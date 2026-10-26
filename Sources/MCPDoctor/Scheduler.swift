import AppKit
import MCPDoctorCore
import Network

/// Keeps snapshots current without polling hard:
///
/// - File watchers re-read config and cache files as soon as a harness writes them.
/// - One coalescing timer runs each harness's own check on its own interval, one at a time,
///   at background priority.
/// - Checks also run after wake, when the network comes back, and when the panel opens with
///   stale data. Nothing runs while offline; intervals double in Low Power Mode.
@MainActor
final class Scheduler {
    private static let tickInterval: TimeInterval = 60
    private static let quickRefreshInterval: TimeInterval = 5 * 60
    /// Data older than this is checked again when the panel opens or the Mac wakes.
    private static let staleAfter: TimeInterval = 5 * 60
    /// Gives Wi-Fi a moment to reconnect after wake.
    private static let wakeDelay: Duration = .seconds(20)
    /// Harnesses rewrite some watched files in bursts.
    private static let fileChangeDebounce: Duration = .seconds(3)
    /// A harness's own check rewrites its token file, so changes right after a check are ignored.
    private static let signInFileQuietPeriod: TimeInterval = 60

    private static func checkInterval(for harness: Harness) -> TimeInterval {
        switch harness {
        case .claudeCode: 15 * 60
        case .codex: 10 * 60
        case .cursor: 15 * 60
        }
    }

    private let model: AppModel
    private var timer: Timer?
    private var lastCheck: [Harness: Date] = [:]
    private var lastQuickRefresh = Date.distantPast
    private var queue: [Harness] = []
    private var isDraining = false
    private var watchers: [FileWatcher] = []
    private var pendingFileChanges: [URL: Task<Void, Never>] = [:]
    private let pathMonitor = NWPathMonitor()
    private var wakeObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        model.requestCheck = { [weak self] harness, delay in
            Task {
                try? await Task.sleep(for: delay)
                self?.enqueue(harness)
            }
        }
        Task {
            for harness in Harness.allCases {
                await model.refresh(harness, deep: false)
            }
            lastQuickRefresh = .now
            checkAllNow()
        }
        watchFiles()
        startTimer()
        observeWake()
        observeNetwork()
    }

    func panelOpened() {
        checkStale()
    }

    func checkAllNow() {
        Harness.allCases.forEach(enqueue)
    }

    private func checkStale() {
        for harness in Harness.allCases where age(of: harness) > Self.staleAfter {
            enqueue(harness)
        }
    }

    private func age(of harness: Harness) -> TimeInterval {
        lastCheck[harness].map { Date.now.timeIntervalSince($0) } ?? .infinity
    }

    private func tick() {
        guard model.isOnline else { return }
        let factor: Double = ProcessInfo.processInfo.isLowPowerModeEnabled ? 2 : 1
        for harness in Harness.allCases where age(of: harness) >= Self.checkInterval(for: harness) * factor {
            enqueue(harness)
        }
        if Date.now.timeIntervalSince(lastQuickRefresh) >= Self.quickRefreshInterval * factor {
            lastQuickRefresh = .now
            Task {
                for harness in Harness.allCases {
                    await model.refresh(harness, deep: false)
                }
            }
        }
    }

    private func enqueue(_ harness: Harness) {
        guard model.isOnline, !queue.contains(harness) else { return }
        queue.append(harness)
        drain()
    }

    /// Runs queued checks one at a time so two harness CLIs never run together.
    private func drain() {
        guard !isDraining else { return }
        isDraining = true
        Task {
            while !queue.isEmpty {
                let harness = queue.removeFirst()
                lastCheck[harness] = .now
                await model.refresh(harness, deep: true)
            }
            isDraining = false
        }
    }

    // MARK: - Triggers

    private func startTimer() {
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = Self.tickInterval / 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: Self.wakeDelay)
                self?.checkStale()
            }
        }
    }

    private func observeNetwork() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "mcp-doctor.network", qos: .utility))
    }

    private func networkChanged(online: Bool) {
        let cameBack = online && !model.isOnline
        model.isOnline = online
        if cameBack { checkAllNow() }
    }

    private func watchFiles() {
        watchers = model.doctor.watchedFiles.map { file in
            FileWatcher(url: file.url) { [weak self] in self?.fileChanged(file) }
        }
    }

    private func fileChanged(_ file: WatchedFile) {
        pendingFileChanges[file.url]?.cancel()
        pendingFileChanges[file.url] = Task { [weak self] in
            try? await Task.sleep(for: Self.fileChangeDebounce)
            guard !Task.isCancelled, let self else { return }
            await model.refresh(file.harness, deep: false)
            if file.changesOnSignIn, age(of: file.harness) > Self.signInFileQuietPeriod {
                enqueue(file.harness)
            }
        }
    }
}

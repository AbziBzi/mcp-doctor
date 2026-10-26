import AppKit
import MCPDoctorCore
import Observation

enum SignInState: Equatable {
    case running(link: URL?)
    case failed(String)
}

/// One harness's servers, split the way the panel shows them.
struct ServerGroups {
    /// Problems worth a badge.
    var attention: [MCPServer] = []
    /// Everything else worth listing: healthy, muted, disabled or not yet checked.
    var others: [MCPServer] = []
    /// claude.ai connectors that have never worked on this Mac.
    var dormant: [MCPServer] = []
}

@MainActor
@Observable
final class AppModel {
    private static let signInTimeout: TimeInterval = 10 * 60
    /// A sign-in in Terminal gives no signal when it finishes, so check again a few times.
    private static let terminalSignInRechecks: [Duration] = [.seconds(60), .seconds(180)]

    let doctor: Doctor

    private(set) var snapshots: [HarnessSnapshot] = Harness.allCases.map {
        HarnessSnapshot(harness: $0, installed: true, servers: [], checkedAt: nil, error: nil)
    }
    private(set) var checking: Set<Harness> = []
    private(set) var signIns: [String: SignInState] = [:]
    var isOnline = true
    private(set) var muted: Set<String>
    private(set) var seenHealthy: Set<String>

    /// Queues a check of a harness after a delay. Set by the scheduler, which runs one at a time.
    @ObservationIgnored var requestCheck: ((Harness, Duration) -> Void)?
    @ObservationIgnored private var signInTasks: [String: Task<Void, Never>] = [:]
    /// Where muted and seen-healthy servers persist; `nil` keeps them in memory (demo mode).
    @ObservationIgnored private let defaults: UserDefaults?

    init(doctor: Doctor, defaults: UserDefaults? = .standard) {
        self.doctor = doctor
        self.defaults = defaults
        muted = Set(defaults?.stringArray(forKey: "mutedServers") ?? [])
        seenHealthy = Set(defaults?.stringArray(forKey: "seenHealthyServers") ?? [])
    }

    func groups(for snapshot: HarnessSnapshot) -> ServerGroups {
        var groups = ServerGroups()
        for server in snapshot.servers.sorted(by: Self.problemsFirst) {
            if AttentionPolicy.needsAttention(server, muted: muted, seenHealthy: seenHealthy) {
                groups.attention.append(server)
            } else if isDormant(server) {
                groups.dormant.append(server)
            } else {
                groups.others.append(server)
            }
        }
        return groups
    }

    var attentionCount: Int {
        snapshots.reduce(0) { $0 + groups(for: $1).attention.count }
    }

    var lastChecked: Date? {
        snapshots.compactMap(\.checkedAt).max()
    }

    func isDormant(_ server: MCPServer) -> Bool {
        AttentionPolicy.isDormant(server, seenHealthy: seenHealthy)
    }

    func isMuted(_ server: MCPServer) -> Bool {
        muted.contains(server.id)
    }

    static func problemsFirst(_ a: MCPServer, _ b: MCPServer) -> Bool {
        (a.status.sortRank, a.displayName.lowercased()) < (b.status.sortRank, b.displayName.lowercased())
    }

    // MARK: - Refreshing

    /// A quick refresh re-reads local files; a deep one also runs the harness's own check.
    func refresh(_ harness: Harness, deep: Bool) async {
        if deep { checking.insert(harness) }
        defer { if deep { checking.remove(harness) } }
        await doctor.quickRefresh(harness, forceCredentials: deep)
        if deep { await doctor.deepCheck(harness) }
        apply(await doctor.snapshots())
    }

    private func apply(_ snapshots: [HarnessSnapshot]) {
        self.snapshots = snapshots
        let healthy = snapshots.flatMap(\.servers).filter { $0.status == .ok }.map(\.id)
        if !seenHealthy.isSuperset(of: healthy) {
            seenHealthy.formUnion(healthy)
            defaults?.set(seenHealthy.sorted(), forKey: "seenHealthyServers")
        }
    }

    func toggleMute(_ server: MCPServer) {
        if muted.contains(server.id) { muted.remove(server.id) } else { muted.insert(server.id) }
        defaults?.set(muted.sorted(), forKey: "mutedServers")
    }

    // MARK: - Signing in

    /// Runs the harness's own login command without a terminal. The CLI opens the browser and
    /// stores the tokens in its own format; this app never writes credentials.
    func signIn(_ server: MCPServer) {
        let id = server.id
        guard signInTasks[id] == nil else { return }
        signIns[id] = .running(link: nil)
        signInTasks[id] = Task {
            defer { signInTasks[id] = nil }
            guard let invocation = await doctor.signInInvocation(for: server) else {
                signIns[id] = .failed("\(server.harness.displayName) can't sign in to this server from here")
                return
            }
            let env = await doctor.environment()
            let result = await CommandRunner.run(
                invocation.executable,
                arguments: invocation.arguments,
                environment: env.variables,
                workingDirectory: invocation.workingDirectory,
                timeout: Self.signInTimeout,
                qualityOfService: .userInitiated,
                onOutput: { chunk in
                    if let link = Self.firstLink(in: chunk) {
                        Task { @MainActor in self.showSignInLink(link, for: id) }
                    }
                    return false
                }
            )
            if Task.isCancelled {
                signIns[id] = nil
            } else if result.succeeded {
                signIns[id] = nil
                requestCheck?(server.harness, .zero)
            } else {
                signIns[id] = .failed(Compatibility.explain(
                    result.failureSummary,
                    harness: server.harness,
                    action: "sign in to MCP servers from the command line"
                ))
            }
        }
    }

    /// The running task ends the login process and then clears its own state.
    func cancelSignIn(_ server: MCPServer) {
        signInTasks[server.id]?.cancel()
    }

    func dismissSignInError(_ server: MCPServer) {
        signIns[server.id] = nil
    }

    /// Fallback for CLIs that need a real terminal.
    func signInInTerminal(_ server: MCPServer) {
        Task {
            guard let invocation = await doctor.signInInvocation(for: server) else { return }
            do {
                NSWorkspace.shared.open(try Self.terminalScript(for: invocation))
                signIns[server.id] = nil
                for delay in Self.terminalSignInRechecks {
                    requestCheck?(server.harness, delay)
                }
            } catch {
                signIns[server.id] = .failed(error.localizedDescription)
            }
        }
    }

    func copySignInCommand(_ server: MCPServer) {
        Task {
            guard let invocation = await doctor.signInInvocation(for: server) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(invocation.shellCommand, forType: .string)
        }
    }

    private func showSignInLink(_ link: URL, for id: String) {
        if case .running(nil) = signIns[id] { signIns[id] = .running(link: link) }
    }

    /// A `.command` file opens in Terminal without Automation permission and deletes itself.
    private static func terminalScript(for invocation: Invocation) throws -> URL {
        let script = """
        #!/bin/zsh -l
        cd \(Invocation.shellQuote(invocation.workingDirectory.path))
        \(invocation.shellCommand)
        code=$?
        echo
        if [ $code -eq 0 ]; then echo "Signed in. You can close this window."; else echo "Sign-in exited with status $code."; fi
        rm -f -- "$0"
        """
        let url = FileManager.default.temporaryDirectory.appending(path: "mcp-doctor-sign-in-\(UUID().uuidString).command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    nonisolated static func firstLink(in chunk: Data) -> URL? {
        let text = String(decoding: chunk, as: UTF8.self)
        return text.firstMatch(of: #/https?://[^\s"'<>]+/#).flatMap { URL(string: String($0.output)) }
    }
}

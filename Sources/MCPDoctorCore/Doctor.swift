import Foundation

/// A file a harness writes, watched so changes show up without waiting for the next check.
public struct WatchedFile: Sendable {
    public let harness: Harness
    public let url: URL
    /// The harness rewrites it after a sign-in, so a change calls for a check.
    public let changesOnSignIn: Bool
}

/// Holds what is known about every harness and merges it into snapshots.
public actor Doctor {
    private static let credentialReadInterval: TimeInterval = 5 * 60

    private struct HarnessState {
        var installed = true
        var configured: [ConfiguredServer] = []
        var fileSignals: [String: [LocalSignal]] = [:]
        var credentialSignals: [String: [LocalSignal]] = [:]
        var lastCredentialRead: Date?
        var check: DeepCheck?
        var checkedAt: Date?
        var error: String?
    }

    public nonisolated let watchedFiles: [WatchedFile]
    private let adapters: [Harness: any HarnessAdapter]
    private let environmentTask: Task<ShellEnvironment, Never>
    private var states: [Harness: HarnessState] = [:]
    private var deepChecks: [Harness: Task<Void, Never>] = [:]

    /// Without an `environment`, the user's login-shell environment is loaded in the background.
    public init(adapters: [any HarnessAdapter], environment: ShellEnvironment? = nil) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.harness, $0) })
        watchedFiles = adapters.flatMap { adapter in
            adapter.watchedFiles.map { WatchedFile(harness: adapter.harness, url: $0, changesOnSignIn: false) }
                + adapter.signInFiles.map { WatchedFile(harness: adapter.harness, url: $0, changesOnSignIn: true) }
        }
        environmentTask = Task { [environment] in
            if let environment { return environment }
            return await ShellEnvironment.load()
        }
    }

    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Doctor {
        Doctor(adapters: [
            ClaudeCodeAdapter(home: home),
            CodexAdapter(home: home),
            CursorAdapter(home: home),
        ])
    }

    public func environment() async -> ShellEnvironment {
        await environmentTask.value
    }

    /// Re-reads config files and local signals. Credential stores are read at most every few
    /// minutes unless `forceCredentials` is set.
    public func quickRefresh(_ harness: Harness, forceCredentials: Bool = false) async {
        guard let adapter = adapters[harness] else { return }
        let env = await environment()
        let lastRead = states[harness]?.lastCredentialRead
        let readCredentials = forceCredentials
            || lastRead.map { Date.now.timeIntervalSince($0) > Self.credentialReadInterval } ?? true

        let configured = await adapter.configuredServers(env: env)
        let fileSignals = await adapter.localSignals(env: env)
        let credentialSignals = readCredentials ? await adapter.credentialSignals(env: env) : nil

        update(harness) { state in
            state.installed = adapter.isInstalled(env: env)
            state.configured = configured
            state.fileSignals = fileSignals
            if let credentialSignals {
                state.credentialSignals = credentialSignals
                state.lastCredentialRead = .now
            }
        }
    }

    /// Runs the harness's own health check. Concurrent requests for one harness share a run.
    public func deepCheck(_ harness: Harness) async {
        if let running = deepChecks[harness] {
            await running.value
            return
        }
        let task = Task { await performDeepCheck(harness) }
        deepChecks[harness] = task
        await task.value
        deepChecks[harness] = nil
    }

    private func performDeepCheck(_ harness: Harness) async {
        guard let adapter = adapters[harness] else { return }
        let env = await environment()
        do {
            let check = try await adapter.deepCheck(env: env)
            update(harness) { state in
                state.installed = true
                state.check = check
                state.checkedAt = .now
                state.error = nil
            }
        } catch AdapterError.notInstalled {
            update(harness) { state in
                state.installed = false
                state.error = nil
            }
        } catch {
            let message = Compatibility.explain(error.localizedDescription, harness: harness, action: "report MCP server status")
            update(harness) { state in
                state.error = message
                state.checkedAt = .now
            }
        }
    }

    private func update(_ harness: Harness, _ change: (inout HarnessState) -> Void) {
        change(&states[harness, default: HarnessState()])
    }

    public func signInInvocation(for server: MCPServer) async -> Invocation? {
        let env = await environment()
        return adapters[server.harness]?.signInInvocation(for: server, env: env)
    }

    public func snapshots(now: Date = .now) -> [HarnessSnapshot] {
        Harness.allCases.map { harness in
            let state = states[harness] ?? HarnessState()
            let signals = state.fileSignals.merging(state.credentialSignals) { files, credentials in files + credentials }
            return HarnessSnapshot(
                harness: harness,
                installed: state.installed,
                servers: StatusMerger.merge(
                    harness: harness,
                    configured: state.configured,
                    check: state.check,
                    signals: signals,
                    now: now
                ),
                checkedAt: state.checkedAt,
                error: state.error
            )
        }
    }
}

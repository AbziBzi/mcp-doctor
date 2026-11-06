import Foundation

/// Pi (`pi` CLI, `@earendil-works/pi-coding-agent`).
///
/// - Config: `~/.pi/agent/mcp.json`, or `$PI_CODING_AGENT_DIR/mcp.json` when that's set.
/// - Health: `pi mcp list --json` (~3 s). Pi connects to every enabled server, refreshing tokens
///   itself, and prints each server's state. It exits with status 1 whenever a server isn't
///   connected, so the JSON on stdout is read regardless of the exit status.
/// - Sign-in: `pi mcp login <name>`. Without a terminal it opens the browser and finishes on the
///   browser's callback, so it runs in the background like the other harnesses.
public struct PiAdapter: HarnessAdapter {
    public let harness = Harness.pi
    public let home: URL
    let agentDirectory: URL

    public init(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        agentDirectory = Self.agentDirectory(home: home, environment: environment)
    }

    static func agentDirectory(home: URL, environment: [String: String]) -> URL {
        guard let custom = environment["PI_CODING_AGENT_DIR"], !custom.isEmpty else {
            return home.appending(path: ".pi/agent")
        }
        if custom == "~" { return home }
        if custom.hasPrefix("~/") { return home.appending(path: String(custom.dropFirst(2))) }
        return URL(fileURLWithPath: custom)
    }

    var configURL: URL { agentDirectory.appending(path: "mcp.json") }
    var authFileURL: URL { agentDirectory.appending(path: "mcp-auth.json") }

    public var watchedFiles: [URL] { [configURL] }
    public var signInFiles: [URL] { [authFileURL] }

    public func configuredServers(env: ShellEnvironment) async -> [ConfiguredServer] {
        // The CLI runs with the login-shell environment, which may point Pi elsewhere.
        let directory = env.variables["PI_CODING_AGENT_DIR"] == nil
            ? agentDirectory
            : Self.agentDirectory(home: home, environment: env.variables)
        let config = directory.appending(path: "mcp.json")
        guard let servers = JSONFile.object(at: config)?["mcpServers"] as? [String: Any] else { return [] }
        return servers.keys.sorted().compactMap { name in
            guard let entry = servers[name] as? [String: Any] else { return nil }
            let url = entry["url"] as? String
            let headers = entry["headers"] as? [String: Any] ?? [:]
            return ConfiguredServer(
                name: name,
                transport: url == nil ? .stdio : .http,
                target: url ?? entry["command"] as? String,
                enabled: (entry["enabled"] as? Bool) != false,
                canSignIn: url != nil && !Self.hasAuthorizationHeader(headers)
            )
        }
    }

    public func deepCheck(env: ShellEnvironment) async throws -> DeepCheck {
        let executable = try requireExecutable(env)
        let startedAt = Date.now
        let result = await CommandRunner.run(
            executable,
            arguments: ["mcp", "list", "--json"],
            environment: env.variables,
            workingDirectory: home,
            timeout: 90,
            qualityOfService: .background
        )
        if result.launchError != nil || result.timedOut {
            throw AdapterError.commandFailed(result.failureSummary)
        }
        guard let list = Self.parseList(result.stdout) else {
            if !result.succeeded, !result.output.contains("{") {
                throw AdapterError.commandFailed(result.failureSummary)
            }
            throw AdapterError.unreadableOutput(harness: harness, command: "pi mcp list --json")
        }
        if list.servers.isEmpty, let configError = list.errors.first {
            throw AdapterError.commandFailed(configError)
        }
        return DeepCheck(servers: list.servers, startedAt: startedAt)
    }

    /// Pi signs in with OAuth only when the server has no `Authorization` header of its own.
    static func hasAuthorizationHeader(_ headers: [String: Any]) -> Bool {
        headers.keys.contains { $0.lowercased() == "authorization" }
    }

    // MARK: - Parsing

    struct ListResponse: Decodable {
        struct Entry: Decodable {
            let name: String
            let enabled: Bool?
            /// The URL of an HTTP server, or the command of a stdio server.
            let transport: String?
            let state: String?
            let error: String?
        }

        let servers: [Entry]
        let errors: [String]?
    }

    static func parseList(_ data: Data) -> (servers: [CheckedServer], errors: [String])? {
        guard let list = try? JSONDecoder().decode(ListResponse.self, from: data) else { return nil }
        let servers = list.servers.map { entry in
            let isHTTP = entry.transport.map { $0.hasPrefix("http://") || $0.hasPrefix("https://") } ?? false
            let (status, detail) = status(for: entry)
            return CheckedServer(
                name: entry.name,
                transport: isHTTP ? .http : .stdio,
                target: entry.transport,
                status: status,
                detail: detail,
                // The list doesn't say whether a server uses OAuth or its own headers; mcp.json
                // does. Only a server Pi says needs sign-in is known to use OAuth.
                canSignIn: isHTTP && entry.state == "needs-auth"
            )
        }
        return (servers, list.errors ?? [])
    }

    /// Pi's states: `connecting`, `connected`, `disconnected`, `needs-auth`, `failed` and `closed`.
    static func status(for entry: ListResponse.Entry) -> (ServerStatus, String?) {
        if entry.enabled == false || entry.state == "disabled" { return (.disabled, "Disabled in Pi") }
        switch entry.state {
        case "connected":
            return (.ok, nil)
        case "needs-auth":
            return (.needsAuth, entry.error)
        case "failed":
            let detail = entry.error ?? "Failed to connect"
            let lowered = detail.lowercased()
            let authFailure = ["unauthorized", "401", "invalid_grant", "invalid_token", "oauth"]
                .contains { lowered.contains($0) }
            return (authFailure ? .needsAuth : .failed, detail)
        default:
            return (.unknown, entry.error ?? entry.state.map { "Pi reported \($0)" })
        }
    }
}

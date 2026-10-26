import Foundation
import Synchronization

/// Codex.
///
/// - Config: `codex mcp list --json` (~60 ms), which already includes plugin servers.
/// - Health: `codex app-server` → `mcpServerStatus/list`. Codex connects to each server, refreshing
///   tokens with its own locking, and reports per-server errors (~2 s).
/// - Sign-in: `codex mcp login <name>`.
public struct CodexAdapter: HarnessAdapter {
    public let harness = Harness.codex
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    public var watchedFiles: [URL] { [home.appending(path: ".codex/config.toml")] }

    public func configuredServers(env: ShellEnvironment) async -> [ConfiguredServer] {
        guard let executable = env.executable(named: harness.executableName) else { return [] }
        let result = await CommandRunner.run(
            executable,
            arguments: ["mcp", "list", "--json"],
            environment: env.variables,
            workingDirectory: home,
            timeout: 15
        )
        return Self.parseConfigList(result.stdout)
    }

    public func deepCheck(env: ShellEnvironment) async throws -> DeepCheck {
        let executable = try requireExecutable(env)
        let startedAt = Date.now
        let scanner = ResponseScanner(responseID: 2)
        let result = await CommandRunner.run(
            executable,
            arguments: ["app-server"],
            environment: env.variables,
            workingDirectory: home,
            input: Self.statusRequests,
            keepInputOpen: true,
            timeout: 60,
            qualityOfService: .background,
            onOutput: scanner.consume
        )
        guard let response = scanner.response else {
            throw AdapterError.commandFailed(scanner.errorMessage ?? result.failureSummary)
        }
        return DeepCheck(servers: Self.parseStatusResponse(response), startedAt: startedAt)
    }

    /// The JSON-RPC handshake, then a request for every server's status (id 2).
    static var statusRequests: Data {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"mcp-doctor","version":"\#(version)"}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"mcpServerStatus/list","params":{"detail":"toolsAndAuthOnly","limit":500}}"#,
        ]
        return Data(requests.map { $0 + "\n" }.joined().utf8)
    }

    /// Codex spells auth states `o_auth` in the CLI and `oAuth` in the app server.
    static func usesOAuth(_ authStatus: String?) -> Bool {
        let normalized = authStatus?.replacingOccurrences(of: "_", with: "").lowercased()
        return normalized == "oauth" || normalized == "notloggedin"
    }

    // MARK: - Parsing

    struct ConfigEntry: Decodable {
        struct TransportInfo: Decodable {
            let type: String?
            let url: String?
            let command: String?
        }

        let name: String
        let enabled: Bool?
        let transport: TransportInfo?
        let authStatus: String?
    }

    static func parseConfigList(_ data: Data) -> [ConfiguredServer] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let entries = try? decoder.decode([ConfigEntry].self, from: data) else { return [] }
        return entries.map { entry in
            let isHTTP = entry.transport?.url != nil || (entry.transport?.type ?? "").contains("http")
            return ConfiguredServer(
                name: entry.name,
                transport: isHTTP ? .http : .stdio,
                target: entry.transport?.url ?? entry.transport?.command,
                enabled: entry.enabled ?? true,
                canSignIn: usesOAuth(entry.authStatus)
            )
        }
    }

    struct StatusResponse: Decodable, Sendable {
        struct Page: Decodable, Sendable {
            let data: [Entry]
        }

        struct Entry: Decodable, Sendable {
            let name: String
            let authStatus: String?
            let runtimeStatus: String?
            let toolsError: String?
            let httpOrigin: String?
        }

        let result: Page
    }

    static func parseStatusResponse(_ response: StatusResponse) -> [CheckedServer] {
        response.result.data.map { entry in
            let (status, detail) = status(for: entry)
            return CheckedServer(
                name: entry.name,
                transport: entry.httpOrigin == nil ? .stdio : .http,
                target: entry.httpOrigin,
                status: status,
                detail: detail,
                canSignIn: usesOAuth(entry.authStatus)
            )
        }
    }

    static func status(for entry: StatusResponse.Entry) -> (ServerStatus, String?) {
        if entry.runtimeStatus == "disabled" { return (.disabled, "Disabled in Codex") }
        if let error = entry.toolsError {
            let detail = error.replacingOccurrences(of: "MCP startup failed: ", with: "")
            let lowered = error.lowercased()
            let authFailure = ["oauth", "unauthorized", "401", "invalid_client", "invalid_grant", "token"]
                .contains { lowered.contains($0) }
            return (authFailure ? .needsAuth : .failed, detail)
        }
        if entry.authStatus == "notLoggedIn" { return (.needsAuth, "Not signed in") }
        return (.ok, nil)
    }
}

/// Collects newline-delimited JSON-RPC messages until the response with a given id arrives.
final class ResponseScanner: Sendable {
    private struct Envelope: Decodable {
        struct RPCError: Decodable {
            let message: String
        }

        let id: Int?
        let error: RPCError?
    }

    private struct State {
        var partialLine = Data()
        var response: CodexAdapter.StatusResponse?
        var errorMessage: String?
    }

    private let responseID: Int
    private let state = Mutex(State())

    init(responseID: Int) {
        self.responseID = responseID
    }

    var response: CodexAdapter.StatusResponse? { state.withLock { $0.response } }
    var errorMessage: String? { state.withLock { $0.errorMessage } }

    /// Returns `true` once there's nothing more to wait for.
    func consume(_ chunk: Data) -> Bool {
        state.withLock { state in
            var segments = chunk.split(separator: 0x0A, omittingEmptySubsequences: false)
            let tail = segments.removeLast()
            for segment in segments {
                state.partialLine.append(segment)
                let line = state.partialLine
                state.partialLine = Data()
                if handle(line, into: &state) { return true }
            }
            state.partialLine.append(tail)
            return false
        }
    }

    private func handle(_ line: Data, into state: inout State) -> Bool {
        guard !line.isEmpty, let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else { return false }
        if let error = envelope.error, envelope.id != nil {
            state.errorMessage = error.message
            return true
        }
        guard envelope.id == responseID else { return false }
        do {
            state.response = try JSONDecoder().decode(CodexAdapter.StatusResponse.self, from: line)
        } catch {
            state.errorMessage = "Unexpected response from codex app-server"
        }
        return true
    }
}

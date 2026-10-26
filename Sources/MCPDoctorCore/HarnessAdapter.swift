import Foundation

/// Knows where one harness keeps its MCP configuration and how to ask it about server health.
public protocol HarnessAdapter: Sendable {
    var harness: Harness { get }

    /// Checks and sign-ins run from here.
    var home: URL { get }

    /// Files the harness writes that this adapter reads; a change triggers a re-read.
    var watchedFiles: [URL] { get }

    /// Files the harness rewrites after a sign-in. A change may mean a sign-in finished outside
    /// this app, which only a check can confirm.
    var signInFiles: [URL] { get }

    func isInstalled(env: ShellEnvironment) -> Bool

    /// Servers from config files. Cheap.
    func configuredServers(env: ShellEnvironment) async -> [ConfiguredServer]

    /// Evidence from files the harness writes, such as a needs-auth cache. Cheap.
    func localSignals(env: ShellEnvironment) async -> [String: [LocalSignal]]

    /// Token metadata from the harness's credential store. Read less often than files.
    func credentialSignals(env: ShellEnvironment) async -> [String: [LocalSignal]]

    /// The harness's own health check. Authoritative but slower; the harness refreshes tokens
    /// itself, with its own locking.
    func deepCheck(env: ShellEnvironment) async throws -> DeepCheck

    func signInInvocation(for server: MCPServer, env: ShellEnvironment) -> Invocation?
}

extension HarnessAdapter {
    public var signInFiles: [URL] { [] }

    public func isInstalled(env: ShellEnvironment) -> Bool {
        env.executable(named: harness.executableName) != nil
    }

    public func localSignals(env: ShellEnvironment) async -> [String: [LocalSignal]] { [:] }

    public func credentialSignals(env: ShellEnvironment) async -> [String: [LocalSignal]] { [:] }

    /// `<cli> mcp login <name>`, which all supported harnesses share.
    public func signInInvocation(for server: MCPServer, env: ShellEnvironment) -> Invocation? {
        guard server.canSignIn, let executable = env.executable(named: harness.executableName) else { return nil }
        return Invocation(executable: executable, arguments: ["mcp", "login", server.name], workingDirectory: home)
    }

    func requireExecutable(_ env: ShellEnvironment) throws -> URL {
        guard let executable = env.executable(named: harness.executableName) else {
            throw AdapterError.notInstalled(harness.executableName)
        }
        return executable
    }

    /// Runs `<cli> mcp list` from the home folder and parses its text output.
    func listCheck(
        env: ShellEnvironment,
        extraEnvironment: [String: String] = [:],
        timeout: TimeInterval,
        parse: (String) -> [CheckedServer]
    ) async throws -> DeepCheck {
        let executable = try requireExecutable(env)
        let startedAt = Date.now
        let result = await CommandRunner.run(
            executable,
            arguments: ["mcp", "list"],
            environment: env.variables.merging(extraEnvironment) { _, extra in extra },
            workingDirectory: home,
            timeout: timeout,
            qualityOfService: .background
        )
        let servers = parse(result.output)
        if servers.isEmpty, !result.succeeded {
            throw AdapterError.commandFailed(result.failureSummary)
        }
        let command = "\(harness.executableName) mcp list"
        return DeepCheck(
            servers: try ListOutput.validate(servers, output: result.output, harness: harness, command: command),
            startedAt: startedAt
        )
    }
}

public enum AdapterError: LocalizedError {
    case notInstalled(String)
    case commandFailed(String)
    /// The command ran but printed nothing that could be parsed, usually because a newer or
    /// older harness formats its output differently.
    case unreadableOutput(harness: Harness, command: String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let name):
            "\(name) is not installed"
        case .commandFailed(let message):
            message
        case .unreadableOutput(let harness, let command):
            "Couldn't read the output of `\(command)`. This version of \(harness.displayName) may not be "
                + "supported yet; MCP Doctor is tested with \(harness.testedVersion)."
        }
    }
}

/// Turns the errors CLIs print when they lack a command or method into update instructions.
public enum Compatibility {
    static let unsupportedMarkers = [
        "unknown command", "unrecognized subcommand", "unexpected argument",
        "method not found", "-32601", "unknown variant", "unknown field", "missing field", "invalid params",
    ]

    /// `action` completes "This version of <harness> can't …".
    public static func explain(_ message: String, harness: Harness, action: String) -> String {
        let lowered = message.lowercased()
        guard unsupportedMarkers.contains(where: lowered.contains) else { return message }
        return "This version of \(harness.displayName) can't \(action). Update \(harness.displayName); "
            + "MCP Doctor is tested with \(harness.testedVersion)."
    }
}

enum ListOutput {
    /// Returns the parsed servers, or throws when the output had content but none of it could
    /// be read. An empty list is only accepted when the CLI says there are no servers.
    static func validate(
        _ servers: [CheckedServer],
        output: String,
        harness: Harness,
        command: String
    ) throws -> [CheckedServer] {
        guard servers.isEmpty else { return servers }
        let lines = CommandOutput.lines(output).filter { !$0.lowercased().hasPrefix("checking") }
        let lowered = output.lowercased()
        if lines.isEmpty || lowered.contains("no mcp servers") || lowered.contains("no servers") {
            return []
        }
        throw AdapterError.unreadableOutput(harness: harness, command: command)
    }
}

enum CommandOutput {
    static var ansiEscape: Regex<Substring> { #/\u{1B}\[[0-9;?]*[A-Za-z]/# }

    /// Non-empty, trimmed lines without terminal escape codes.
    static func lines(_ text: String) -> [String] {
        text.replacing(ansiEscape, with: "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

enum JSONFile {
    static func object(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

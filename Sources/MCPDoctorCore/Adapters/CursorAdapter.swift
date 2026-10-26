import Foundation

/// Cursor (`cursor-agent` CLI).
///
/// - Config: `~/.cursor/mcp.json`.
/// - Health: `cursor-agent mcp list` (~2.5 s). Cursor keeps a project folder per working
///   directory, and its answers differ between directories, so checks run from the home
///   directory, whose project holds the token file the others link to.
/// - Sign-in: `cursor-agent mcp login <name>`, also from the home directory.
public struct CursorAdapter: HarnessAdapter {
    public let harness = Harness.cursor
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    var configURL: URL { home.appending(path: ".cursor/mcp.json") }

    /// `~/.cursor/projects/<home path with separators as dashes>/mcp-auth.json`
    var authFileURL: URL {
        let slug = home.path.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
        return home.appending(path: ".cursor/projects/\(slug)/mcp-auth.json")
    }

    public var watchedFiles: [URL] { [configURL] }
    public var signInFiles: [URL] { [authFileURL] }

    public func configuredServers(env: ShellEnvironment) async -> [ConfiguredServer] {
        guard let servers = JSONFile.object(at: configURL)?["mcpServers"] as? [String: Any] else { return [] }
        return servers.keys.sorted().compactMap { name in
            guard let entry = servers[name] as? [String: Any] else { return nil }
            let url = entry["url"] as? String
            return ConfiguredServer(
                name: name,
                transport: url == nil ? .stdio : .http,
                target: url ?? entry["command"] as? String,
                enabled: (entry["disabled"] as? Bool) != true,
                canSignIn: url != nil
            )
        }
    }

    public func deepCheck(env: ShellEnvironment) async throws -> DeepCheck {
        try await listCheck(env: env, timeout: 60, parse: Self.parseList)
    }

    // MARK: - Parsing

    /// Lines look like `name: requires_authentication`. Transport and sign-in support aren't in
    /// the output; they come from `mcp.json` when the results are merged.
    static func parseList(_ output: String) -> [CheckedServer] {
        CommandOutput.lines(output).compactMap { line in
            guard let separator = line.range(of: ": ", options: .backwards) else { return nil }
            let name = String(line[..<separator.lowerBound])
            let state = String(line[separator.upperBound...])
            guard !name.isEmpty, !state.contains(" ") else { return nil }
            let (status, detail) = parseStatus(state)
            return CheckedServer(name: name, transport: .unknown, status: status, detail: detail, canSignIn: false)
        }
    }

    static func parseStatus(_ state: String) -> (ServerStatus, String?) {
        let lowered = state.lowercased()
        let readable = state.replacingOccurrences(of: "_", with: " ")
        if lowered == "ready" || lowered == "connected" { return (.ok, nil) }
        if lowered.contains("auth") { return (.needsAuth, nil) }
        if lowered.contains("disabled") { return (.disabled, "Disabled in Cursor") }
        if lowered.contains("error") || lowered.contains("fail") { return (.failed, readable) }
        return (.unknown, readable)
    }
}

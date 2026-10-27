import Foundation

/// Claude Code.
///
/// - Config: `~/.claude.json` → `mcpServers` (user scope). Plugin servers and claude.ai
///   connectors only show up in `claude mcp list`.
/// - Local signals: `~/.claude/mcp-needs-auth-cache.json`, which Claude Code writes when a server
///   needs sign-in, and token expiry metadata from the `Claude Code-credentials` Keychain item.
/// - Health: `claude mcp list` connects to every server (~6 s with larger connection batches).
/// - Sign-in: `claude mcp login <name>`, which also covers claude.ai connectors.
public struct ClaudeCodeAdapter: HarnessAdapter {
    public let harness = Harness.claudeCode
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    var configURL: URL { home.appending(path: ".claude.json") }
    var needsAuthCacheURL: URL { home.appending(path: ".claude/mcp-needs-auth-cache.json") }

    public var watchedFiles: [URL] { [configURL, needsAuthCacheURL] }

    public func configuredServers(env: ShellEnvironment) async -> [ConfiguredServer] {
        guard let servers = JSONFile.object(at: configURL)?["mcpServers"] as? [String: Any] else { return [] }
        return servers.keys.sorted().compactMap { name in
            guard let entry = servers[name] as? [String: Any] else { return nil }
            let url = entry["url"] as? String
            let transport: Transport = switch (entry["type"] as? String)?.lowercased() {
            case "http": .http
            case "sse": .sse
            case "stdio": .stdio
            default: url == nil ? .stdio : .http
            }
            return ConfiguredServer(
                name: name,
                transport: transport,
                target: url ?? entry["command"] as? String,
                canSignIn: transport != .stdio
            )
        }
    }

    public func localSignals(env: ShellEnvironment) async -> [String: [LocalSignal]] {
        let cache = JSONFile.object(at: needsAuthCacheURL) ?? [:]
        return cache.compactMapValues { value in
            guard let milliseconds = (value as? [String: Any])?["timestamp"] as? Double else { return nil }
            return [.needsAuth(since: Date(timeIntervalSince1970: milliseconds / 1000))]
        }
    }

    public func credentialSignals(env: ShellEnvironment) async -> [String: [LocalSignal]] {
        await Self.tokenMetadata().mapValues { [$0] }
    }

    /// Claude Code connects to only a few servers at a time by default, so with ~60 servers
    /// (claude.ai connectors included) `claude mcp list` takes ~24 s. Larger batches give the same
    /// results in ~6 s at about the same peak memory.
    static let checkEnvironment = [
        "MCP_SERVER_CONNECTION_BATCH_SIZE": "64",
        "MCP_REMOTE_SERVER_CONNECTION_BATCH_SIZE": "64",
    ]

    public func deepCheck(env: ShellEnvironment) async throws -> DeepCheck {
        try await listCheck(env: env, extraEnvironment: Self.checkEnvironment, timeout: 120, parse: Self.parseList)
    }

    /// `claude mcp login` cancels an OAuth sign-in as soon as it starts waiting for the browser if
    /// stdin isn't a terminal, after it has already cleared the stored token.
    public func signInInvocation(for server: MCPServer, env: ShellEnvironment) -> Invocation? {
        guard server.canSignIn, let executable = env.executable(named: harness.executableName) else { return nil }
        return Invocation(executable: executable, arguments: ["mcp", "login", server.name], workingDirectory: home, needsTerminal: true)
    }

    // MARK: - Parsing

    /// Lines look like `name: target - ✔ Connected`. Names can contain `:`, and failure details can
    /// contain ` - `, so the split happens at the first ` - ` that is followed by a status glyph.
    static var listLine: Regex<(Substring, name: Substring, target: Substring, glyph: Substring, status: Substring)> {
        #/^(?<name>.+?):\s(?<target>.*?)\s-\s(?<glyph>[^\s\w])\S*\s+(?<status>.+)$/#
    }

    static func parseList(_ output: String) -> [CheckedServer] {
        CommandOutput.lines(output).compactMap { line in
            guard let match = line.wholeMatch(of: listLine) else { return nil }
            let name = match.output.name.trimmingCharacters(in: .whitespaces)
            var target = match.output.target.trimmingCharacters(in: .whitespaces)

            var transport: Transport = target.hasPrefix("http") ? .http : .stdio
            for (suffix, marked) in [("(HTTP)", Transport.http), ("(SSE)", .sse)] where target.hasSuffix(suffix) {
                transport = marked
                target = target.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            }
            if name.hasPrefix(MCPServer.connectorPrefix) { transport = .connector }

            let (status, detail) = parseStatus(String(match.output.status))
            return CheckedServer(
                name: name,
                transport: transport,
                target: target.isEmpty ? nil : target,
                status: status,
                detail: detail,
                canSignIn: transport != .stdio
            )
        }
    }

    static func parseStatus(_ text: String) -> (ServerStatus, String?) {
        let lowered = text.lowercased()
        if lowered.hasPrefix("connected") { return (.ok, nil) }
        if lowered.contains("needs auth") { return (.needsAuth, nil) }
        if lowered.contains("pending approval") { return (.unknown, "Waiting for approval in Claude Code") }
        if lowered.contains("disabled") { return (.disabled, "Disabled in Claude Code") }
        if lowered.hasPrefix("failed") {
            let detail = text.split(separator: "—", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
            return (.failed, detail)
        }
        return (.unknown, text)
    }

    // MARK: - Credentials

    /// Reads expiry metadata from Claude Code's Keychain item. Going through `/usr/bin/security`
    /// rather than the Security framework keeps Keychain access independent of this app's code
    /// signature, which changes with every build. Tokens are decoded only far enough to see whether
    /// they exist and are dropped immediately.
    static func tokenMetadata() async -> [String: LocalSignal] {
        let result = await CommandRunner.run(
            URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
            timeout: 10
        )
        guard result.succeeded else { return [:] }
        return parseCredentials(result.stdout)
    }

    /// The item holds JSON, either as text or hex-encoded.
    static func parseCredentials(_ raw: Data) -> [String: LocalSignal] {
        let trimmed = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let json = trimmed.hasPrefix("{") ? Data(trimmed.utf8) : hexDecoded(trimmed)
        guard let json,
              let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let entries = root["mcpOAuth"] as? [String: [String: Any]]
        else { return [:] }

        var signals: [String: LocalSignal] = [:]
        for entry in entries.values {
            guard let name = entry["serverName"] as? String else { continue }
            let expiresAt = (entry["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            let hasRefreshToken = !((entry["refreshToken"] as? String) ?? "").isEmpty
            signals[name] = .token(expiresAt: expiresAt, hasRefreshToken: hasRefreshToken)
        }
        return signals
    }

    static func hexDecoded(_ hex: String) -> Data? {
        let digits = Array(hex.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            data.append(byte)
        }
        return data
    }
}

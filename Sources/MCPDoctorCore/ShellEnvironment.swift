import Foundation

/// The user's login-shell environment.
///
/// Apps started from Finder or launchd get a minimal PATH, so the harness CLIs and the stdio
/// MCP servers they spawn would not be found. The environment is captured once from the user's
/// shell and kept in memory only.
public struct ShellEnvironment: Sendable {
    public var variables: [String: String]

    public init(variables: [String: String]) {
        self.variables = variables
    }

    static let startMarker = "__MCP_DOCTOR_ENV_START__"
    static let endMarker = "__MCP_DOCTOR_ENV_END__"

    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> ShellEnvironment {
        let inherited = ProcessInfo.processInfo.environment
        let shell = inherited["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let script = "printf '%s' '\(startMarker)'; /usr/bin/env -0; printf '%s' '\(endMarker)'"

        // Interactive first, so PATH set in .zshrc is included; plain login shell as a fallback.
        for flags in ["-ilc", "-lc"] {
            let result = await CommandRunner.run(
                URL(fileURLWithPath: shell),
                arguments: [flags, script],
                environment: inherited,
                workingDirectory: home,
                timeout: 8
            )
            if let variables = parse(result.stdout), variables["PATH"] != nil {
                return ShellEnvironment(variables: withFallbackPath(variables, home: home))
            }
        }
        return ShellEnvironment(variables: withFallbackPath(inherited, home: home))
    }

    /// Reads `env -0` output between the markers, ignoring anything the shell printed around it.
    static func parse(_ data: Data) -> [String: String]? {
        guard let start = data.range(of: Data(startMarker.utf8)),
              let end = data.range(of: Data(endMarker.utf8), in: start.upperBound..<data.endIndex)
        else { return nil }
        var variables: [String: String] = [:]
        for entry in data[start.upperBound..<end.lowerBound].split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "=") else { continue }
            variables[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return variables
    }

    /// Appends the usual install locations of the harness CLIs to PATH.
    static func withFallbackPath(_ variables: [String: String], home: URL) -> [String: String] {
        var variables = variables
        var path = (variables["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for directory in [home.appending(path: ".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        where !path.contains(directory) {
            path.append(directory)
        }
        variables["PATH"] = path.joined(separator: ":")
        return variables
    }

    public func executable(named name: String) -> URL? {
        (variables["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

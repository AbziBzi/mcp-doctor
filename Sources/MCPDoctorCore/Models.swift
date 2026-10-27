import Foundation

public enum Harness: String, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case cursor

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    public var executableName: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .cursor: "cursor-agent"
        }
    }

    /// The newest version MCP Doctor has been tested against.
    public var testedVersion: String {
        switch self {
        case .claudeCode: "2.1.310"
        case .codex: "0.164.0"
        case .cursor: "2026.10.19"
        }
    }
}

public enum Transport: String, Sendable {
    case http
    case sse
    case stdio
    /// A claude.ai connector, managed on claude.ai rather than in a local config file.
    case connector
    case unknown
}

public enum ServerStatus: Sendable, Equatable {
    case ok
    case needsAuth
    /// The access token expires at this date and cannot be refreshed.
    case expiringSoon(Date)
    case failed
    case disabled
    case unknown

    public var isProblem: Bool {
        switch self {
        case .needsAuth, .expiringSoon, .failed: true
        case .ok, .disabled, .unknown: false
        }
    }

    /// Problems first, healthy and disabled last.
    public var sortRank: Int {
        switch self {
        case .needsAuth: 0
        case .failed: 1
        case .expiringSoon: 2
        case .unknown: 3
        case .ok: 4
        case .disabled: 5
        }
    }

    public var label: String {
        switch self {
        case .ok: "Connected"
        case .needsAuth: "Needs sign-in"
        case .expiringSoon: "Expiring soon"
        case .failed: "Failing"
        case .disabled: "Disabled"
        case .unknown: "Unknown"
        }
    }
}

public struct MCPServer: Identifiable, Sendable, Equatable {
    /// Claude Code lists claude.ai connectors under names with this prefix.
    public static let connectorPrefix = "claude.ai "

    public let harness: Harness
    public let name: String
    public var transport: Transport
    public var target: String?
    public var status: ServerStatus
    public var detail: String?
    public var canSignIn: Bool

    public init(
        harness: Harness,
        name: String,
        transport: Transport,
        target: String? = nil,
        status: ServerStatus,
        detail: String? = nil,
        canSignIn: Bool
    ) {
        self.harness = harness
        self.name = name
        self.transport = transport
        self.target = target
        self.status = status
        self.detail = detail
        self.canSignIn = canSignIn
    }

    public var id: String { "\(harness.rawValue)/\(name)" }

    /// The name without prefixes such as `claude.ai ` or `plugin:<plugin>:`.
    public var displayName: String {
        if name.hasPrefix(Self.connectorPrefix) {
            return name.dropFirst(Self.connectorPrefix.count).trimmingCharacters(in: .whitespaces)
        }
        if name.hasPrefix("plugin:"), let last = name.split(separator: ":").last {
            return String(last)
        }
        return name
    }

    /// Where the server comes from, when the display name hides it.
    public var origin: String? {
        if transport == .connector { return "claude.ai" }
        let parts = name.split(separator: ":")
        if parts.count >= 3, parts[0] == "plugin" { return "plugin \(parts[1])" }
        return nil
    }
}

public struct HarnessSnapshot: Identifiable, Sendable, Equatable {
    public let harness: Harness
    public var installed: Bool
    public var servers: [MCPServer]
    public var checkedAt: Date?
    public var error: String?

    public init(harness: Harness, installed: Bool, servers: [MCPServer], checkedAt: Date?, error: String?) {
        self.harness = harness
        self.installed = installed
        self.servers = servers
        self.checkedAt = checkedAt
        self.error = error
    }

    public var id: Harness { harness }
}

/// A command that signs in to one server, run either in the background or in a terminal.
public struct Invocation: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL
    /// The CLI gives up when stdin isn't a terminal, so background runs go through a pseudo-terminal.
    public var needsTerminal: Bool

    public init(executable: URL, arguments: [String], workingDirectory: URL, needsTerminal: Bool = false) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.needsTerminal = needsTerminal
    }

    /// What to run without a terminal. `script` gives the CLI a pseudo-terminal; its own stdin must
    /// stay open, because at end of input it sends ^D, which cancels the CLI's prompt.
    public var background: (executable: URL, arguments: [String]) {
        guard needsTerminal else { return (executable, arguments) }
        return (URL(fileURLWithPath: "/usr/bin/script"), ["-q", "/dev/null", executable.path] + arguments)
    }

    public var shellCommand: String {
        ([executable.path] + arguments).map(Self.shellQuote).joined(separator: " ")
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

import Foundation

/// A server listed in a harness's config file.
public struct ConfiguredServer: Sendable, Equatable {
    public var name: String
    public var transport: Transport
    public var target: String?
    public var enabled: Bool
    public var canSignIn: Bool

    public init(name: String, transport: Transport, target: String? = nil, enabled: Bool = true, canSignIn: Bool) {
        self.name = name
        self.transport = transport
        self.target = target
        self.enabled = enabled
        self.canSignIn = canSignIn
    }
}

/// What the harness's own CLI reported for a server.
public struct CheckedServer: Sendable, Equatable {
    public var name: String
    public var transport: Transport
    public var target: String?
    public var status: ServerStatus
    public var detail: String?
    public var canSignIn: Bool

    public init(
        name: String,
        transport: Transport,
        target: String? = nil,
        status: ServerStatus,
        detail: String? = nil,
        canSignIn: Bool
    ) {
        self.name = name
        self.transport = transport
        self.target = target
        self.status = status
        self.detail = detail
        self.canSignIn = canSignIn
    }
}

public struct DeepCheck: Sendable, Equatable {
    public var servers: [CheckedServer]
    /// When the check started; anything observed later is newer evidence.
    public var startedAt: Date

    public init(servers: [CheckedServer], startedAt: Date) {
        self.servers = servers
        self.startedAt = startedAt
    }
}

/// Cheap local evidence read between CLI checks.
public enum LocalSignal: Sendable, Equatable {
    /// The harness itself recorded that the server needs sign-in.
    case needsAuth(since: Date)
    /// Stored OAuth token metadata. The token itself is never kept.
    case token(expiresAt: Date?, hasRefreshToken: Bool)
}

public enum StatusMerger {
    /// Warn this long before a token that can't be refreshed expires.
    static let expiryWarning: TimeInterval = 12 * 60 * 60

    public static func merge(
        harness: Harness,
        configured: [ConfiguredServer],
        check: DeepCheck?,
        signals: [String: [LocalSignal]],
        now: Date = .now
    ) -> [MCPServer] {
        var servers: [MCPServer] = []
        var index: [String: Int] = [:]

        for config in configured {
            index[config.name] = servers.count
            servers.append(MCPServer(
                harness: harness,
                name: config.name,
                transport: config.transport,
                target: config.target,
                status: config.enabled ? .unknown : .disabled,
                detail: config.enabled ? "Not checked yet" : "Disabled in config",
                canSignIn: config.canSignIn
            ))
        }

        for checked in check?.servers ?? [] {
            if let position = index[checked.name] {
                servers[position].status = checked.status
                servers[position].detail = checked.detail
                servers[position].canSignIn = checked.canSignIn || servers[position].canSignIn
                if servers[position].transport == .unknown { servers[position].transport = checked.transport }
                if servers[position].target == nil { servers[position].target = checked.target }
            } else {
                index[checked.name] = servers.count
                servers.append(MCPServer(
                    harness: harness,
                    name: checked.name,
                    transport: checked.transport,
                    target: checked.target,
                    status: checked.status,
                    detail: checked.detail,
                    canSignIn: checked.canSignIn
                ))
            }
        }

        let checkedAt = check?.startedAt
        for (name, serverSignals) in signals {
            guard let position = index[name], servers[position].status != .disabled else { continue }
            for signal in serverSignals {
                apply(signal, to: &servers[position], checkedAt: checkedAt, now: now)
            }
        }
        return servers
    }

    private static func apply(_ signal: LocalSignal, to server: inout MCPServer, checkedAt: Date?, now: Date) {
        switch signal {
        case .needsAuth(let since):
            // The harness keeps this flag until the user signs in again, and its sessions skip the
            // server while it's set, even when a CLI check with the stored token still connects.
            // Organisations provision many claude.ai connectors that get flagged without being used,
            // so for those the flag only counts when it's newer than the last check.
            if server.transport == .connector, let checkedAt, since <= checkedAt { return }
            server.detail = server.status == .ok
                ? "\(server.harness.displayName) sessions skip it until you sign in again"
                : "\(server.harness.displayName) reported that it needs sign-in"
            server.status = .needsAuth
        case .token(let expiresAt, let hasRefreshToken):
            guard let expiresAt, !hasRefreshToken else { return }
            if expiresAt <= now {
                // Only trust the expiry if it happened after the last successful check.
                if checkedAt.map({ expiresAt > $0 }) ?? true {
                    server.status = .needsAuth
                    server.detail = "Access token expired and can't be refreshed"
                }
            } else if expiresAt.timeIntervalSince(now) < expiryWarning, server.status == .ok {
                server.status = .expiringSoon(expiresAt)
                server.detail = "Token can't be refreshed and expires soon"
            }
        }
    }
}

/// Decides which problems deserve a badge.
public enum AttentionPolicy {
    /// A claude.ai connector that has never worked on this Mac. Organisations often provision
    /// dozens of these, so they stay out of the badge until they work once.
    public static func isDormant(_ server: MCPServer, seenHealthy: Set<String>) -> Bool {
        server.transport == .connector && server.status != .ok && !seenHealthy.contains(server.id)
    }

    public static func needsAttention(_ server: MCPServer, muted: Set<String>, seenHealthy: Set<String>) -> Bool {
        server.status.isProblem && !muted.contains(server.id) && !isDormant(server, seenHealthy: seenHealthy)
    }
}

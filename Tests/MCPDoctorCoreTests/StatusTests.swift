import Foundation
import Testing
@testable import MCPDoctorCore

@Suite struct StatusMergerTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func checkResultOverridesConfig() throws {
        let servers = StatusMerger.merge(
            harness: .cursor,
            configured: [ConfiguredServer(name: "diagrams", transport: .http, target: "https://diagrams.example.com", canSignIn: true)],
            check: DeepCheck(servers: [CheckedServer(name: "diagrams", transport: .unknown, status: .needsAuth, canSignIn: false)], startedAt: now),
            signals: [:],
            now: now
        )
        let server = try #require(servers.first)
        #expect(servers.count == 1)
        #expect(server.status == .needsAuth)
        #expect(server.transport == .http)
        #expect(server.canSignIn)
    }

    @Test func newerNeedsAuthSignalWins() {
        let check = DeepCheck(servers: [CheckedServer(name: "x", transport: .http, status: .ok, canSignIn: true)], startedAt: now)
        let older = StatusMerger.merge(harness: .claudeCode, configured: [], check: check,
                                       signals: ["x": [.needsAuth(since: now - 60)]], now: now)
        let newer = StatusMerger.merge(harness: .claudeCode, configured: [], check: check,
                                       signals: ["x": [.needsAuth(since: now + 60)]], now: now + 120)
        #expect(older.first?.status == .ok)
        #expect(newer.first?.status == .needsAuth)
    }

    @Test func unrefreshableTokens() {
        let check = DeepCheck(servers: [CheckedServer(name: "x", transport: .http, status: .ok, canSignIn: true)], startedAt: now)
        let soon = now + 3600
        func status(hasRefreshToken: Bool, at time: Date) -> ServerStatus? {
            StatusMerger.merge(
                harness: .claudeCode,
                configured: [],
                check: check,
                signals: ["x": [.token(expiresAt: soon, hasRefreshToken: hasRefreshToken)]],
                now: time
            ).first?.status
        }
        #expect(status(hasRefreshToken: false, at: now) == .expiringSoon(soon))
        #expect(status(hasRefreshToken: true, at: now) == .ok)
        #expect(status(hasRefreshToken: false, at: soon + 1) == .needsAuth)
    }
}

@Suite struct AttentionPolicyTests {
    @Test func dormantConnectorsStayOutOfTheBadge() {
        let connector = MCPServer(harness: .claudeCode, name: "claude.ai Mailer", transport: .connector, status: .needsAuth, canSignIn: true)
        let local = MCPServer(harness: .codex, name: "logs", transport: .http, status: .needsAuth, canSignIn: true)
        #expect(!AttentionPolicy.needsAttention(connector, muted: [], seenHealthy: []))
        #expect(AttentionPolicy.needsAttention(connector, muted: [], seenHealthy: [connector.id]))
        #expect(AttentionPolicy.needsAttention(local, muted: [], seenHealthy: []))
        #expect(!AttentionPolicy.needsAttention(local, muted: [local.id], seenHealthy: []))
    }
}

@Suite struct CompatibilityTests {
    @Test(arguments: [
        (Harness.claudeCode, "error: unknown command 'login'"),
        (.codex, "error: unrecognized subcommand 'app-server'"),
        (.codex, "Method not found"),
        (.cursor, "error: unknown command 'login'"),
    ])
    func explainsMissingCommandsAndMethods(harness: Harness, message: String) {
        let explained = Compatibility.explain(message, harness: harness, action: "sign in")
        #expect(explained.hasPrefix("This version of \(harness.displayName) can't sign in."))
        #expect(explained.contains(harness.testedVersion))
    }

    @Test func leavesOtherErrorsAlone() {
        let message = "OAuth token refresh failed: invalid_client"
        #expect(Compatibility.explain(message, harness: .codex, action: "sign in") == message)
    }

    @Test func rejectsOutputThatCannotBeParsed() {
        #expect(throws: AdapterError.self) {
            try ListOutput.validate([], output: "some new format\nthat we don't understand", harness: .claudeCode, command: "claude mcp list")
        }
    }

    @Test func acceptsGenuinelyEmptyLists() throws {
        let empty = "Checking MCP server health…\n\nNo MCP servers configured. Use `claude mcp add` to add a server.\n"
        #expect(try ListOutput.validate([], output: empty, harness: .claudeCode, command: "claude mcp list").isEmpty)
        #expect(try ListOutput.validate([], output: "", harness: .cursor, command: "cursor-agent mcp list").isEmpty)
    }
}

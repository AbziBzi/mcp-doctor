import Foundation
import Testing
@testable import MCPDoctorCore

// Fixtures mirror real CLI output, with made-up server names.

@Suite struct ClaudeCodeParsingTests {
    @Test func parsesHealthOutput() throws {
        let output = """
        Checking MCP server health…

        claude.ai Claude Docs: https://example.com/docs - ✔ Connected
        claude.ai Metrics: https://example.com/metrics - ! Needs authentication
        claude.ai Transcriber : https://example.com/transcribe - ! Needs authentication
        claude.ai Gateway: https://example.com/gw - ✘ Failed to connect — HTTP 502: Error POSTing - bad gateway
        plugin:acme-db:database: /Users/me/.claude/plugins/run.sh  - ✔ Connected
        logs: https://logs.example.com/mcp (HTTP) - ✔ Connected
        legacy: https://example.com/sse (SSE) - ✘ Failed to connect
        project-tool: npx tool - ⏸ Pending approval
        """
        let servers = ClaudeCodeAdapter.parseList(output)
        try #require(servers.count == 8)
        #expect(servers.map(\.name) == [
            "claude.ai Claude Docs", "claude.ai Metrics", "claude.ai Transcriber", "claude.ai Gateway",
            "plugin:acme-db:database", "logs", "legacy", "project-tool",
        ])
        #expect(servers[0].status == .ok)
        #expect(servers[0].transport == .connector)
        #expect(servers[1].status == .needsAuth)
        #expect(servers[3].status == .failed)
        #expect(servers[3].detail == "HTTP 502: Error POSTing - bad gateway")
        #expect(servers[4].transport == .stdio)
        #expect(servers[4].target == "/Users/me/.claude/plugins/run.sh")
        #expect(!servers[4].canSignIn)
        #expect(servers[5].transport == .http)
        #expect(servers[5].target == "https://logs.example.com/mcp")
        #expect(servers[6].transport == .sse)
        #expect(servers[7].status == .unknown)
    }

    @Test(arguments: [
        ("Connected", ServerStatus.ok),
        ("Needs authentication", .needsAuth),
        ("Pending approval", .unknown),
        ("Disabled", .disabled),
        ("Failed to connect — timeout", .failed),
        ("Something new", .unknown),
    ])
    func parsesStatus(text: String, expected: ServerStatus) {
        #expect(ClaudeCodeAdapter.parseStatus(text).0 == expected)
    }

    @Test func readsTokenMetadataWithoutKeepingTokens() {
        let json = """
        {"claudeAiOauth":{},"mcpOAuth":{
          "diagrams|1":{"serverName":"diagrams","accessToken":"a","refreshToken":"r","expiresAt":1792754816290},
          "assistant|2":{"serverName":"assistant","accessToken":"a"}
        }}
        """
        let plain = ClaudeCodeAdapter.parseCredentials(Data(json.utf8))
        #expect(plain["diagrams"] == .token(expiresAt: Date(timeIntervalSince1970: 1_792_754_816.290), hasRefreshToken: true))
        #expect(plain["assistant"] == .token(expiresAt: nil, hasRefreshToken: false))

        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        #expect(ClaudeCodeAdapter.parseCredentials(Data(hex.utf8)) == plain)
    }

    @Test func rejectsMalformedHex() {
        #expect(ClaudeCodeAdapter.hexDecoded("abc") == nil)
        #expect(ClaudeCodeAdapter.hexDecoded("zz") == nil)
        #expect(ClaudeCodeAdapter.hexDecoded("7b7d") == Data("{}".utf8))
    }
}

@Suite struct CodexParsingTests {
    @Test func parsesConfigList() throws {
        let json = """
        [{"name":"diagrams","enabled":true,"transport":{"type":"streamable_http","url":"https://diagrams.example.com/mcp"},"auth_status":"o_auth"},
         {"name":"sandbox","enabled":true,"transport":{"type":"streamable_http","url":"https://sandbox.example.com/mcp"},"auth_status":"bearer_token"},
         {"name":"database","enabled":false,"transport":{"type":"stdio","command":"bash"},"auth_status":"unsupported"}]
        """
        let servers = CodexAdapter.parseConfigList(Data(json.utf8))
        try #require(servers.count == 3)
        #expect(servers.map(\.name) == ["diagrams", "sandbox", "database"])
        #expect(servers[0].canSignIn)
        #expect(!servers[1].canSignIn)
        #expect(servers[2].transport == .stdio)
        #expect(!servers[2].enabled)
    }

    @Test func scansAppServerStreamForResponse() throws {
        let scanner = ResponseScanner(responseID: 2)
        let notification = #"{"method":"remoteControl/status/changed","params":{"status":"disabled"}}"# + "\n"
        let initialize = #"{"id":1,"result":{"userAgent":"codex"}}"# + "\n"
        let response = #"{"id":2,"result":{"data":["#
            + #"{"name":"diagrams","authStatus":"notLoggedIn","toolsError":"MCP startup failed: OAuth authorization required","tools":{}},"#
            + #"{"name":"logs","authStatus":"oAuth","toolsError":"MCP startup failed: OAuth token refresh failed: invalid_client","httpOrigin":"https://logs.example.com","tools":{}},"#
            + #"{"name":"broken","authStatus":"bearerToken","toolsError":"connection refused","httpOrigin":"https://broken.example.com","tools":{}},"#
            + #"{"name":"database","authStatus":"unsupported","tools":{"q":{"name":"q"}}}"#
            + #"],"nextCursor":null}}"# + "\n"

        // Deliver the response in two chunks to exercise line reassembly.
        let all = Data((notification + initialize + response).utf8)
        let split = all.count - 40
        #expect(!scanner.consume(all.prefix(split)))
        #expect(scanner.consume(all.suffix(from: split)))

        let servers = CodexAdapter.parseStatusResponse(try #require(scanner.response))
        try #require(servers.count == 4)
        #expect(servers.map(\.status) == [.needsAuth, .needsAuth, .failed, .ok])
        #expect(servers[0].detail == "OAuth authorization required")
        #expect(servers[1].detail == "OAuth token refresh failed: invalid_client")
        #expect(servers[1].canSignIn)
        #expect(servers[3].transport == .stdio)
    }

    @Test func surfacesRPCErrors() {
        let scanner = ResponseScanner(responseID: 2)
        #expect(scanner.consume(Data((#"{"id":1,"error":{"code":-1,"message":"not initialized"}}"# + "\n").utf8)))
        #expect(scanner.response == nil)
        #expect(scanner.errorMessage == "not initialized")
    }

    @Test func recognisesBothAuthSpellings() {
        #expect(CodexAdapter.usesOAuth("o_auth"))
        #expect(CodexAdapter.usesOAuth("notLoggedIn"))
        #expect(!CodexAdapter.usesOAuth("bearer_token"))
        #expect(!CodexAdapter.usesOAuth(nil))
    }
}

@Suite struct CursorParsingTests {
    @Test func parsesList() {
        let output = "\u{1B}[2Kdatabase: ready\nassistant: requires_authentication\nother: error\nLoading…\n"
        let servers = CursorAdapter.parseList(output)
        #expect(servers.map(\.name) == ["database", "assistant", "other"])
        #expect(servers.map(\.status) == [.ok, .needsAuth, .failed])
    }

    @Test func derivesAuthFilePath() {
        let adapter = CursorAdapter(home: URL(fileURLWithPath: "/Users/jane.doe"))
        #expect(adapter.authFileURL.path == "/Users/jane.doe/.cursor/projects/Users-jane-doe/mcp-auth.json")
    }
}

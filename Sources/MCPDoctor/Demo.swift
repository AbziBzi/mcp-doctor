import Foundation
import MCPDoctorCore

/// Made-up servers for screenshots and for trying the panel: `MCPDoctor --demo`.
/// They go through the same merge and attention logic as real check results.
struct DemoAdapter: HarnessAdapter {
    let harness: Harness
    let servers: [CheckedServer]

    var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    var watchedFiles: [URL] { [] }

    func isInstalled(env: ShellEnvironment) -> Bool { true }

    func configuredServers(env: ShellEnvironment) async -> [ConfiguredServer] { [] }

    func deepCheck(env: ShellEnvironment) async throws -> DeepCheck {
        DeepCheck(servers: servers, startedAt: .now)
    }

    func signInInvocation(for server: MCPServer, env: ShellEnvironment) -> Invocation? { nil }
}

extension Doctor {
    static func demo() -> Doctor {
        Doctor(
            adapters: [
                DemoAdapter(harness: .claudeCode, servers: [
                    .http("github"), .http("sentry"), .http("context7"),
                    .stdio("playwright"), .stdio("filesystem"), .stdio("postgres"),
                    .connector("Google Drive"), .connector("Gmail"), .connector("Slack"),
                    .connector("Notion"), .connector("Figma"), .connector("Linear"),
                    .connector("Asana", status: .needsAuth), .connector("HubSpot", status: .needsAuth),
                ]),
                DemoAdapter(harness: .codex, servers: [
                    .http("linear", status: .needsAuth, detail: "OAuth token refresh failed: invalid_grant"),
                    .http("github"), .http("sentry"), .http("context7"), .stdio("playwright"),
                ]),
                DemoAdapter(harness: .cursor, servers: [
                    .http("notion", status: .needsAuth), .http("github"), .stdio("figma"),
                ]),
            ],
            environment: ShellEnvironment(variables: [:])
        )
    }
}

private extension CheckedServer {
    static func http(_ name: String, status: ServerStatus = .ok, detail: String? = nil) -> CheckedServer {
        CheckedServer(
            name: name,
            transport: .http,
            target: "https://\(name).example.com/mcp",
            status: status,
            detail: detail,
            canSignIn: true
        )
    }

    static func stdio(_ name: String) -> CheckedServer {
        CheckedServer(name: name, transport: .stdio, target: "npx \(name)-mcp", status: .ok, canSignIn: false)
    }

    static func connector(_ name: String, status: ServerStatus = .ok) -> CheckedServer {
        CheckedServer(name: MCPServer.connectorPrefix + name, transport: .connector, status: status, canSignIn: true)
    }
}

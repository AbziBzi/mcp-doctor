import Foundation
import Synchronization
import Testing
@testable import MCPDoctorCore

/// Reports fixed servers, or throws, and counts how often it was checked.
private struct FakeAdapter: HarnessAdapter {
    final class Counter: Sendable {
        let value = Mutex(0)
    }

    let harness: Harness
    var servers: [CheckedServer] = []
    var error: AdapterError?
    let checks = Counter()

    var home: URL { URL(fileURLWithPath: "/tmp") }
    var watchedFiles: [URL] { [] }

    func isInstalled(env: ShellEnvironment) -> Bool { true }

    func configuredServers(env: ShellEnvironment) async -> [ConfiguredServer] { [] }

    func deepCheck(env: ShellEnvironment) async throws -> DeepCheck {
        checks.value.withLock { $0 += 1 }
        try await Task.sleep(for: .milliseconds(100))
        if let error { throw error }
        return DeepCheck(servers: servers, startedAt: .now)
    }
}

@Suite struct DoctorTests {
    let environment = ShellEnvironment(variables: [:])

    @Test func concurrentChecksShareOneRun() async {
        let adapter = FakeAdapter(harness: .codex, servers: [CheckedServer(name: "x", transport: .http, status: .ok, canSignIn: true)])
        let doctor = Doctor(adapters: [adapter], environment: environment)
        async let first: Void = doctor.deepCheck(.codex)
        async let second: Void = doctor.deepCheck(.codex)
        _ = await (first, second)
        #expect(adapter.checks.value.withLock { $0 } == 1)
        #expect(await doctor.snapshots().first { $0.harness == .codex }?.servers.first?.status == .ok)
    }

    @Test func missingHarnessIsNotAnError() async throws {
        let doctor = Doctor(adapters: [FakeAdapter(harness: .cursor, error: .notInstalled("cursor-agent"))], environment: environment)
        await doctor.deepCheck(.cursor)
        let snapshot = try #require(await doctor.snapshots().first { $0.harness == .cursor })
        #expect(!snapshot.installed)
        #expect(snapshot.error == nil)
    }

    @Test func outdatedHarnessExplainsItself() async throws {
        let doctor = Doctor(adapters: [FakeAdapter(harness: .codex, error: .commandFailed("Method not found"))], environment: environment)
        await doctor.deepCheck(.codex)
        let snapshot = try #require(await doctor.snapshots().first { $0.harness == .codex })
        #expect(snapshot.error?.hasPrefix("This version of Codex can't report MCP server status.") == true)
    }
}

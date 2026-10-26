import Foundation
import Testing
@testable import MCPDoctorCore

@Suite struct CommandRunnerTests {
    let shell = URL(fileURLWithPath: "/bin/sh")

    @Test func collectsOutputAndExitStatus() async {
        let result = await CommandRunner.run(shell, arguments: ["-c", "echo out; echo err >&2; exit 3"], timeout: 5)
        #expect(result.output == "out\n")
        #expect(result.errorOutput == "err\n")
        #expect(result.exitStatus == 3)
        #expect(!result.succeeded)
        #expect(result.failureSummary == "err")
    }

    @Test func passesInput() async {
        let result = await CommandRunner.run(URL(fileURLWithPath: "/bin/cat"), input: Data("hello".utf8), timeout: 5)
        #expect(result.succeeded)
        #expect(result.output == "hello")
    }

    @Test func stopsAfterTimeout() async {
        let started = Date.now
        let result = await CommandRunner.run(shell, arguments: ["-c", "sleep 5"], timeout: 0.2)
        #expect(result.timedOut)
        #expect(!result.succeeded)
        #expect(Date.now.timeIntervalSince(started) < 3)
    }

    @Test func stopsWhenOutputSaysSo() async {
        let started = Date.now
        let result = await CommandRunner.run(shell, arguments: ["-c", "echo ready; sleep 5"], timeout: 10) { chunk in
            String(decoding: chunk, as: UTF8.self).contains("ready")
        }
        #expect(result.output.contains("ready"))
        #expect(Date.now.timeIntervalSince(started) < 3)
    }

    @Test func stopsWhenCancelled() async {
        let started = Date.now
        let run = Task { await CommandRunner.run(shell, arguments: ["-c", "sleep 5"], timeout: 10) }
        try? await Task.sleep(for: .milliseconds(200))
        run.cancel()
        let result = await run.value
        #expect(!result.succeeded)
        #expect(Date.now.timeIntervalSince(started) < 3)
    }

    @Test func reportsLaunchFailures() async {
        let result = await CommandRunner.run(URL(fileURLWithPath: "/nonexistent/tool"), timeout: 5)
        #expect(result.launchError != nil)
        #expect(!result.succeeded)
    }
}

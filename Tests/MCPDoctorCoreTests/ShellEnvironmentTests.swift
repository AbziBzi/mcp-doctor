import Foundation
import Testing
@testable import MCPDoctorCore

@Suite struct ShellEnvironmentTests {
    @Test func parsesShellOutputBetweenMarkers() {
        var data = Data("motd noise\n\(ShellEnvironment.startMarker)".utf8)
        data.append(Data("PATH=/a:/b\0HOME=/Users/me\0EMPTY=\0".utf8))
        data.append(Data(ShellEnvironment.endMarker.utf8))
        #expect(ShellEnvironment.parse(data) == ["PATH": "/a:/b", "HOME": "/Users/me", "EMPTY": ""])
    }

    @Test func addsUsualInstallLocationsToPath() {
        let variables = ShellEnvironment.withFallbackPath(["PATH": "/usr/bin:/opt/homebrew/bin"], home: URL(fileURLWithPath: "/Users/me"))
        #expect(variables["PATH"] == "/usr/bin:/opt/homebrew/bin:/Users/me/.local/bin:/usr/local/bin")
    }

    @Test func quotesShellArguments() {
        #expect(Invocation.shellQuote("claude.ai Bob's") == #"'claude.ai Bob'\''s'"#)
    }
}

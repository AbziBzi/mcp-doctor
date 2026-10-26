import Foundation
import MCPDoctorCore

/// `MCPDoctor --dump` prints what the panel would show, for debugging and bug reports.
enum Dump {
    static func run() async {
        let doctor = Doctor.standard()
        for harness in Harness.allCases {
            let started = Date.now
            await doctor.quickRefresh(harness, forceCredentials: true)
            await doctor.deepCheck(harness)
            let seconds = Date.now.timeIntervalSince(started).formatted(.number.precision(.fractionLength(1)))
            print("checked \(harness.displayName) in \(seconds)s")
        }

        for snapshot in await doctor.snapshots() {
            print("\n" + heading(for: snapshot))
            for server in snapshot.servers.sorted(by: { ($0.status.sortRank, $0.name) < ($1.status.sortRank, $1.name) }) {
                let columns = [
                    server.status.label.padding(toLength: 14, withPad: " ", startingAt: 0),
                    server.name.padding(toLength: 40, withPad: " ", startingAt: 0),
                    server.transport.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0),
                    server.canSignIn ? "sign-in" : "       ",
                    server.detail ?? "",
                ]
                print("  " + columns.joined(separator: " "))
            }
        }
    }

    private static func heading(for snapshot: HarnessSnapshot) -> String {
        var heading = snapshot.harness.displayName
        if !snapshot.installed { heading += " (not installed)" }
        if let error = snapshot.error { heading += " (error: \(error))" }
        return heading
    }
}

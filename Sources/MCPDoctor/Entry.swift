import AppKit

@main
enum Entry {
    static func main() {
        // Writing to a CLI that has already exited would otherwise terminate the app.
        signal(SIGPIPE, SIG_IGN)

        if CommandLine.arguments.contains("--dump") {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await Dump.run()
                done.signal()
            }
            done.wait()
            return
        }

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

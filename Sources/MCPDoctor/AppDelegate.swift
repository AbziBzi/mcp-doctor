import AppKit
import MCPDoctorCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        let model = arguments.contains("--demo")
            ? AppModel(doctor: .demo(), defaults: nil)
            : AppModel(doctor: .standard())
        let scheduler = Scheduler(model: model)
        let statusItem = StatusItemController(model: model, scheduler: scheduler)
        self.statusItem = statusItem
        scheduler.start()

        // Debugging aids: open the panel at launch and keep it open, optionally expanded.
        if arguments.contains("--show-panel") {
            Task {
                // The status item's button has no window until the menu bar lays it out.
                try? await Task.sleep(for: .milliseconds(500))
                statusItem.showPanel(pinned: true, expanded: arguments.contains("--expanded"))
            }
        }
    }
}

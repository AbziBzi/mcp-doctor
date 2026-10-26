import Observation
import ServiceManagement

/// "Open at login", backed by the app's login item registration.
@MainActor
@Observable
final class LoginItem {
    private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    /// Why the last change didn't take effect, if it didn't.
    private(set) var problem: String?

    func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        problem = nil
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            problem = error.localizedDescription
        }
        if service.status == .requiresApproval {
            problem = "Allow MCP Doctor under Login Items in System Settings."
            SMAppService.openSystemSettingsLoginItems()
        }
        isEnabled = service.status == .enabled
    }
}

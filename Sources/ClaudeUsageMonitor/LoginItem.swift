import Foundation
import ServiceManagement

/// Thin wrapper over SMAppService for "launch at login". Best-effort: registration
/// sticks reliably only when the app runs from a stable path (e.g. /Applications).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("LoginItem toggle failed: \(error.localizedDescription)")
        }
    }
}

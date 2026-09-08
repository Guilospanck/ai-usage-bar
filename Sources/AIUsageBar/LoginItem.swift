import Foundation
import ServiceManagement

/// Thin wrapper over SMAppService for the "Launch at login" toggle.
/// Only works when the binary is running from inside a signed/bundled `.app`;
/// from a bare `swift run` binary registration will fail and we report false.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var isAvailable: Bool {
        // Registration needs a real app bundle.
        Bundle.main.bundleIdentifier != nil
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            NSLog("LoginItem toggle failed: \(error.localizedDescription)")
            return false
        }
    }
}

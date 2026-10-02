import Foundation
import ServiceManagement

/// Registers this app with `SMAppService` so macOS launches it at login.
/// The toggle stores intent. Whether it actually starts is `SMAppService.mainApp.status`.
enum LaunchAtLogin {
    private static let preferenceKey = "launchAtLogin"

    static let approvalMessage = "Turn on CursorBar in System Settings → General → Login Items."

    /// Off until the user turns the setting on. A missing key stays off.
    static var wantsEnabled: Bool {
        UserDefaults.standard.bool(forKey: preferenceKey)
    }

    /// `nil` when login launch is on, or when the user turned it off.
    /// A string means macOS still will not start the app.
    @discardableResult
    static func sync() -> String? {
        guard wantsEnabled else { return nil }
        return enable()
    }

    @discardableResult
    static func enable() -> String? {
        UserDefaults.standard.set(true, forKey: preferenceKey)
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                return nil
            case .requiresApproval:
                return approvalMessage
            case .notRegistered, .notFound:
                try SMAppService.mainApp.register()
            @unknown default:
                try SMAppService.mainApp.register()
            }
        } catch {
            return "Open at login failed: \(error.localizedDescription)"
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            return nil
        case .requiresApproval:
            return approvalMessage
        case .notRegistered, .notFound:
            return "macOS did not enable open at login."
        @unknown default:
            return "macOS did not enable open at login."
        }
    }

    @discardableResult
    static func disable() -> String? {
        UserDefaults.standard.set(false, forKey: preferenceKey)
        switch SMAppService.mainApp.status {
        case .notRegistered, .notFound:
            return nil
        case .enabled, .requiresApproval:
            break
        @unknown default:
            break
        }
        do {
            try SMAppService.mainApp.unregister()
            return nil
        } catch {
            return "Could not turn off open at login: \(error.localizedDescription)"
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

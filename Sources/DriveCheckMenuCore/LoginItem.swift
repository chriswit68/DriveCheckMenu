import Foundation
import ServiceManagement

public enum LoginItemError: LocalizedError {
    case notBundled
    case registrationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notBundled:
            return "Der Login-Start steht nur in der App-Hülle zur Verfügung."
        case .registrationFailed(let message):
            return message
        }
    }
}

public enum LoginItem {
    public static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    public static var isEnabled: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    public static var statusText: String {
        guard isSupported else { return "Nur im App-Bundle verfügbar" }
        switch SMAppService.mainApp.status {
        case .enabled: return "Aktiv"
        case .notRegistered: return "Nicht registriert"
        case .notFound: return "Nicht gefunden"
        case .requiresApproval: return "Wartet auf Freigabe in den Systemeinstellungen"
        @unknown default: return "Unbekannt"
        }
    }

    public static func set(enabled: Bool) throws {
        guard isSupported else { throw LoginItemError.notBundled }

        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            do {
                try SMAppService.mainApp.register()
            } catch {
                throw LoginItemError.registrationFailed(error.localizedDescription)
            }
        } else {
            guard SMAppService.mainApp.status != .notRegistered else { return }
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                // Unregistering an already removed entry is not an error for the UI.
                if SMAppService.mainApp.status != .notRegistered {
                    throw LoginItemError.registrationFailed(error.localizedDescription)
                }
            }
        }
    }
}

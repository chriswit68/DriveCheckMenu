import AppKit

/// Seit macOS 26 (Tahoe) darf eine App ihr Menüleistensymbol erst anzeigen, wenn sie in
/// „Systemeinstellungen → Menüleiste → In der Menüleiste erlauben“ freigegeben wurde.
///
/// `NSStatusItem` lässt sich trotzdem fehlerfrei erzeugen (`isVisible == true`), das Symbol
/// bleibt aber unsichtbar – die App wirkt dadurch, als würde sie nicht starten.
enum MenuBarPermission {
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension?MenuBar"
    )!

    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}

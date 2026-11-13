import AppKit
import DriveCheckMenuCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState!
    private var statusItemController: StatusItemController!

    private var menuBarVisibilityFailures = 0
    private static let menuBarAlertShownKey = "DriveCheckMenu.menuBarPermissionAlertShown"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        state = AppState()
        statusItemController = StatusItemController(state: state)
        statusItemController.install()
        state.start()

        Notifier.shared.requestAuthorization()

        if let simulation = state.simulationMode {
            NSLog("DriveCheckMenu läuft im Simulationsmodus: %@", simulation.rawValue)
        }

        NSLog("DriveCheckMenu gestartet – %@", statusItemController.diagnostics)

        // Das Menüleistensymbol wird erst nach dem ersten Runloop-Durchlauf platziert.
        scheduleMenuBarVisibilityCheck(after: 2)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        statusItemController?.refreshVisibilityState()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Ein erneuter Start (z. B. per Finder oder `open`) soll die Einstellungen zeigen,
        // statt scheinbar wirkungslos zu bleiben – besonders, wenn das Menüleistensymbol
        // wegen der macOS-Freigabe unsichtbar ist.
        statusItemController?.showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: Menüleisten-Freigabe

    private func evaluateMenuBarVisibility() {
        guard let controller = statusItemController else { return }
        controller.refreshVisibilityState()

        if controller.isStatusItemVisible {
            if menuBarVisibilityFailures > 0 {
                NSLog("DriveCheckMenu: Menüleistensymbol ist wieder sichtbar.")
            } else {
                NSLog("DriveCheckMenu: Menüleistensymbol sichtbar – %@", controller.diagnostics)
            }
            menuBarVisibilityFailures = 0
            return
        }

        menuBarVisibilityFailures += 1
        NSLog(
            "DriveCheckMenu: Menüleistensymbol nicht sichtbar (Prüfung %d/12) – %@",
            menuBarVisibilityFailures,
            controller.diagnostics
        )
        if menuBarVisibilityFailures >= 2 {
            presentMenuBarPermissionAlertIfNeeded()
        }

        guard menuBarVisibilityFailures < 12 else { return }
        scheduleMenuBarVisibilityCheck(after: 5)
    }

    private func scheduleMenuBarVisibilityCheck(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                self?.evaluateMenuBarVisibility()
            }
        }
    }

    private func presentMenuBarPermissionAlertIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.menuBarAlertShownKey) else { return }
        defaults.set(true, forKey: Self.menuBarAlertShownKey)

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Kein Symbol in der Menüleiste sichtbar"
        alert.informativeText = """
        DriveCheckMenu läuft, aber macOS zeigt das Symbol nicht an. Seit macOS 26 (Tahoe) \
        müssen neue Menüleisten-Apps einmalig freigegeben werden.

        Öffnen Sie „Systemeinstellungen → Menüleiste“ und erlauben Sie DriveCheckMenu unter \
        „In der Menüleiste erlauben“. Falls der Schalter wirkungslos bleibt, hilft ein \
        Neustart der App oder ein erneuter Login.

        Sie erreichen diese Einstellungen später auch über „Einstellungen → Allgemein“.
        """
        alert.addButton(withTitle: "Menüleisten-Einstellungen öffnen")
        alert.addButton(withTitle: "Später")

        if alert.runModal() == .alertFirstButtonReturn {
            MenuBarPermission.openSettings()
        }
    }
}

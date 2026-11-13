import AppKit
import DriveCheckMenuCore
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(state: AppState) {
        let rootView = SettingsView(state: state)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "DriveCheckMenu – Einstellungen"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 760, height: 620))
        window.minSize = NSSize(width: 700, height: 540)
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

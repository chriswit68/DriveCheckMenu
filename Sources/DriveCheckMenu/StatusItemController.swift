import AppKit
import DriveCheckMenuCore
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let state: AppState
    private var statusItem: NSStatusItem!
    private var settingsWindowController: SettingsWindowController?
    private var lastSnapshot: MonitorSnapshot?

    init(state: AppState) {
        self.state = state
        super.init()
        state.onSnapshot = { [weak self] snapshot in
            self?.apply(snapshot: snapshot)
        }
    }

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "DriveCheckMenu – Status wird ermittelt …"
        updateIcon(level: .ok, tooltip: "DriveCheckMenu – Status wird ermittelt …")
    }

    /// Ob das Menüleistensymbol tatsächlich auf einem Bildschirm liegt. Unter macOS 26 und
    /// neuer lässt sich ein `NSStatusItem` fehlerfrei erzeugen, während das Symbol wegen der
    /// Menüleisten-Freigabe unsichtbar bleibt.
    var isStatusItemVisible: Bool {
        guard let window = statusItem?.button?.window else { return false }
        guard window.isVisible, window.alphaValue > 0 else { return false }
        guard window.occlusionState.contains(.visible) else { return false }
        guard let screen = window.screen else { return false }
        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else { return false }
        return frame.intersects(screen.frame)
    }

    func refreshVisibilityState() {
        state.setMenuBarItemVisible(isStatusItemVisible)
    }

    // MARK: Snapshot

    private func apply(snapshot: MonitorSnapshot) {
        lastSnapshot = snapshot
        updateIcon(level: snapshot.overall, tooltip: tooltip(for: snapshot))
    }

    private func tooltip(for snapshot: MonitorSnapshot) -> String {
        var lines = ["DriveCheckMenu – \(snapshot.overallSummary)"]
        for status in snapshot.monitoredDrives where status.health != .ok {
            lines.append("\(status.drive.displayName): \(status.shortStatusText)")
        }
        for status in snapshot.monitoredRaids where status.health != .ok {
            lines.append("\(status.raid.displayName): \(status.raid.status)")
        }
        return lines.joined(separator: "\n")
    }

    private func updateIcon(level: HealthLevel, tooltip: String) {
        guard let button = statusItem.button else { return }

        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "Laufwerksstatus")?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        button.image = image
        // Bei „ok“/„unknown“ keine feste Tint-Farbe setzen: Das Template-Bild passt sich
        // dann automatisch an die Menüleiste an (hell auf dunkel, dunkel auf hell) und
        // bleibt deutlich sichtbar. Nur Warnungen und Probleme werden eingefärbt.
        button.contentTintColor = color(for: level)
        button.toolTip = tooltip
    }

    private func color(for level: HealthLevel) -> NSColor? {
        switch level {
        case .ok, .unknown:
            return nil
        case .warning:
            return .systemYellow
        case .problem:
            return .systemRed
        }
    }

    // MARK: Click handling

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isSecondaryClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)

        if isSecondaryClick {
            showSettings()
        } else {
            showStatusMenu()
        }
    }

    private func showStatusMenu() {
        guard statusItem.menu == nil else { return }
        let menu = StatusMenuBuilder.build(state: state, target: self)
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    // MARK: Actions

    @objc func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(state: state)
        }
        settingsWindowController?.showSettings()
    }

    @objc func refreshNow() {
        state.refresh()
    }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    @objc func startSelfTest(_ sender: NSMenuItem) {
        guard let status = sender.representedObject as? DriveStatus else { return }
        state.startSelfTest(for: status)
    }

    @objc func startSelfTestWithAdministrator(_ sender: NSMenuItem) {
        guard let status = sender.representedObject as? DriveStatus else { return }
        state.startSelfTestWithAdministrator(for: status)
    }

    // MARK: Diagnostics

    /// Used by the `--smoke` launch mode to verify UI construction without screen access.
    var diagnostics: String {
        let hasItem = statusItem != nil
        let hasImage = statusItem?.button?.image != nil
        let settingsVisible = settingsWindowController?.window?.isVisible == true
        let tabs = (settingsWindowController?.window?.contentViewController as? NSHostingController<SettingsView>) != nil
        let menuItems = state.snapshot == nil
            ? -1
            : StatusMenuBuilder.build(state: state, target: self).items.count
        let buttonWindow = statusItem?.button?.window
        let windowFrame = buttonWindow.map { NSStringFromRect($0.frame) } ?? "nil"
        let windowVisible = buttonWindow?.isVisible ?? false
        let windowLevel = buttonWindow?.level.rawValue ?? -1
        let screen = buttonWindow?.screen.map { NSStringFromRect($0.frame) } ?? "nil"
        let occlusion = buttonWindow?.occlusionState.contains(.visible) ?? false
        return "statusItem=\(hasItem) image=\(hasImage) statusVisible=\(isStatusItemVisible) settingsWindow=\(settingsVisible) hostingView=\(tabs) menuItems=\(menuItems) statusWindow=\(windowFrame) visible=\(windowVisible) occlusion=\(occlusion) level=\(windowLevel) screen=\(screen)"
    }
}

enum MenuIcons {
    static func dot(_ level: HealthLevel) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()
        let color: NSColor
        switch level {
        case .ok: color = .systemGreen
        case .unknown: color = .secondaryLabelColor
        case .warning: color = .systemYellow
        case .problem: color = .systemRed
        }
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

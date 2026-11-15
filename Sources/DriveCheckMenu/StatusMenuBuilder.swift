import AppKit
import DriveCheckMenuCore

@MainActor
enum StatusMenuBuilder {
    static func build(state: AppState, target: StatusItemController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        guard let snapshot = state.snapshot else {
            addInfo(to: menu, title: "Status wird ermittelt …")
            menu.addItem(.separator())
            menu.addItem(actionItem("Einstellungen …", action: #selector(StatusItemController.showSettings), target: target, key: ","))
            menu.addItem(actionItem("Beenden", action: #selector(StatusItemController.quit), target: target, key: "q"))
            return menu
        }

        let header = NSMenuItem(title: snapshot.overallSummary, action: nil, keyEquivalent: "")
        header.image = MenuIcons.dot(snapshot.overall)
        header.isEnabled = false
        menu.addItem(header)

        if let simulation = state.simulationMode {
            addInfo(to: menu, title: "Simulationsmodus: \(simulation.rawValue)")
        }

        if snapshot.monitoredDrives.isEmpty && snapshot.monitoredRaids.isEmpty {
            addInfo(to: menu, title: "Keine Laufwerke ausgewählt")
        }

        if !snapshot.monitoredDrives.isEmpty {
            menu.addItem(.separator())
            addSectionTitle(to: menu, title: "Laufwerke")
            for status in snapshot.monitoredDrives {
                menu.addItem(driveItem(status: status, state: state, target: target))
            }
        }

        if !snapshot.monitoredRaids.isEmpty {
            menu.addItem(.separator())
            addSectionTitle(to: menu, title: "RAID")
            for status in snapshot.monitoredRaids {
                menu.addItem(raidItem(status: status))
            }
        }

        if state.settings.useSmartctl && snapshot.smartctlPath == nil {
            menu.addItem(.separator())
            addInfo(to: menu, title: "smartctl nicht gefunden – nur Basisstatus via diskutil")
        }

        menu.addItem(.separator())

        let lastCheck = NSMenuItem(
            title: "Letzte Prüfung: \(dateFormatter.string(from: snapshot.date))",
            action: nil,
            keyEquivalent: ""
        )
        lastCheck.isEnabled = false
        menu.addItem(lastCheck)

        menu.addItem(actionItem("Jetzt aktualisieren", action: #selector(StatusItemController.refreshNow), target: target, key: "r"))
        menu.addItem(.separator())
        menu.addItem(actionItem("Einstellungen …", action: #selector(StatusItemController.showSettings), target: target, key: ","))
        menu.addItem(actionItem("Über DriveCheckMenu", action: #selector(StatusItemController.showAbout), target: target))
        menu.addItem(.separator())
        menu.addItem(actionItem("Beenden", action: #selector(StatusItemController.quit), target: target, key: "q"))

        return menu
    }

    // MARK: Drive

    private static func driveItem(status: DriveStatus, state: AppState, target: StatusItemController) -> NSMenuItem {
        let item = NSMenuItem(title: "\(status.drive.displayName) – \(status.shortStatusText)", action: nil, keyEquivalent: "")
        item.image = MenuIcons.dot(status.health)
        item.isEnabled = true

        let submenu = NSMenu()
        submenu.autoenablesItems = false

        addInfo(to: submenu, title: "Modell: \(status.drive.displayName)")
        addInfo(to: submenu, title: "Seriennummer: \(status.drive.serial ?? "–")")
        addInfo(to: submenu, title: "Größe: \(status.drive.sizeText)")
        if let usage = status.usage {
            addInfo(to: submenu, title: usage.summaryText)
        }
        addInfo(to: submenu, title: "Anschluss: \(status.drive.protocolName) · \(status.drive.kindText) · \(status.drive.locationText)")
        addInfo(to: submenu, title: "Gerät: \(status.isConnected ? "/dev/\(status.drive.bsdName)" : "nicht verbunden")")

        if let smart = status.smart {
            submenu.addItem(.separator())
            addInfo(to: submenu, title: "SMART-Quelle: \(smart.source.label)")
            addInfo(to: submenu, title: "SMART-Gesamtstatus: \(smartStatusText(smart))")
            if let temperature = smart.temperatureCelsius {
                var text = "Temperatur: \(Format.number(temperature)) °C"
                if !smart.temperatureSensors.isEmpty {
                    text += " (Sensoren: \(smart.temperatureSensors.map { Format.number($0) }.joined(separator: ", ")) °C)"
                }
                addInfo(to: submenu, title: text)
            }
            if let used = smart.percentageUsed {
                addInfo(to: submenu, title: "Verschleiß: \(Format.number(used)) % verbraucht")
            }
            if let wear = smart.wearLevelingPercent {
                addInfo(to: submenu, title: "Verschleiß (SATA): \(Format.number(wear)) % verbraucht")
            }
            if let spare = smart.availableSpare {
                var text = "Verfügbare Reserve: \(Format.number(spare)) %"
                if let threshold = smart.availableSpareThreshold {
                    text += " (Schwelle \(Format.number(threshold)) %)"
                }
                addInfo(to: submenu, title: text)
            }
            if let mediaErrors = smart.mediaErrors {
                addInfo(to: submenu, title: "Medienfehler: \(mediaErrors)")
            }
            if let errorEntries = smart.errorLogEntries {
                addInfo(to: submenu, title: "Fehlerprotokoll: \(errorEntries) Einträge")
            }
            if let hours = smart.powerOnHours {
                addInfo(to: submenu, title: "Betriebsstunden: \(Format.hours(hours))")
            }
            if let cycles = smart.powerCycles {
                addInfo(to: submenu, title: "Einschaltzyklen: \(cycles)")
            }
            if let shutdowns = smart.unsafeShutdowns {
                addInfo(to: submenu, title: "Unsichere Shutdowns: \(shutdowns)")
            }
            if let reallocated = smart.reallocatedSectors {
                addInfo(to: submenu, title: "Wiederzugewiesene Sektoren: \(reallocated)")
            }
            if let pending = smart.pendingSectors {
                addInfo(to: submenu, title: "Schwebende Sektoren: \(pending)")
            }
            if let uncorrectable = smart.uncorrectableSectors {
                addInfo(to: submenu, title: "Nicht korrigierbare Sektoren: \(uncorrectable)")
            }
            if let selfTest = smart.lastSelfTest, !selfTest.isEmpty {
                addInfo(to: submenu, title: "Letzter Selbsttest: \(selfTest)")
            }
            if !smart.messages.isEmpty {
                for message in smart.messages.prefix(4) {
                    addInfo(to: submenu, title: "Hinweis: \(message)")
                }
            }
        }

        submenu.addItem(.separator())
        for reason in status.reasons {
            addInfo(to: submenu, title: reason)
        }
        submenu.addItem(.separator())
        addSelfTestItems(to: submenu, status: status, state: state, target: target)

        item.submenu = submenu
        return item
    }

    private static func addSelfTestItems(
        to menu: NSMenu,
        status: DriveStatus,
        state: AppState,
        target: StatusItemController
    ) {
        guard state.effectiveSmartctlPath != nil else {
            addInfo(to: menu, title: "SMART-Kurztest: smartctl nicht gefunden")
            return
        }
        guard status.isConnected else {
            addInfo(to: menu, title: "SMART-Kurztest: Laufwerk nicht verbunden")
            return
        }

        if let test = state.selfTests.state(forKey: status.id) {
            if test.running {
                var title = "Selbsttest läuft …"
                if let remaining = test.percentRemaining {
                    title = "Selbsttest läuft … noch \(Format.number(remaining)) %"
                } else if !test.message.isEmpty {
                    title = "Selbsttest läuft: \(test.message)"
                }
                addInfo(to: menu, title: title)
                return
            }
            if test.requiresAdmin {
                addInfo(to: menu, title: test.message)
                let item = actionItem(
                    "Mit Administratorrechten starten …",
                    action: #selector(StatusItemController.startSelfTestWithAdministrator),
                    target: target
                )
                item.representedObject = status
                menu.addItem(item)
                return
            }
            if !test.message.isEmpty {
                addInfo(to: menu, title: "Letzter Selbsttest: \(test.message)")
            }
        }

        let item = actionItem(
            "SMART-Kurztest starten",
            action: #selector(StatusItemController.startSelfTest),
            target: target
        )
        item.representedObject = status
        menu.addItem(item)
    }

    // MARK: RAID

    private static func raidItem(status: RaidStatus) -> NSMenuItem {
        let item = NSMenuItem(title: "\(status.raid.displayName) – \(status.shortStatusText)", action: nil, keyEquivalent: "")
        item.image = MenuIcons.dot(status.health)

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        addInfo(to: submenu, title: "Name: \(status.raid.displayName)")
        addInfo(to: submenu, title: "Level: \(status.raid.levelText)")
        addInfo(to: submenu, title: "Status: \(status.raid.status)")
        addInfo(to: submenu, title: "Größe: \(status.raid.sizeText)")
        if let usage = status.usage {
            addInfo(to: submenu, title: usage.summaryText)
        }
        addInfo(to: submenu, title: "Gerät: \(status.isConnected ? "/dev/\(status.raid.bsdName)" : "nicht verfügbar")")
        if let progress = status.raid.rebuildProgress {
            addInfo(to: submenu, title: "Rebuild: \(Format.number(progress)) %")
        }
        if !status.raid.members.isEmpty {
            submenu.addItem(.separator())
            addSectionTitle(to: submenu, title: "Mitglieder")
            for member in status.raid.members {
                let level: HealthLevel
                let lower = member.status.lowercased()
                if lower.contains("online") {
                    level = .ok
                } else if lower.contains("rebuild") || lower.contains("resync") {
                    level = .warning
                } else {
                    level = .problem
                }
                let memberItem = NSMenuItem(title: "\(member.bsdName) – \(member.status)", action: nil, keyEquivalent: "")
                memberItem.image = MenuIcons.dot(level)
                memberItem.isEnabled = false
                submenu.addItem(memberItem)
            }
        }
        submenu.addItem(.separator())
        for reason in status.reasons {
            addInfo(to: submenu, title: reason)
        }

        item.submenu = submenu
        return item
    }

    // MARK: Helpers

    private static func smartStatusText(_ smart: SmartHealth) -> String {
        switch smart.passed {
        case .some(true): return "OK"
        case .some(false): return "Fehler"
        case .none: return "Unbekannt"
        }
    }

    private static func addInfo(to menu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private static func addSectionTitle(to menu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        menu.addItem(item)
    }

    private static func actionItem(
        _ title: String,
        action: Selector,
        target: AnyObject,
        key: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        if !key.isEmpty {
            item.keyEquivalentModifierMask = [.command]
        }
        return item
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

import AppKit
import DriveCheckMenuCore

if CommandLine.arguments.contains("--dump") {
    dumpStatus()
    exit(0)
}

if CommandLine.arguments.contains("--smoke") {
    runSmokeTest()
    exit(0)
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}

// MARK: - Diagnostics

func dumpStatus() {
    var settings = SettingsStore.shared.load()
    let simulation = SimulationMode(arguments: ProcessInfo.processInfo.arguments)
    var snapshot = StatusCollector.collect(settings: settings)

    if !settings.defaultSelectionApplied {
        settings.selectedDrives = snapshot.drives.filter(\.isConnected).map { StoredDrive(drive: $0.drive) }
        settings.selectedRaids = snapshot.raids.filter(\.isConnected).map { StoredRaid(raid: $0.raid) }
    }
    snapshot.applySelection(from: settings)
    if let simulation {
        snapshot = StatusCollector.apply(simulation: simulation, to: snapshot)
    }
    snapshot.recalculateOverall()

    print("DriveCheckMenu Statusausgabe")
    print("Datum: \(snapshot.date)")
    print("Gesamt: \(snapshot.overall.rawValue) – \(snapshot.overallSummary)")
    print("smartctl: \(snapshot.smartctlPath ?? "nicht gefunden") (Version \(snapshot.smartctlVersion ?? "?"))")
    if let simulation {
        print("Simulation: \(simulation.rawValue)")
    }
    print("")

    for status in snapshot.drives {
        let mark = status.isMonitored ? "[x]" : "[ ]"
        print("\(mark) \(status.drive.displayName) (/dev/\(status.drive.bsdName)) – \(status.health.label)")
        print("    \(status.drive.sizeText) · \(status.drive.protocolName) · \(status.drive.locationText) · \(status.drive.kindText) · \(status.drive.id)")
        if let usage = status.usage {
            print("    \(usage.summaryText)")
        }
        if let smart = status.smart {
            var parts = ["Quelle: \(smart.source.label)"]
            if let temperature = smart.temperatureCelsius { parts.append("Temp: \(Format.number(temperature)) °C") }
            if let used = smart.percentageUsed { parts.append("Verschleiß: \(Format.number(used)) %") }
            if let spare = smart.availableSpare { parts.append("Reserve: \(Format.number(spare)) %") }
            if let mediaErrors = smart.mediaErrors { parts.append("Medienfehler: \(mediaErrors)") }
            if let hours = smart.powerOnHours { parts.append("Stunden: \(Format.number(hours))") }
            print("    " + parts.joined(separator: " · "))
        } else {
            print("    Keine SMART-Daten")
        }
        for reason in status.reasons {
            print("    – \(reason)")
        }
    }

    for status in snapshot.raids {
        let mark = status.isMonitored ? "[x]" : "[ ]"
        print("\(mark) RAID \(status.raid.displayName) (/dev/\(status.raid.bsdName)) – \(status.health.label)")
        print("    \(status.raid.levelText) · \(status.raid.sizeText) · Status: \(status.raid.status) · Mitglieder: \(status.raid.members.map { "\($0.bsdName)=\($0.status)" }.joined(separator: ", "))")
        if let usage = status.usage {
            print("    \(usage.summaryText)")
        }
        for reason in status.reasons {
            print("    – \(reason)")
        }
    }
}

// MARK: - UI smoke test

func runSmokeTest() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    MainActor.assumeIsolated {
        let state = AppState()
        let controller = StatusItemController(state: state)
        controller.install()
        controller.showSettings()
        state.start()

        let deadline = Date().addingTimeInterval(25)
        while state.snapshot == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }

        print("SMOKE \(controller.diagnostics)")
        if let snapshot = state.snapshot {
            print("SMOKE overall=\(snapshot.overall.rawValue) drives=\(snapshot.drives.count) raids=\(snapshot.raids.count) monitored=\(snapshot.monitoredDriveCount)/\(snapshot.monitoredRaidCount)")
        } else {
            print("SMOKE snapshot=nil")
        }
        print("SMOKE loginItem=\(state.loginItemStatusText)")
    }
}

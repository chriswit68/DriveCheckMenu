import Foundation

public enum SimulationMode: String, Sendable {
    case failing
    case degraded
    case missing

    public init?(arguments: [String]) {
        for argument in arguments {
            let lower = argument.lowercased()
            if lower.hasPrefix("--simulate=") {
                self.init(rawValue: String(lower.dropFirst("--simulate=".count)))
                return
            }
            if lower.hasPrefix("--simulate") {
                continue
            }
        }
        if let value = ProcessInfo.processInfo.environment["DCM_SIMULATE"]?.lowercased() {
            self.init(rawValue: value)
            return
        }
        return nil
    }
}

public enum StatusCollector {
    public static func collect(settings: AppSettings) -> MonitorSnapshot {
        let smartctlPath = settings.useSmartctl
            ? SmartctlLocator.locate(override: settings.smartctlPathOverride)
            : nil
        let smartctlVersion = smartctlPath.flatMap { SmartctlLocator.version(at: $0) }

        let inventory = DiskInventory.inventory()
        var drives = inventory.drives
        var smartByBSD: [String: SmartHealth] = [:]

        for index in drives.indices {
            var drive = drives[index]
            var smart: SmartHealth?

            if let smartctlPath {
                let probed = SmartctlProbe.probe(bsdName: drive.bsdName, smartctlPath: smartctlPath)
                smart = probed
                if let serial = probed.serialNumber, !serial.isEmpty {
                    drive.serial = serial
                }
                if let model = probed.modelName, !model.isEmpty {
                    drive.model = model
                }
                if let capacity = probed.capacityBytes, capacity > 0 {
                    drive.sizeBytes = capacity
                }
                if let rotationRate = probed.rotationRate {
                    // USB bridges often report solid state incorrectly; smartctl knows better.
                    drive.isSolidState = rotationRate == 0
                }
                if probed.hasUsableData {
                    drive.id = StableID.key(
                        serial: drive.serial,
                        model: drive.model,
                        size: drive.sizeBytes
                    )
                }
            }

            if smart == nil || smart!.hasUsableData == false {
                if let fallback = diskutilFallback(status: drive.smartStatusRaw, smartctl: smart) {
                    smart = fallback
                }
            }

            var key = StableID.key(serial: drive.serial, model: drive.model, size: drive.sizeBytes)
            let usedKeys = Set(drives[0..<index].map(\.id))
            if usedKeys.contains(key) {
                key = "\(key)|\(drive.bsdName)"
            }
            drive.id = key

            drives[index] = drive
            if let smart { smartByBSD[drive.bsdName] = smart }
        }

        let matchedDriveIDs = SelectionMatcher.matchedDriveIDs(settings.selectedDrives, available: drives)

        var driveStatuses: [DriveStatus] = drives.map { drive in
            let smart = smartByBSD[drive.bsdName]
            let evaluation = HealthEvaluator.evaluate(
                smart: smart,
                diskutilStatus: drive.smartStatusRaw,
                thresholds: settings.thresholds
            )
            return DriveStatus(
                drive: drive,
                smart: smart,
                usage: inventory.usageByDisk[drive.bsdName]?.rebased(toTotal: drive.sizeBytes),
                health: evaluation.level,
                reasons: evaluation.reasons,
                isMonitored: matchedDriveIDs.contains(drive.id),
                isConnected: true
            )
        }

        // Add placeholders for selected drives that are currently not connected.
        for stored in settings.selectedDrives {
            let isPresent = drives.contains { drive in
                if drive.id == stored.id { return true }
                if let serial = stored.serial, !serial.isEmpty, drive.serial == serial { return true }
                return false
            }
            guard !isPresent else { continue }
            let placeholder = DriveInfo(
                id: stored.id,
                bsdName: "–",
                model: stored.name.isEmpty ? stored.model : stored.name,
                serial: stored.serial,
                sizeBytes: stored.sizeBytes,
                isInternal: false,
                isSolidState: false,
                protocolName: "–",
                isEjectable: true
            )
            driveStatuses.append(
                DriveStatus(
                    drive: placeholder,
                    smart: nil,
                    health: .warning,
                    reasons: ["Nicht verbunden"],
                    isMonitored: true,
                    isConnected: false
                )
            )
        }

        let raidSets = RaidProbe.sets()
        var raidStatuses: [RaidStatus] = raidSets.map { raid in
            let evaluation = HealthEvaluator.evaluate(raid: raid)
            return RaidStatus(
                raid: raid,
                usage: inventory.usageByDisk[raid.bsdName]?.rebased(toTotal: raid.sizeBytes),
                health: evaluation.level,
                reasons: evaluation.reasons,
                isMonitored: settings.selectedRaidKeys.contains(raid.id),
                isConnected: true
            )
        }

        for stored in settings.selectedRaids where !raidSets.contains(where: { $0.id == stored.id }) {
            let placeholder = RaidSetInfo(
                id: stored.id,
                name: stored.name,
                level: stored.level,
                status: "Nicht verfügbar",
                bsdName: "–",
                sizeBytes: stored.sizeBytes,
                members: []
            )
            raidStatuses.append(
                RaidStatus(
                    raid: placeholder,
                    health: .warning,
                    reasons: ["RAID-Set nicht verfügbar"],
                    isMonitored: true,
                    isConnected: false
                )
            )
        }

        driveStatuses.sort {
            if $0.isConnected != $1.isConnected { return $0.isConnected }
            if $0.drive.isInternal != $1.drive.isInternal { return !$0.drive.isInternal }
            return $0.drive.displayName.localizedStandardCompare($1.drive.displayName) == .orderedAscending
        }
        raidStatuses.sort {
            $0.raid.displayName.localizedStandardCompare($1.raid.displayName) == .orderedAscending
        }

        var snapshot = MonitorSnapshot(
            date: Date(),
            drives: driveStatuses,
            raids: raidStatuses,
            smartctlPath: smartctlPath,
            smartctlVersion: smartctlVersion
        )
        snapshot.recalculateOverall()
        return snapshot
    }

    private static func diskutilFallback(status: String?, smartctl: SmartHealth?) -> SmartHealth? {
        guard let status, !status.isEmpty else { return nil }
        let lower = status.lowercased()

        var health = SmartHealth(source: .diskutil)
        if lower.contains("verified") {
            health.passed = true
        } else if lower.contains("failing") {
            health.passed = false
        } else {
            health.passed = nil
            health.unavailableReason = "SMART-Status: \(status)"
        }

        // Keep the smartctl diagnosis for the detail view, but use the basic diskutil result.
        if let smartctl, let reason = smartctl.unavailableReason, !reason.isEmpty {
            health.messages = [reason]
        }
        health.modelName = smartctl?.modelName
        health.serialNumber = smartctl?.serialNumber
        return health
    }

    public static func apply(simulation: SimulationMode, to snapshot: MonitorSnapshot) -> MonitorSnapshot {
        var snapshot = snapshot
        switch simulation {
        case .failing:
            if let index = snapshot.drives.firstIndex(where: { $0.isMonitored && $0.isConnected })
                ?? snapshot.drives.firstIndex(where: \.isConnected) {
                snapshot.drives[index].isMonitored = true
                snapshot.drives[index].health = .problem
                snapshot.drives[index].reasons = ["Simulation: SMART-Fehler"]
            } else {
                snapshot.drives.append(
                    DriveStatus(
                        drive: DriveInfo(
                            id: "simulation:failing",
                            bsdName: "disk99",
                            model: "Simuliertes Laufwerk (Fehler)",
                            sizeBytes: 1_000_000_000_000,
                            isInternal: false,
                            isSolidState: true,
                            protocolName: "PCI-Express",
                            isEjectable: true
                        ),
                        health: .problem,
                        reasons: ["Simulation: SMART-Fehler"],
                        isMonitored: true
                    )
                )
            }
        case .degraded:
            if let index = snapshot.raids.firstIndex(where: { $0.isMonitored && $0.isConnected })
                ?? snapshot.raids.firstIndex(where: \.isConnected) {
                snapshot.raids[index].isMonitored = true
                snapshot.raids[index].raid.status = "Degraded"
                snapshot.raids[index].health = .problem
                snapshot.raids[index].reasons = ["Simulation: RAID degradiert"]
            } else {
                snapshot.raids.append(
                    RaidStatus(
                        raid: RaidSetInfo(
                            id: "simulation:degraded",
                            name: "Simulierter RAID-Verbund",
                            level: "Mirror",
                            status: "Degraded",
                            bsdName: "disk99",
                            sizeBytes: 2_000_000_000_000,
                            members: [
                                RaidMember(id: "sim:1", bsdName: "disk98s2", status: "Online"),
                                RaidMember(id: "sim:2", bsdName: "disk97s2", status: "Offline")
                            ]
                        ),
                        health: .problem,
                        reasons: ["Simulation: RAID degradiert"],
                        isMonitored: true
                    )
                )
            }
        case .missing:
            if let index = snapshot.drives.firstIndex(where: { $0.isMonitored && $0.isConnected })
                ?? snapshot.drives.firstIndex(where: \.isConnected) {
                snapshot.drives[index].isMonitored = true
                snapshot.drives[index].health = .warning
                snapshot.drives[index].isConnected = false
                snapshot.drives[index].reasons = ["Simulation: Nicht verbunden"]
            }
        }
        snapshot.recalculateOverall()
        return snapshot
    }
}

extension MonitorSnapshot {
    public mutating func recalculateOverall() {
        let monitored = drives.filter(\.isMonitored).map(\.health) + raids.filter(\.isMonitored).map(\.health)
        overall = HealthLevel.worst(monitored)
        problemCount = monitored.filter { $0 == .problem }.count
        warningCount = monitored.filter { $0 == .warning }.count
        monitoredDriveCount = drives.filter(\.isMonitored).count
        monitoredRaidCount = raids.filter(\.isMonitored).count
        if monitoredDriveCount == 0 && monitoredRaidCount == 0 {
            overall = .ok
        }
    }
}

extension SmartHealth {
    /// True when smartctl delivered actual health information (not just an error).
    public var hasUsableData: Bool {
        passed != nil || temperatureCelsius != nil || percentageUsed != nil
            || criticalWarning != nil || !ataAttributes.isEmpty
    }
}

import Foundation

// MARK: - Health

/// Severity of a single monitored item, ordered from best to worst.
public enum HealthLevel: String, Codable, CaseIterable, Sendable {
    case ok
    case unknown
    case warning
    case problem

    public var rank: Int {
        switch self {
        case .ok: return 0
        case .unknown: return 1
        case .warning: return 2
        case .problem: return 3
        }
    }

    public var label: String {
        switch self {
        case .ok: return "OK"
        case .unknown: return "Unbekannt"
        case .warning: return "Warnung"
        case .problem: return "Problem"
        }
    }

    public static func worst(_ levels: [HealthLevel]) -> HealthLevel {
        levels.max(by: { $0.rank < $1.rank }) ?? .ok
    }
}

extension HealthLevel: Comparable {
    public static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

// MARK: - SMART

public struct AtaAttribute: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var value: Int
    public var worst: Int?
    public var threshold: Int?
    public var rawValue: Double?
    public var rawString: String?
    public var prefailure: Bool

    public init(
        id: Int,
        name: String,
        value: Int,
        worst: Int? = nil,
        threshold: Int? = nil,
        rawValue: Double? = nil,
        rawString: String? = nil,
        prefailure: Bool = false
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.worst = worst
        self.threshold = threshold
        self.rawValue = rawValue
        self.rawString = rawString
        self.prefailure = prefailure
    }

    /// A prefailure attribute that already reached or fell below its manufacturer limit.
    public var isFailingNow: Bool {
        guard prefailure, let threshold, threshold > 0 else { return false }
        return value <= threshold
    }

    public var displayName: String {
        name.replacingOccurrences(of: "_", with: " ")
    }
}

public struct SmartHealth: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        case smartctl
        case diskutil

        public var label: String {
            switch self {
            case .smartctl: return "smartctl"
            case .diskutil: return "diskutil (Basisstatus)"
            }
        }
    }

    public var source: Source
    public var passed: Bool?
    public var modelName: String?
    public var serialNumber: String?
    public var capacityBytes: Int64?
    public var temperatureCelsius: Double?
    public var temperatureSensors: [Double] = []
    public var deviceOperatingLimit: Double?
    public var deviceCriticalLimit: Double?
    public var percentageUsed: Double?
    public var availableSpare: Double?
    public var availableSpareThreshold: Double?
    public var mediaErrors: Int?
    public var errorLogEntries: Int?
    public var criticalWarning: Int?
    public var rotationRate: Int?
    public var powerOnHours: Double?
    public var powerCycles: Int?
    public var unsafeShutdowns: Int?
    public var reallocatedSectors: Int?
    public var pendingSectors: Int?
    public var uncorrectableSectors: Int?
    public var wearLevelingPercent: Double?
    public var ataAttributes: [AtaAttribute] = []
    public var deviceType: String?
    public var powerMode: String?
    public var isStandby: Bool = false
    public var messages: [String] = []
    public var unavailableReason: String?
    public var lastSelfTest: String?

    public init(source: Source) {
        self.source = source
    }

    public var isPassed: Bool? { passed }

    public var temperatureText: String? {
        guard let temperatureCelsius else { return nil }
        return String(format: "%.0f °C", temperatureCelsius)
    }

    public var percentageUsedText: String? {
        guard let percentageUsed else { return nil }
        return String(format: "%.0f %%", percentageUsed)
    }
}

// MARK: - Storage usage

/// Currently used capacity of a mass storage device or volume group.
///
/// The values are read from the mounted file systems (one `getfsstat` call), so they
/// describe the space actually occupied by user data, not the raw device wear level.
public struct StorageUsage: Codable, Hashable, Sendable {
    public var totalBytes: Int64
    public var usedBytes: Int64

    public init(totalBytes: Int64, usedBytes: Int64) {
        self.totalBytes = max(0, totalBytes)
        self.usedBytes = min(max(0, usedBytes), max(0, totalBytes))
    }

    public var percentUsed: Double? {
        guard totalBytes > 0 else { return nil }
        return Double(usedBytes) / Double(totalBytes) * 100
    }

    public var usedText: String { Format.bytes(usedBytes) }
    public var totalText: String { Format.bytes(totalBytes) }

    public var percentText: String? {
        percentUsed.map { String(format: "%.0f %%", $0) }
    }

    /// Re-bases the usage on the device capacity so the percentage matches the displayed size.
    public func rebased(toTotal totalBytes: Int64) -> StorageUsage {
        guard totalBytes > 0 else { return self }
        return StorageUsage(totalBytes: totalBytes, usedBytes: usedBytes)
    }

    /// "Belegt: 265,01 GB von 999,86 GB (27 %)"
    public var summaryText: String {
        if let percentText {
            return "Belegt: \(usedText) von \(totalText) (\(percentText))"
        }
        return "Belegt: \(usedText) von \(totalText)"
    }

    /// "265,01 GB belegt (27 %)"
    public var shortText: String {
        if let percentText {
            return "\(usedText) belegt (\(percentText))"
        }
        return "\(usedText) belegt"
    }

    /// Adds up the usage of several file systems (e.g. multiple APFS containers on one disk).
    public static func combined(_ usages: [StorageUsage]) -> StorageUsage? {
        let valid = usages.filter { $0.totalBytes > 0 }
        guard !valid.isEmpty else { return nil }
        return StorageUsage(
            totalBytes: valid.reduce(0) { $0 + $1.totalBytes },
            usedBytes: valid.reduce(0) { $0 + $1.usedBytes }
        )
    }
}

// MARK: - Drives

public struct DriveInfo: Codable, Hashable, Identifiable, Sendable {
    /// Stable identity across reboots and re-plugs. Serial based when available.
    public var id: String
    public var bsdName: String
    public var model: String
    public var serial: String?
    public var sizeBytes: Int64
    public var isInternal: Bool
    public var isSolidState: Bool
    public var protocolName: String
    public var isEjectable: Bool
    public var smartStatusRaw: String?
    public var mediaName: String

    public init(
        id: String,
        bsdName: String,
        model: String,
        serial: String? = nil,
        sizeBytes: Int64,
        isInternal: Bool,
        isSolidState: Bool,
        protocolName: String,
        isEjectable: Bool,
        smartStatusRaw: String? = nil,
        mediaName: String = ""
    ) {
        self.id = id
        self.bsdName = bsdName
        self.model = model
        self.serial = serial
        self.sizeBytes = sizeBytes
        self.isInternal = isInternal
        self.isSolidState = isSolidState
        self.protocolName = protocolName
        self.isEjectable = isEjectable
        self.smartStatusRaw = smartStatusRaw
        self.mediaName = mediaName
    }

    public var displayName: String {
        model.isEmpty ? bsdName : model
    }

    public var locationText: String {
        isInternal ? "Intern" : "Extern"
    }

    public var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    public var kindText: String {
        isSolidState ? "SSD" : "HDD"
    }
}

public struct StoredDrive: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var model: String
    public var sizeBytes: Int64
    public var serial: String?

    public init(id: String, name: String, model: String, sizeBytes: Int64, serial: String? = nil) {
        self.id = id
        self.name = name
        self.model = model
        self.sizeBytes = sizeBytes
        self.serial = serial
    }

    public init(drive: DriveInfo) {
        self.init(
            id: drive.id,
            name: drive.displayName,
            model: drive.model,
            sizeBytes: drive.sizeBytes,
            serial: drive.serial
        )
    }
}

public struct DriveStatus: Identifiable, Sendable {
    public var drive: DriveInfo
    public var smart: SmartHealth?
    /// Used capacity of the mounted file systems on this disk. nil when unavailable.
    public var usage: StorageUsage?
    public var health: HealthLevel
    public var reasons: [String]
    public var isMonitored: Bool
    public var isConnected: Bool

    public var id: String { drive.id }

    public init(
        drive: DriveInfo,
        smart: SmartHealth? = nil,
        usage: StorageUsage? = nil,
        health: HealthLevel = .unknown,
        reasons: [String] = [],
        isMonitored: Bool = false,
        isConnected: Bool = true
    ) {
        self.drive = drive
        self.smart = smart
        self.usage = usage
        self.health = health
        self.reasons = reasons
        self.isMonitored = isMonitored
        self.isConnected = isConnected
    }

    public var shortStatusText: String {
        var parts: [String] = [health.label]
        if let temperature = smart?.temperatureText {
            parts.append(temperature)
        }
        if let used = smart?.percentageUsedText {
            parts.append("Verschleiß \(used)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - RAID

public struct RaidMember: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var bsdName: String
    public var status: String

    public init(id: String, bsdName: String, status: String) {
        self.id = id
        self.bsdName = bsdName
        self.status = status
    }
}

public struct RaidSetInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var level: String
    public var status: String
    public var bsdName: String
    public var sizeBytes: Int64
    public var members: [RaidMember]
    public var rebuildProgress: Double?

    public init(
        id: String,
        name: String,
        level: String,
        status: String,
        bsdName: String,
        sizeBytes: Int64,
        members: [RaidMember],
        rebuildProgress: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.level = level
        self.status = status
        self.bsdName = bsdName
        self.sizeBytes = sizeBytes
        self.members = members
        self.rebuildProgress = rebuildProgress
    }

    public var displayName: String {
        name.isEmpty ? bsdName : name
    }

    public var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    public var levelText: String {
        switch level.lowercased() {
        case "mirror": return "Mirror (RAID 1)"
        case "stripe": return "Stripe (RAID 0)"
        case "conatenated", "concatenated": return "JBOD"
        default: return level
        }
    }
}

public struct StoredRaid: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var level: String
    public var sizeBytes: Int64

    public init(id: String, name: String, level: String, sizeBytes: Int64) {
        self.id = id
        self.name = name
        self.level = level
        self.sizeBytes = sizeBytes
    }

    public init(raid: RaidSetInfo) {
        self.init(id: raid.id, name: raid.displayName, level: raid.level, sizeBytes: raid.sizeBytes)
    }
}

public struct RaidStatus: Identifiable, Sendable {
    public var raid: RaidSetInfo
    /// Used capacity of the file systems on the RAID volume. nil when unavailable.
    public var usage: StorageUsage?
    public var health: HealthLevel
    public var reasons: [String]
    public var isMonitored: Bool
    public var isConnected: Bool

    public var id: String { raid.id }

    public init(
        raid: RaidSetInfo,
        usage: StorageUsage? = nil,
        health: HealthLevel = .unknown,
        reasons: [String] = [],
        isMonitored: Bool = false,
        isConnected: Bool = true
    ) {
        self.raid = raid
        self.usage = usage
        self.health = health
        self.reasons = reasons
        self.isMonitored = isMonitored
        self.isConnected = isConnected
    }

    public var shortStatusText: String {
        if let progress = raid.rebuildProgress {
            return "Rebuild \(String(format: "%.0f %%", progress))"
        }
        return health.label
    }
}

// MARK: - Snapshot

public struct MonitorSnapshot: Sendable {
    public var date: Date
    public var drives: [DriveStatus]
    public var raids: [RaidStatus]
    public var smartctlPath: String?
    public var smartctlVersion: String?
    public var overall: HealthLevel
    public var problemCount: Int
    public var warningCount: Int
    public var monitoredDriveCount: Int
    public var monitoredRaidCount: Int

    public init(
        date: Date = Date(),
        drives: [DriveStatus] = [],
        raids: [RaidStatus] = [],
        smartctlPath: String? = nil,
        smartctlVersion: String? = nil,
        overall: HealthLevel = .ok,
        problemCount: Int = 0,
        warningCount: Int = 0,
        monitoredDriveCount: Int = 0,
        monitoredRaidCount: Int = 0
    ) {
        self.date = date
        self.drives = drives
        self.raids = raids
        self.smartctlPath = smartctlPath
        self.smartctlVersion = smartctlVersion
        self.overall = overall
        self.problemCount = problemCount
        self.warningCount = warningCount
        self.monitoredDriveCount = monitoredDriveCount
        self.monitoredRaidCount = monitoredRaidCount
    }

    public var monitoredDrives: [DriveStatus] { drives.filter(\.isMonitored) }
    public var monitoredRaids: [RaidStatus] { raids.filter(\.isMonitored) }

    public var overallSummary: String {
        switch overall {
        case .ok:
            if monitoredDriveCount == 0 && monitoredRaidCount == 0 {
                return "Keine Laufwerke ausgewählt"
            }
            return "Alles in Ordnung"
        case .unknown:
            return "Status unbekannt"
        case .warning:
            return warningCount == 1 ? "1 Warnung" : "\(warningCount) Warnungen"
        case .problem:
            return problemCount == 1 ? "1 Problem" : "\(problemCount) Probleme"
        }
    }
}

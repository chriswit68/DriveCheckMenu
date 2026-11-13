import Foundation

// MARK: - Thresholds

public struct HealthThresholds: Codable, Equatable, Sendable {
    public var temperatureWarning: Double
    public var temperatureCritical: Double
    public var wearWarning: Double
    public var wearCritical: Double

    public init(
        temperatureWarning: Double = 60,
        temperatureCritical: Double = 75,
        wearWarning: Double = 90,
        wearCritical: Double = 100
    ) {
        self.temperatureWarning = temperatureWarning
        self.temperatureCritical = temperatureCritical
        self.wearWarning = wearWarning
        self.wearCritical = wearCritical
    }

    public static let `default` = HealthThresholds()

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = HealthThresholds()
        temperatureWarning = try container.decodeIfPresent(Double.self, forKey: .temperatureWarning) ?? fallback.temperatureWarning
        temperatureCritical = try container.decodeIfPresent(Double.self, forKey: .temperatureCritical) ?? fallback.temperatureCritical
        wearWarning = try container.decodeIfPresent(Double.self, forKey: .wearWarning) ?? fallback.wearWarning
        wearCritical = try container.decodeIfPresent(Double.self, forKey: .wearCritical) ?? fallback.wearCritical
    }
}

// MARK: - Check interval

public enum CheckInterval: Double, CaseIterable, Identifiable, Sendable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600
    case sixHours = 21600
    case twelveHours = 43200
    case daily = 86400

    public var id: Double { rawValue }

    public var label: String {
        switch self {
        case .oneMinute: return "Jede Minute"
        case .fiveMinutes: return "Alle 5 Minuten"
        case .fifteenMinutes: return "Alle 15 Minuten"
        case .thirtyMinutes: return "Alle 30 Minuten"
        case .oneHour: return "Jede Stunde"
        case .sixHours: return "Alle 6 Stunden"
        case .twelveHours: return "Alle 12 Stunden"
        case .daily: return "Täglich"
        }
    }

    public static func label(for seconds: Double) -> String {
        CheckInterval(rawValue: seconds)?.label ?? "Alle \(Int(seconds / 60)) Minuten"
    }
}

// MARK: - Settings

public struct AppSettings: Codable, Equatable, Sendable {
    public var intervalSeconds: Double
    public var notifyOnChange: Bool
    public var defaultSelectionApplied: Bool
    public var selectedDrives: [StoredDrive]
    public var selectedRaids: [StoredRaid]
    public var thresholds: HealthThresholds
    public var useSmartctl: Bool
    public var smartctlPathOverride: String?

    public init(
        intervalSeconds: Double = CheckInterval.fiveMinutes.rawValue,
        notifyOnChange: Bool = true,
        defaultSelectionApplied: Bool = false,
        selectedDrives: [StoredDrive] = [],
        selectedRaids: [StoredRaid] = [],
        thresholds: HealthThresholds = .default,
        useSmartctl: Bool = true,
        smartctlPathOverride: String? = nil
    ) {
        self.intervalSeconds = intervalSeconds
        self.notifyOnChange = notifyOnChange
        self.defaultSelectionApplied = defaultSelectionApplied
        self.selectedDrives = selectedDrives
        self.selectedRaids = selectedRaids
        self.thresholds = thresholds
        self.useSmartctl = useSmartctl
        self.smartctlPathOverride = smartctlPathOverride
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings()
        intervalSeconds = try container.decodeIfPresent(Double.self, forKey: .intervalSeconds) ?? fallback.intervalSeconds
        notifyOnChange = try container.decodeIfPresent(Bool.self, forKey: .notifyOnChange) ?? fallback.notifyOnChange
        defaultSelectionApplied = try container.decodeIfPresent(Bool.self, forKey: .defaultSelectionApplied) ?? fallback.defaultSelectionApplied
        selectedDrives = try container.decodeIfPresent([StoredDrive].self, forKey: .selectedDrives) ?? []
        selectedRaids = try container.decodeIfPresent([StoredRaid].self, forKey: .selectedRaids) ?? []
        thresholds = try container.decodeIfPresent(HealthThresholds.self, forKey: .thresholds) ?? .default
        useSmartctl = try container.decodeIfPresent(Bool.self, forKey: .useSmartctl) ?? fallback.useSmartctl
        smartctlPathOverride = try container.decodeIfPresent(String.self, forKey: .smartctlPathOverride)
    }

    public var selectedDriveKeys: Set<String> { Set(selectedDrives.map(\.id)) }
    public var selectedRaidKeys: Set<String> { Set(selectedRaids.map(\.id)) }

    public func isDriveMonitored(_ drive: DriveInfo, available: [DriveInfo]) -> Bool {
        let matched = SelectionMatcher.matchedDriveIDs(selectedDrives, available: available)
        return matched.contains(drive.id)
    }

    public func isRaidMonitored(_ raid: RaidSetInfo) -> Bool {
        selectedRaids.contains { $0.id == raid.id }
    }
}

// MARK: - Selection matching

public enum SelectionMatcher {
    /// Matches stored drive selections against the currently connected drives.
    /// Exact id (serial) wins, then serial, then a unique model+size pair.
    public static func matchedDriveIDs(_ stored: [StoredDrive], available: [DriveInfo]) -> Set<String> {
        var matched = Set<String>()
        var matchedStored = Set<String>()
        var remaining = available

        // 1. Exact id match.
        for entry in stored {
            if let drive = remaining.first(where: { $0.id == entry.id }) {
                matched.insert(drive.id)
                matchedStored.insert(entry.id)
                remaining.removeAll { $0.id == drive.id }
            }
        }

        // 2. Serial match (key format may have changed).
        for entry in stored where !matchedStored.contains(entry.id) {
            guard let serial = entry.serial, !serial.isEmpty else { continue }
            if let drive = remaining.first(where: { $0.serial == serial }) {
                matched.insert(drive.id)
                matchedStored.insert(entry.id)
                remaining.removeAll { $0.id == drive.id }
            }
        }

        // 3. Unique model + size match.
        for entry in stored where !matchedStored.contains(entry.id) {
            let candidates = remaining.filter {
                $0.model == entry.model && $0.sizeBytes == entry.sizeBytes
            }
            if candidates.count == 1, let drive = candidates.first {
                matched.insert(drive.id)
                matchedStored.insert(entry.id)
                remaining.removeAll { $0.id == drive.id }
            }
        }

        return matched
    }
}

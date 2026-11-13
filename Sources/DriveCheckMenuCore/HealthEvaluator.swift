import Foundation

public enum HealthEvaluator {
    public struct Evaluation: Sendable {
        public var level: HealthLevel
        public var reasons: [String]
    }

    // MARK: Drive

    public static func evaluate(
        smart: SmartHealth?,
        diskutilStatus: String?,
        thresholds: HealthThresholds
    ) -> Evaluation {
        var level: HealthLevel = .ok
        var reasons: [String] = []

        func raise(_ newLevel: HealthLevel, _ reason: String) {
            if newLevel > level { level = newLevel }
            reasons.append(reason)
        }

        guard let smart else {
            if let diskutilStatus, !diskutilStatus.isEmpty {
                return evaluateDiskutilFallback(status: diskutilStatus, thresholds: thresholds)
            }
            return Evaluation(level: .warning, reasons: ["Keine SMART-Daten verfügbar"])
        }

        if smart.isStandby {
            raise(.warning, "Laufwerk im Standby – SMART nicht geprüft")
        }

        if let unavailableReason = smart.unavailableReason, !smart.isStandby, smart.source == .smartctl {
            raise(.warning, unavailableReason)
        }

        switch smart.passed {
        case .some(false):
            raise(.problem, "SMART-Gesamtstatus: Fehler")
        case .some(true):
            break
        case .none:
            if smart.source == .smartctl, smart.unavailableReason == nil, !smart.isStandby {
                raise(.warning, "SMART-Gesamtstatus unbekannt")
            }
        }

        if let criticalWarning = smart.criticalWarning, criticalWarning != 0 {
            raise(.problem, "Kritische SMART-Warnung (Code \(criticalWarning))")
        }

        if let spare = smart.availableSpare, let threshold = smart.availableSpareThreshold, spare <= threshold {
            raise(.problem, "Reserveblöcke erschöpft (\(Format.number(spare)) %, Schwelle \(Format.number(threshold)) %)")
        }

        if let percentageUsed = smart.percentageUsed {
            if percentageUsed >= thresholds.wearCritical {
                raise(.problem, "Verschleiß kritisch (\(Format.number(percentageUsed)) %)")
            } else if percentageUsed >= thresholds.wearWarning {
                raise(.warning, "Verschleiß hoch (\(Format.number(percentageUsed)) %)")
            }
        } else if let wear = smart.wearLevelingPercent {
            if wear >= thresholds.wearCritical {
                raise(.problem, "Verschleiß kritisch (\(Format.number(wear)) %)")
            } else if wear >= thresholds.wearWarning {
                raise(.warning, "Verschleiß hoch (\(Format.number(wear)) %)")
            }
        }

        if let pending = smart.pendingSectors, pending > 0 {
            raise(.problem, "\(pending) schwebende Sektoren")
        }
        if let uncorrectable = smart.uncorrectableSectors, uncorrectable > 0 {
            raise(.problem, "\(uncorrectable) nicht korrigierbare Sektoren")
        }
        if let reallocated = smart.reallocatedSectors, reallocated > 0 {
            raise(.warning, "\(reallocated) wiederzugewiesene Sektoren")
        }
        if let mediaErrors = smart.mediaErrors, mediaErrors > 0 {
            raise(.warning, "\(mediaErrors) Medienfehler")
        }
        if let errorLogEntries = smart.errorLogEntries, errorLogEntries > 0 {
            raise(.warning, "\(errorLogEntries) Einträge im Fehlerprotokoll")
        }

        if let failingAttribute = smart.ataAttributes.first(where: \.isFailingNow) {
            raise(.problem, "SMART-Attribut unter Schwelle: \(failingAttribute.displayName)")
        }

        if let temperature = smart.temperatureCelsius {
            let warningLimit = min(thresholds.temperatureWarning, smart.deviceOperatingLimit ?? .greatestFiniteMagnitude)
            let criticalLimit = min(thresholds.temperatureCritical, smart.deviceCriticalLimit ?? .greatestFiniteMagnitude)
            let effectiveWarning = min(warningLimit, criticalLimit)

            if temperature >= criticalLimit {
                raise(.problem, "Temperatur kritisch (\(Format.number(temperature)) °C)")
            } else if temperature >= effectiveWarning {
                raise(.warning, "Temperatur hoch (\(Format.number(temperature)) °C)")
            }
        }

        if level == .ok {
            reasons.append("SMART-Status in Ordnung")
        }

        // Keep only unique reasons, preserving order.
        var seen = Set<String>()
        reasons = reasons.filter { seen.insert($0).inserted }

        return Evaluation(level: level, reasons: reasons)
    }

    private static func evaluateDiskutilFallback(status: String, thresholds: HealthThresholds) -> Evaluation {
        let lower = status.lowercased()
        if lower.contains("failing") || lower.contains("failed") {
            return Evaluation(level: .problem, reasons: ["SMART-Status: \(status)"])
        }
        if lower.contains("verified") || lower.contains("ok") {
            return Evaluation(level: .ok, reasons: ["SMART-Status: \(status) (Basisprüfung)"])
        }
        if lower.contains("not supported") || lower.contains("unsupported") {
            return Evaluation(level: .warning, reasons: ["SMART wird von diesem Gerät nicht unterstützt"])
        }
        return Evaluation(level: .unknown, reasons: ["SMART-Status: \(status)"])
    }

    // MARK: RAID

    public static func evaluate(raid: RaidSetInfo) -> Evaluation {
        var level: HealthLevel = .ok
        var reasons: [String] = []

        func raise(_ newLevel: HealthLevel, _ reason: String) {
            if newLevel > level { level = newLevel }
            reasons.append(reason)
        }

        let setStatus = raid.status.lowercased()
        if raid.members.isEmpty {
            raise(.warning, "Keine Mitglieder gefunden")
        }

        if setStatus.contains("degraded") {
            raise(.problem, "RAID degradiert")
        } else if setStatus.contains("offline") || setStatus.contains("failed") || setStatus.contains("not online") {
            raise(.problem, "RAID \(raid.status)")
        } else if !setStatus.contains("online") {
            raise(.warning, "RAID-Status: \(raid.status)")
        }

        for member in raid.members {
            let status = member.status.lowercased()
            if status.contains("online") {
                continue
            } else if status.contains("rebuild") || status.contains("resync") {
                raise(.warning, "Mitglied \(member.bsdName) wird neu aufgebaut")
            } else if status.contains("missing") || status.contains("offline") || status.contains("failed") || status.contains("degraded") {
                raise(.problem, "Mitglied \(member.bsdName): \(member.status)")
            } else {
                raise(.warning, "Mitglied \(member.bsdName): \(member.status)")
            }
        }

        if let progress = raid.rebuildProgress {
            raise(.warning, "Rebuild läuft (\(Format.number(progress)) %)")
        }

        if level == .ok {
            reasons.append("RAID \(raid.status)")
        }

        var seen = Set<String>()
        reasons = reasons.filter { seen.insert($0).inserted }

        return Evaluation(level: level, reasons: reasons)
    }
}

// MARK: - Formatting

public enum Format {
    public static func number(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    public static func hours(_ value: Double) -> String {
        let hours = Int(value.rounded())
        if hours >= 24 {
            let days = hours / 24
            return "\(hours) h (\(days) Tage)"
        }
        return "\(hours) h"
    }
}

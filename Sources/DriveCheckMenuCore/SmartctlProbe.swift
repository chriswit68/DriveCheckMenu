import Foundation

// MARK: - Locator

public enum SmartctlLocator {
    public static let candidatePaths = [
        "/opt/homebrew/bin/smartctl",
        "/usr/local/bin/smartctl",
        "/opt/local/bin/smartctl",
        "/usr/bin/smartctl"
    ]

    public static func locate(override: String? = nil) -> String? {
        if let override, !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        return candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func version(at path: String) -> String? {
        let result = Shell.run(path, ["--version"], timeout: 5)
        guard result.status == 0 else { return nil }
        guard let firstLine = result.stdout.components(separatedBy: .newlines).first else { return nil }
        // "smartctl 7.5 2025-04-30 r5714 [Darwin 27.2.0 arm64] (local build)"
        let parts = firstLine.split(separator: " ")
        if parts.count >= 2, parts[0] == "smartctl" {
            return String(parts[1])
        }
        return firstLine
    }
}

// MARK: - Probe

public enum SmartctlProbe {
    /// Reads detailed SMART data for a BSD device. Falls back through device type hints.
    public static func probe(bsdName: String, smartctlPath: String) -> SmartHealth {
        guard bsdName.hasPrefix("disk") else {
            var health = SmartHealth(source: .smartctl)
            health.unavailableReason = "Ungültiges Gerät"
            return health
        }

        let deviceArguments: [[String]] = [
            [],
            ["-d", "sat"],
            ["-d", "nvme"]
        ]

        var lastHealth: SmartHealth?
        for extra in deviceArguments {
            let args = ["-a", "-j", "-n", "standby"] + extra + [bsdName]
            let result = Shell.run(smartctlPath, args, timeout: 20)

            if let health = SmartctlParser.parse(
                output: result.stdout,
                stderr: result.stderr,
                exitStatus: result.status
            ) {
                if health.unavailableReason == nil || health.passed != nil || health.temperatureCelsius != nil {
                    return health
                }
                lastHealth = health
            } else if outputIndicatesPermissionProblem(result.combinedOutput) {
                var health = SmartHealth(source: .smartctl)
                health.unavailableReason = "Administratorrechte erforderlich"
                health.messages = [firstMeaningfulLine(result.combinedOutput)].compactMap { $0 }
                return health
            }
        }

        if let lastHealth { return lastHealth }

        var health = SmartHealth(source: .smartctl)
        let result = Shell.run(smartctlPath, ["-a", "-j", "-n", "standby", bsdName], timeout: 20)
        health.unavailableReason = firstMeaningfulLine(result.combinedOutput) ?? "SMART-Daten nicht verfügbar"
        return health
    }

    private static func outputIndicatesPermissionProblem(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("permission denied")
            || lower.contains("operation not permitted")
            || lower.contains("must be root")
            || lower.contains("requires root")
    }

    private static func firstMeaningfulLine(_ output: String) -> String? {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("{") && !$0.hasPrefix("}") && !$0.hasPrefix("\"") }
    }
}

// MARK: - Parser

public enum SmartctlParser {
    /// Parses smartctl JSON output. Returns nil when no JSON could be decoded.
    public static func parse(output: String, stderr: String = "", exitStatus: Int32 = 0) -> SmartHealth? {
        guard
            let data = output.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return parse(json: root, stderr: stderr, exitStatus: exitStatus)
    }

    public static func parse(json root: [String: Any], stderr: String = "", exitStatus: Int32 = 0) -> SmartHealth {
        var health = SmartHealth(source: .smartctl)

        let device = root.dict("device")
        health.deviceType = device?.string("type") ?? device?.string("protocol")
        health.modelName = root.string("model_name")
        health.serialNumber = root.string("serial_number")
        if let capacity = root.dict("user_capacity")?.number("bytes") {
            health.capacityBytes = Int64(capacity)
        }

        if let smartStatus = root.dict("smart_status") {
            health.passed = smartStatus.bool("passed")
        }

        if let temperature = root.dict("temperature") {
            health.temperatureCelsius = temperature.number("current")
            health.deviceOperatingLimit = temperature.number("op_limit_max")
            health.deviceCriticalLimit = temperature.number("critical_limit_max")
            if health.temperatureCelsius == nil {
                health.temperatureCelsius = temperature.number("drive_trip")
            }
        }

        health.rotationRate = root.int("rotation_rate")

        let nvme = root.dict("nvme_smart_health_information_log")
        if let nvme {
            if health.temperatureCelsius == nil {
                health.temperatureCelsius = nvme.number("temperature")
            }
            if let sensors = nvme["temperature_sensors"] as? [Any] {
                health.temperatureSensors = sensors.compactMap { numberValue($0) }
                if health.temperatureCelsius == nil, let first = health.temperatureSensors.first {
                    health.temperatureCelsius = first
                }
            }
            health.criticalWarning = nvme.int("critical_warning")
            health.availableSpare = nvme.number("available_spare")
            health.availableSpareThreshold = nvme.number("available_spare_threshold")
            health.percentageUsed = nvme.number("percentage_used")
            health.mediaErrors = nvme.int("media_errors")
            health.errorLogEntries = nvme.int("num_err_log_entries")
            health.unsafeShutdowns = nvme.int("unsafe_shutdowns")
            health.powerCycles = nvme.int("power_cycles")
            if let hours = nvme.number("power_on_hours") {
                health.powerOnHours = hours
            }
        }

        if let powerOnTime = root.dict("power_on_time") {
            if health.powerOnHours == nil {
                health.powerOnHours = powerOnTime.number("hours")
            }
        }
        if health.powerCycles == nil {
            health.powerCycles = root.int("power_cycle_count")
        }

        if let ata = root.dict("ata_smart_attributes"), let table = ata["table"] as? [[String: Any]] {
            let attributes = table.compactMap(parseAttribute)
            health.ataAttributes = attributes

            for attribute in attributes {
                switch normalizedAttributeName(attribute.name) {
                case "reallocated_sector_ct":
                    health.reallocatedSectors = Int(attribute.rawValue ?? 0)
                case "current_pending_sector":
                    health.pendingSectors = Int(attribute.rawValue ?? 0)
                case "offline_uncorrectable", "uncorrectable_error_cnt", "uncorrectable_sector_ct":
                    health.uncorrectableSectors = Int(attribute.rawValue ?? 0)
                case "temperature_celsius", "airflow_temperature_cel":
                    if health.temperatureCelsius == nil, let raw = attribute.rawValue {
                        health.temperatureCelsius = raw
                    }
                case "power_on_hours":
                    if health.powerOnHours == nil, let raw = attribute.rawValue {
                        health.powerOnHours = raw
                    }
                case "wear_leveling_count", "media_wearout_indicator", "ssd_life_left":
                    health.wearLevelingPercent = max(0, min(100, 100 - Double(attribute.value)))
                case "program_fail_cnt_total", "erase_fail_count_total", "runtime_bad_block",
                     "reported_uncorrect", "command_timeout", "crc_error_count":
                    break // visible in the detailed attribute list
                default:
                    break
                }
            }

            if health.passed == nil, let firstFailure = attributes.first(where: \.isFailingNow) {
                health.passed = false
                health.messages.append("Attribut unter Herstellerschwelle: \(firstFailure.displayName)")
            }
        }

        if let powerMode = root.string("power_mode") {
            health.powerMode = powerMode
            if powerMode.uppercased().contains("STANDBY") || powerMode.uppercased().contains("SLEEP") {
                health.isStandby = true
            }
        }

        if let smartctl = root.dict("smartctl"), let messages = smartctl["messages"] as? [[String: Any]] {
            for message in messages {
                guard let text = message.string("string"), !text.isEmpty else { continue }
                health.messages.append(text)
            }
        }

        if health.messages.isEmpty, !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            health.messages.append(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Only treat the upper exit status bits (< 128) as meaningful. Bit 0/1/2 are
        // command/open failures, 3/4/5 indicate a failing disk, 6/7 problems in the logs.
        let bits = Int(exitStatus) & 0x7f
        if bits & (1 << 3) != 0 || bits & (1 << 4) != 0 || bits & (1 << 5) != 0 {
            health.passed = false
        }
        if bits & (1 << 0) != 0 || bits & (1 << 1) != 0 {
            if health.passed == nil, health.unavailableReason == nil {
                health.unavailableReason = "smartctl konnte das Gerät nicht öffnen"
            }
        }

        if let selfTest = root.dict("nvme_self_test_log") {
            health.lastSelfTest = SelfTestParser.summary(fromNVMe: selfTest)
        } else if let ataLog = root.dict("ata_smart_self_test_log") {
            health.lastSelfTest = SelfTestParser.summary(fromATA: ataLog)
        }

        if health.isStandby {
            health.unavailableReason = "Laufwerk im Standby"
        }

        return health
    }

    private static func parseAttribute(_ dict: [String: Any]) -> AtaAttribute? {
        guard let id = dict.int("id"), let name = dict.string("name"), let value = dict.int("value") else {
            return nil
        }
        let flags = dict.dict("flags")
        let raw = dict.dict("raw")
        var rawValue: Double?
        var rawString: String?
        if let raw {
            rawValue = raw.number("value") ?? raw.number("string")
            rawString = raw.string("string")
            if rawValue == nil, let string = rawString {
                rawValue = Double(string.split(separator: " ").first ?? "")
            }
        }
        return AtaAttribute(
            id: id,
            name: name,
            value: value,
            worst: dict.int("worst"),
            threshold: dict.int("thresh"),
            rawValue: rawValue,
            rawString: rawString,
            prefailure: flags?.bool("prefailure") ?? false
        )
    }

    private static func normalizedAttributeName(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "_")
    }
}

// MARK: - JSON helpers

extension Dictionary where Key == String, Value == Any {
    func dict(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func string(_ key: String) -> String? {
        if let value = self[key] as? String { return value }
        if let value = self[key] as? NSNumber { return value.stringValue }
        return nil
    }

    func number(_ key: String) -> Double? {
        numberValue(self[key])
    }

    func int(_ key: String) -> Int? {
        if let number = numberValue(self[key]) { return Int(number) }
        if let string = self[key] as? String { return Int(string) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let value = self[key] as? Bool { return value }
        if let value = self[key] as? NSNumber { return value.boolValue }
        if let value = self[key] as? String {
            switch value.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }
}

func numberValue(_ value: Any?) -> Double? {
    switch value {
    case let value as Double: return value
    case let value as Int: return Double(value)
    case let value as Int64: return Double(value)
    case let value as NSNumber: return value.doubleValue
    case let value as String:
        let normalized = value.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    default: return nil
    }
}

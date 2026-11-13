import Foundation

public enum PlistHelper {
    public static func dictionary(from data: Data) -> [String: Any]? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        return object as? [String: Any]
    }

    public static func dictionary(fromFileAt path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return dictionary(from: data)
    }
}

public enum DiskInventory {
    public static let diskutilPath = "/usr/sbin/diskutil"

    /// Lists all physical whole disks (virtual/synthesized disks are filtered out).
    public static func physicalDisks() -> [DriveInfo] {
        let listResult = Shell.run(diskutilPath, ["list", "-plist"])
        guard
            let listDict = PlistHelper.dictionary(from: Data(listResult.stdout.utf8)),
            let wholeDisks = listDict["WholeDisks"] as? [String]
        else {
            return []
        }

        var drives: [DriveInfo] = []
        for bsdName in wholeDisks {
            guard bsdName.hasPrefix("disk") else { continue }
            guard let drive = driveInfo(bsdName: bsdName) else { continue }
            drives.append(drive)
        }

        // Deterministic ordering: external first, then by model/BSD name.
        return drives.sorted {
            if $0.isInternal != $1.isInternal { return !$0.isInternal }
            if $0.model != $1.model { return $0.model.localizedStandardCompare($1.model) == .orderedAscending }
            return $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending
        }
    }

    /// Reads `diskutil info -plist` for a whole disk and filters out virtual devices.
    public static func driveInfo(bsdName: String) -> DriveInfo? {
        let result = Shell.run(diskutilPath, ["info", "-plist", bsdName])
        guard let dict = PlistHelper.dictionary(from: Data(result.stdout.utf8)) else { return nil }

        guard bool(dict["WholeDisk"]) == true else { return nil }
        if let virtualOrPhysical = dict["VirtualOrPhysical"] as? String,
           virtualOrPhysical.caseInsensitiveCompare("Virtual") == .orderedSame {
            return nil
        }

        let model = (dict["MediaName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (dict["IORegistryEntryName"] as? String)
            ?? bsdName
        let size = int64(dict["TotalSize"]) ?? int64(dict["IOKitSize"]) ?? int64(dict["Size"]) ?? 0

        return DriveInfo(
            id: StableID.modelFallback(model: model, size: size),
            bsdName: bsdName,
            model: model,
            serial: nil,
            sizeBytes: size,
            isInternal: bool(dict["Internal"]) ?? false,
            isSolidState: bool(dict["SolidState"]) ?? false,
            protocolName: (dict["BusProtocol"] as? String) ?? "Unbekannt",
            isEjectable: bool(dict["Ejectable"]) ?? false,
            smartStatusRaw: dict["SMARTStatus"] as? String,
            mediaName: (dict["MediaName"] as? String) ?? model
        )
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value != 0 }
        if let value = value as? String {
            switch value.lowercased() {
            case "yes", "true", "1": return true
            case "no", "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }
}

public enum StableID {
    public static func key(serial: String?, model: String, size: Int64) -> String {
        if let serial, !serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "serial:\(serial.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return modelFallback(model: model, size: size)
    }

    public static func modelFallback(model: String, size: Int64) -> String {
        "model:\(model)|\(size)"
    }
}

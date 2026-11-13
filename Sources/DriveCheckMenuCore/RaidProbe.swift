import Foundation

public enum RaidProbe {
    /// Reads all AppleRAID sets. Returns an empty array when no set is configured.
    public static func sets() -> [RaidSetInfo] {
        let result = Shell.run(DiskInventory.diskutilPath, ["appleRAID", "list", "-plist"])
        guard
            let dict = PlistHelper.dictionary(from: Data(result.stdout.utf8)),
            let rawSets = dict["AppleRAIDSets"] as? [[String: Any]]
        else {
            return []
        }

        let text = Shell.run(DiskInventory.diskutilPath, ["appleRAID", "list"]).stdout
        return rawSets.map { parse(set: $0, text: text) }
    }

    public static func parse(set: [String: Any], text: String = "") -> RaidSetInfo {
        let uuid = (set["AppleRAIDSetUUID"] as? String) ?? (set["BSD Name"] as? String) ?? UUID().uuidString
        let name = (set["Name"] as? String) ?? ""
        let bsdName = (set["BSD Name"] as? String) ?? ""
        let level = (set["Level"] as? String) ?? ""
        let status = (set["Status"] as? String) ?? "Unbekannt"
        let size = int64(set["Size"]) ?? 0

        let members = (set["Members"] as? [[String: Any]] ?? []).compactMap { member -> RaidMember? in
            let memberUUID = (member["AppleRAIDMemberUUID"] as? String) ?? (member["BSD Name"] as? String) ?? UUID().uuidString
            guard let memberBSD = member["BSD Name"] as? String else { return nil }
            return RaidMember(
                id: memberUUID,
                bsdName: memberBSD,
                status: (member["MemberStatus"] as? String) ?? "Unbekannt"
            )
        }

        let progress = rebuildProgress(set: set, text: text, setName: name)

        return RaidSetInfo(
            id: uuid,
            name: name,
            level: level,
            status: status,
            bsdName: bsdName,
            sizeBytes: size,
            members: members,
            rebuildProgress: progress
        )
    }

    private static func rebuildProgress(set: [String: Any], text: String, setName: String) -> Double? {
        // Newer diskutil versions may expose a numeric rebuild progress in the plist.
        for (key, value) in set {
            let lower = key.lowercased()
            guard lower.contains("rebuild") || lower.contains("progress") else { continue }
            if let number = value as? NSNumber {
                let doubleValue = number.doubleValue
                if doubleValue >= 0, doubleValue <= 100 { return doubleValue }
                if doubleValue > 100, doubleValue <= 1 { return doubleValue * 100 }
            }
            if let string = value as? String,
               let match = firstPercent(in: string) {
                return match
            }
        }

        // Fall back to the human readable output, scoped to the set's section when possible.
        guard !text.isEmpty else { return nil }
        let lines = text.components(separatedBy: .newlines)
        var inSection = setName.isEmpty
        for line in lines {
            if line.contains("Name:") {
                inSection = setName.isEmpty || line.contains(setName)
            }
            guard inSection else { continue }
            let lower = line.lowercased()
            if lower.contains("rebuild") || lower.contains("rebuil") {
                if let percent = firstPercent(in: line) { return percent }
            }
        }
        return nil
    }

    private static func firstPercent(in string: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,3}(?:[.,]\d+)?)\s*%"#) else { return nil }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: range), match.numberOfRanges > 1 else { return nil }
        guard let valueRange = Range(match.range(at: 1), in: string) else { return nil }
        let normalized = string[valueRange].replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized) else { return nil }
        return value
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }
}

import Foundation

public struct SelfTestStatus: Sendable, Equatable {
    public var running: Bool
    public var finished: Bool
    public var percentRemaining: Double?
    public var message: String

    public init(running: Bool, finished: Bool, percentRemaining: Double? = nil, message: String) {
        self.running = running
        self.finished = finished
        self.percentRemaining = percentRemaining
        self.message = message
    }
}

public enum SelfTestParser {
    /// Parses `smartctl -l selftest -j` output.
    public static func parse(output: String) -> SelfTestStatus? {
        guard
            let data = output.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        if let nvme = root.dict("nvme_self_test_log") {
            if let current = nvme.dict("current_self_test_operation") {
                let text = current.string("string") ?? ""
                let value = current.int("value") ?? 0
                if text.lowercased().contains("no self-test") || value == 0 {
                    let last = nvmeTable(nvme)?.first
                    let result = last?.string("result") ?? "Kein Selbsttest protokolliert"
                    return SelfTestStatus(running: false, finished: true, percentRemaining: nil, message: result)
                }
                let remaining = current.number("remaining_percent")
                return SelfTestStatus(running: true, finished: false, percentRemaining: remaining, message: text)
            }
        }

        if let ata = root.dict("ata_smart_self_test_log") {
            if let status = summaryStatus(fromATA: ata) {
                return status
            }
        }

        return nil
    }

    public static func summary(fromNVMe nvme: [String: Any]) -> String? {
        if let current = nvme.dict("current_self_test_operation") {
            let text = current.string("string") ?? ""
            if !text.lowercased().contains("no self-test") {
                return text
            }
        }
        return nvmeTable(nvme)?.first?.string("result")
    }

    public static func summary(fromATA ata: [String: Any]) -> String? {
        guard let table = ataTable(ata), let first = table.first else { return nil }
        return first.dict("status")?.string("string")
            ?? first.string("status")
            ?? first.string("type")
    }

    private static func summaryStatus(fromATA ata: [String: Any]) -> SelfTestStatus? {
        guard let table = ataTable(ata), let first = table.first else { return nil }
        let statusDict = first.dict("status")
        let text = statusDict?.string("string") ?? first.string("status") ?? ""
        let lower = text.lowercased()

        var remaining = statusDict?.number("remaining_percent")
        if remaining == nil, let match = firstPercent(in: text) {
            remaining = match
        }

        if lower.contains("in progress") || lower.contains("self-test routine") && !lower.contains("completed") {
            return SelfTestStatus(running: true, finished: false, percentRemaining: remaining, message: text)
        }
        if lower.contains("completed") || lower.contains("without error") || lower.contains("failure") || lower.contains("failed") {
            return SelfTestStatus(running: false, finished: true, percentRemaining: nil, message: text)
        }
        if !text.isEmpty {
            return SelfTestStatus(running: false, finished: true, percentRemaining: nil, message: text)
        }
        return nil
    }

    private static func nvmeTable(_ nvme: [String: Any]) -> [[String: Any]]? {
        nvme["table"] as? [[String: Any]]
    }

    private static func ataTable(_ ata: [String: Any]) -> [[String: Any]]? {
        if let standard = ata.dict("standard") {
            return standard["table"] as? [[String: Any]]
        }
        return ata["table"] as? [[String: Any]]
    }

    private static func firstPercent(in string: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,3}(?:[.,]\d+)?)\s*%"#) else { return nil }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: range), match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: string) else { return nil }
        return Double(string[valueRange].replacingOccurrences(of: ",", with: "."))
    }
}

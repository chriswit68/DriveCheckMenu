import XCTest
@testable import DriveCheckMenuCore

final class DriveCheckMenuTests: XCTestCase {
    // MARK: Fixtures

    private func fixtureURL(_ name: String, extension ext: String) throws -> URL {
        if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") {
            return url
        }
        if let url = Bundle.module.url(forResource: name, withExtension: ext) {
            return url
        }
        throw XCTSkip("Fixture \(name).\(ext) nicht gefunden")
    }

    private func fixtureData(_ name: String, extension ext: String) throws -> Data {
        try Data(contentsOf: try fixtureURL(name, extension: ext))
    }

    private func fixtureJSON(_ name: String) throws -> [String: Any] {
        let data = try fixtureData(name, extension: "json")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func fixturePlist(_ name: String) throws -> [String: Any] {
        let data = try fixtureData(name, extension: "plist")
        return try XCTUnwrap(PlistHelper.dictionary(from: data))
    }

    private func drive(
        id: String = "serial:ABC",
        bsdName: String = "disk9",
        model: String = "Test Disk",
        serial: String? = "ABC",
        size: Int64 = 1_000
    ) -> DriveInfo {
        DriveInfo(
            id: id,
            bsdName: bsdName,
            model: model,
            serial: serial,
            sizeBytes: size,
            isInternal: false,
            isSolidState: true,
            protocolName: "PCI-Express",
            isEjectable: true
        )
    }

    // MARK: SMART parsing (NVMe)

    func testParsesNvmeSmartData() throws {
        let json = try fixtureJSON("smartctl_nvme")
        let health = SmartctlParser.parse(json: json)

        XCTAssertEqual(health.source, .smartctl)
        XCTAssertEqual(health.passed, true)
        XCTAssertEqual(health.modelName, "Samsung SSD 980 PRO 1TB")
        XCTAssertEqual(health.serialNumber, "S5GXNX0W336058E")
        XCTAssertEqual(health.temperatureCelsius, 34)
        XCTAssertEqual(health.temperatureSensors, [34, 43])
        XCTAssertEqual(health.percentageUsed, 0)
        XCTAssertEqual(health.availableSpare, 100)
        XCTAssertEqual(health.availableSpareThreshold, 10)
        XCTAssertEqual(health.mediaErrors, 0)
        XCTAssertEqual(health.criticalWarning, 0)
        XCTAssertEqual(health.powerOnHours, 1131)
        XCTAssertEqual(health.unsafeShutdowns, 2)
        XCTAssertTrue(health.hasUsableData)
        XCTAssertNil(health.unavailableReason)
    }

    func testParsesAtaAttributes() throws {
        let json = try fixtureJSON("smartctl_ata")
        let health = SmartctlParser.parse(json: json)

        XCTAssertEqual(health.source, .smartctl)
        XCTAssertEqual(health.passed, true)
        XCTAssertEqual(health.temperatureCelsius, 25)
        XCTAssertEqual(health.reallocatedSectors, 0)
        XCTAssertNil(health.pendingSectors)
        XCTAssertEqual(health.uncorrectableSectors, 0)
        XCTAssertEqual(health.wearLevelingPercent ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(health.powerOnHours, 84583)
        XCTAssertFalse(health.ataAttributes.isEmpty)
    }

    func testErrorLogReadFailureDoesNotMarkDiskAsFailing() throws {
        var json = try fixtureJSON("smartctl_nvme_errorlog")
        // smartctl exits with code 4 because reading the error log failed, but the
        // disk itself is healthy. The exit code alone must not turn the icon red.
        json["smartctl"] = merge(json["smartctl"] as? [String: Any] ?? [:], ["exit_status": 4])

        let health = SmartctlParser.parse(json: json, exitStatus: 4)
        XCTAssertEqual(health.passed, true)
        XCTAssertFalse(health.messages.isEmpty)

        let evaluation = HealthEvaluator.evaluate(
            smart: health,
            diskutilStatus: "Verified",
            thresholds: .default
        )
        XCTAssertEqual(evaluation.level, .ok)
    }

    func testFailingExitBitsMarkProblem() {
        var health = SmartHealth(source: .smartctl)
        health.passed = true
        let json: [String: Any] = [
            "smart_status": ["passed": true],
            "device": ["name": "disk9", "type": "ata", "protocol": "ATA"]
        ]
        let parsed = SmartctlParser.parse(json: json, exitStatus: 8) // bit 3: disk failing
        XCTAssertEqual(parsed.passed, false)
        XCTAssertNotNil(health.passed)
    }

    // MARK: Health evaluation

    func testTemperatureWarningAndCritical() {
        var smart = SmartHealth(source: .smartctl)
        smart.passed = true
        smart.temperatureCelsius = 61

        var evaluation = HealthEvaluator.evaluate(smart: smart, diskutilStatus: nil, thresholds: .default)
        XCTAssertEqual(evaluation.level, .warning)

        smart.temperatureCelsius = 76
        evaluation = HealthEvaluator.evaluate(smart: smart, diskutilStatus: nil, thresholds: .default)
        XCTAssertEqual(evaluation.level, .problem)
    }

    func testWearThresholds() {
        var smart = SmartHealth(source: .smartctl)
        smart.passed = true
        smart.percentageUsed = 95

        var evaluation = HealthEvaluator.evaluate(smart: smart, diskutilStatus: nil, thresholds: .default)
        XCTAssertEqual(evaluation.level, .warning)

        smart.percentageUsed = 100
        evaluation = HealthEvaluator.evaluate(smart: smart, diskutilStatus: nil, thresholds: .default)
        XCTAssertEqual(evaluation.level, .problem)
    }

    func testMediaErrorsAndSectors() {
        var smart = SmartHealth(source: .smartctl)
        smart.passed = true
        smart.mediaErrors = 3
        var evaluation = HealthEvaluator.evaluate(smart: smart, diskutilStatus: nil, thresholds: .default)
        XCTAssertEqual(evaluation.level, .warning)

        smart = SmartHealth(source: .smartctl)
        smart.passed = true
        smart.pendingSectors = 2
        evaluation = HealthEvaluator.evaluate(smart: smart, diskutilStatus: nil, thresholds: .default)
        XCTAssertEqual(evaluation.level, .problem)
    }

    func testDiskutilFallback() {
        let verified = HealthEvaluator.evaluate(smart: nil, diskutilStatus: "Verified", thresholds: .default)
        XCTAssertEqual(verified.level, .ok)

        let failing = HealthEvaluator.evaluate(smart: nil, diskutilStatus: "Failing", thresholds: .default)
        XCTAssertEqual(failing.level, .problem)

        let unsupported = HealthEvaluator.evaluate(smart: nil, diskutilStatus: "Not Supported", thresholds: .default)
        XCTAssertEqual(unsupported.level, .warning)
    }

    func testStandbyIsWarning() {
        var smart = SmartHealth(source: .smartctl)
        smart.passed = true
        smart.isStandby = true
        smart.unavailableReason = "Laufwerk im Standby"

        let evaluation = HealthEvaluator.evaluate(smart: smart, diskutilStatus: "Verified", thresholds: .default)
        XCTAssertEqual(evaluation.level, .warning)
    }

    // MARK: RAID

    func testParsesAppleRaidSet() throws {
        let plist = try fixturePlist("appleraid_list")
        let sets = try XCTUnwrap(plist["AppleRAIDSets"] as? [[String: Any]])
        XCTAssertEqual(sets.count, 1)

        let raid = RaidProbe.parse(set: try XCTUnwrap(sets.first))
        XCTAssertEqual(raid.name, "RAID1-SAMSUNG-SSD-1TB")
        XCTAssertEqual(raid.level, "Mirror")
        XCTAssertEqual(raid.status, "Online")
        XCTAssertEqual(raid.members.count, 2)
        XCTAssertEqual(raid.id, "D3ABDE08-13A0-42B7-9C73-AEDEDCF3F0AE")
        XCTAssertEqual(raid.sizeBytes, 999_860_731_904)

        let evaluation = HealthEvaluator.evaluate(raid: raid)
        XCTAssertEqual(evaluation.level, .ok)
    }

    func testDegradedRaidIsProblem() {
        let raid = RaidSetInfo(
            id: "RAID-UUID",
            name: "Test RAID",
            level: "Mirror",
            status: "Degraded",
            bsdName: "disk8",
            sizeBytes: 1_000_000,
            members: [
                RaidMember(id: "1", bsdName: "disk4s2", status: "Online"),
                RaidMember(id: "2", bsdName: "disk5s2", status: "Offline")
            ]
        )
        let evaluation = HealthEvaluator.evaluate(raid: raid)
        XCTAssertEqual(evaluation.level, .problem)
    }

    func testRebuildIsWarning() {
        let raid = RaidSetInfo(
            id: "RAID-UUID",
            name: "Test RAID",
            level: "Mirror",
            status: "Online",
            bsdName: "disk8",
            sizeBytes: 1_000_000,
            members: [
                RaidMember(id: "1", bsdName: "disk4s2", status: "Online"),
                RaidMember(id: "2", bsdName: "disk5s2", status: "Rebuilding")
            ],
            rebuildProgress: 42
        )
        let evaluation = HealthEvaluator.evaluate(raid: raid)
        XCTAssertEqual(evaluation.level, .warning)
    }

    // MARK: Self test

    func testSelfTestParserNvmeIdle() throws {
        let data = try fixtureData("smartctl_selftest_nvme", extension: "json")
        let output = try XCTUnwrap(String(data: data, encoding: .utf8))
        let status = try XCTUnwrap(SelfTestParser.parse(output: output))
        XCTAssertFalse(status.running)
        XCTAssertTrue(status.finished)
    }

    func testSelfTestParserAtaInProgress() {
        let json: [String: Any] = [
            "ata_smart_self_test_log": [
                "standard": [
                    "table": [
                        [
                            "type": ["string": "Short offline"],
                            "status": ["string": "Self-test routine in progress", "remaining_percent": 80]
                        ]
                    ]
                ]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let output = String(data: data, encoding: .utf8)!
        let status = SelfTestParser.parse(output: output)
        XCTAssertEqual(status?.running, true)
        XCTAssertEqual(status?.percentRemaining, 80)
    }

    // MARK: Selection

    func testSelectionMatcherUsesSerialAndModelFallback() {
        let diskA = drive(id: "serial:AAA", bsdName: "disk4", model: "Samsung 980", serial: "AAA")
        let diskB = drive(id: "model:Samsung 990|2000", bsdName: "disk5", model: "Samsung 990", serial: nil, size: 2_000)

        let stored = [
            StoredDrive(id: "old-key", name: "Samsung 980", model: "Samsung 980", sizeBytes: 1_000, serial: "AAA"),
            StoredDrive(id: "serial:not-present", name: "Samsung 990", model: "Samsung 990", sizeBytes: 2_000, serial: "BBB")
        ]

        let matched = SelectionMatcher.matchedDriveIDs(stored, available: [diskA, diskB])
        XCTAssertTrue(matched.contains(diskA.id))
        XCTAssertTrue(matched.contains(diskB.id))
    }

    func testSnapshotOverallAggregation() {
        let okDrive = DriveStatus(drive: drive(), health: .ok, isMonitored: true)
        let warningRaid = RaidStatus(
            raid: RaidSetInfo(id: "r", name: "R", level: "Mirror", status: "Online", bsdName: "disk8", sizeBytes: 1, members: []),
            health: .warning,
            isMonitored: true
        )
        var snapshot = MonitorSnapshot(drives: [okDrive], raids: [warningRaid])
        snapshot.recalculateOverall()

        XCTAssertEqual(snapshot.overall, .warning)
        XCTAssertEqual(snapshot.warningCount, 1)
        XCTAssertEqual(snapshot.problemCount, 0)
        XCTAssertEqual(snapshot.monitoredDriveCount, 1)
        XCTAssertEqual(snapshot.monitoredRaidCount, 1)
    }

    // MARK: Settings

    func testSettingsRoundTripAndBackwardsCompatibility() throws {
        var settings = AppSettings()
        settings.selectedDrives = [StoredDrive(id: "serial:AAA", name: "Disk", model: "Disk", sizeBytes: 1, serial: "AAA")]
        settings.selectedRaids = [StoredRaid(id: "RAID", name: "Raid", level: "Mirror", sizeBytes: 2)]
        settings.thresholds.temperatureWarning = 55

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, settings)

        // Missing keys must fall back to defaults instead of failing to decode.
        let partial = #"{"intervalSeconds": 60}"#.data(using: .utf8)!
        let partialSettings = try JSONDecoder().decode(AppSettings.self, from: partial)
        XCTAssertEqual(partialSettings.intervalSeconds, 60)
        XCTAssertEqual(partialSettings.thresholds, .default)
        XCTAssertTrue(partialSettings.useSmartctl)
        XCTAssertTrue(partialSettings.notifyOnChange)
    }

    func testSettingsStorePersists() {
        let suiteName = "DriveCheckMenuTests-\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        var settings = store.load()
        XCTAssertFalse(settings.defaultSelectionApplied)

        settings.defaultSelectionApplied = true
        settings.intervalSeconds = 900
        store.save(settings)

        let reloaded = store.load()
        XCTAssertTrue(reloaded.defaultSelectionApplied)
        XCTAssertEqual(reloaded.intervalSeconds, 900)
    }

    // MARK: Storage usage

    func testStorageUsageMappingFromDiskutilList() throws {
        let plist = try fixturePlist("diskutil_list")
        let hierarchy = try XCTUnwrap(plist["AllDisksAndPartitions"] as? [[String: Any]])

        let containerSize = Int64(999_860_731_904)
        let mounts = [
            MountedVolumeSample(device: "/dev/disk9s1", totalBytes: containerSize, usedBytes: 265_008_218_112),
            MountedVolumeSample(device: "/dev/disk7s2", totalBytes: 511_900_434_432, usedBytes: 263_735_578_624),
            MountedVolumeSample(device: "/dev/disk3s5", totalBytes: 494_332_366_848, usedBytes: 92_725_604_352),
            // Same APFS container as disk3s5 (root snapshot): must not be counted twice.
            MountedVolumeSample(device: "/dev/disk3s1s1", totalBytes: 494_332_366_848, usedBytes: 92_725_604_352)
        ]

        let usages = StorageUsageProbe.usages(allDisksAndPartitions: hierarchy, mounts: mounts)

        // RAID set disk8 is the physical store of the APFS container disk9.
        XCTAssertEqual(usages["disk8"]?.usedBytes, 265_008_218_112)
        XCTAssertEqual(usages["disk8"]?.totalBytes, containerSize)

        // External disk6 hosts container disk7.
        XCTAssertEqual(usages["disk6"]?.usedBytes, 263_735_578_624)
        XCTAssertEqual(usages["disk6"]?.totalBytes, 511_900_434_432)

        // Internal disk0: container disk3 counted once despite two mount samples; the
        // mounted container disk1 has no sample here and falls back to CapacityInUse.
        XCTAssertEqual(usages["disk0"]?.usedBytes, 92_738_707_456)
        XCTAssertEqual(usages["disk0"]?.totalBytes, 494_909_083_648)

        // RAID members have no file system of their own.
        XCTAssertNil(usages["disk4"])
        XCTAssertNil(usages["disk5"])
    }

    func testStorageUsageFallsBackToCapacityInUse() throws {
        let plist = try fixturePlist("diskutil_list")
        let hierarchy = try XCTUnwrap(plist["AllDisksAndPartitions"] as? [[String: Any]])

        let usages = StorageUsageProbe.usages(allDisksAndPartitions: hierarchy, mounts: [])

        // Disk1 (13_103_104) + disk3 volumes without the snapshot duplicate (95_979_520_000).
        XCTAssertEqual(usages["disk0"]?.usedBytes, 95_992_623_104)
        XCTAssertEqual(usages["disk0"]?.totalBytes, 494_909_083_648)
        XCTAssertEqual(usages["disk8"]?.usedBytes, 265_008_218_112)
        XCTAssertEqual(usages["disk6"]?.usedBytes, 263_735_578_624)
    }

    func testStorageUsagePlainFilesystem() {
        let hierarchy: [[String: Any]] = [
            [
                "DeviceIdentifier": "disk12",
                "Size": 2_000_000_000_000,
                "Partitions": [
                    ["DeviceIdentifier": "disk12s1", "Size": 1_999_000_000_000, "Content": "Microsoft Basic Data"]
                ]
            ]
        ]
        let mounts = [
            MountedVolumeSample(device: "/dev/disk12s1", totalBytes: 1_999_000_000_000, usedBytes: 500_000_000_000),
            MountedVolumeSample(device: "/dev/disk12s1", totalBytes: 1_999_000_000_000, usedBytes: 500_000_000_000)
        ]

        let usages = StorageUsageProbe.usages(allDisksAndPartitions: hierarchy, mounts: mounts)
        XCTAssertEqual(usages["disk12"]?.usedBytes, 500_000_000_000)
        XCTAssertEqual(usages["disk12"]?.totalBytes, 1_999_000_000_000)
    }

    func testStorageUsageFormattingAndRebasing() {
        let usage = StorageUsage(totalBytes: 1_000, usedBytes: 250)
        XCTAssertEqual(usage.percentUsed ?? 0, 25, accuracy: 0.001)
        XCTAssertEqual(usage.percentText, "25 %")
        XCTAssertTrue(usage.summaryText.hasPrefix("Belegt: "))
        XCTAssertTrue(usage.summaryText.hasSuffix("(25 %)"))

        let rebased = usage.rebased(toTotal: 5_000)
        XCTAssertEqual(rebased.usedBytes, 250)
        XCTAssertEqual(rebased.totalBytes, 5_000)
        XCTAssertEqual(rebased.percentText, "5 %")

        let combined = StorageUsage.combined([usage, StorageUsage(totalBytes: 3_000, usedBytes: 750)])
        XCTAssertEqual(combined?.totalBytes, 4_000)
        XCTAssertEqual(combined?.usedBytes, 1_000)
        XCTAssertEqual(combined?.percentText, "25 %")

        // Clamp used to total and ignore empty file systems.
        XCTAssertEqual(StorageUsage(totalBytes: 100, usedBytes: 200).usedBytes, 100)
        XCTAssertNil(StorageUsage.combined([StorageUsage(totalBytes: 0, usedBytes: 0)]))
    }

    func testWholeDiskIdentifier() {
        XCTAssertEqual(StorageUsageProbe.wholeDiskIdentifier(for: "disk0s2"), "disk0")
        XCTAssertEqual(StorageUsageProbe.wholeDiskIdentifier(for: "disk12s1s1"), "disk12")
        XCTAssertEqual(StorageUsageProbe.wholeDiskIdentifier(for: "disk8"), "disk8")
        XCTAssertEqual(StorageUsageProbe.wholeDiskIdentifier(for: "disk0"), "disk0")
    }
}

private func merge(_ lhs: [String: Any], _ rhs: [String: Any]) -> [String: Any] {
    lhs.merging(rhs) { _, new in new }
}

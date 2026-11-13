import Foundation
import Combine

@MainActor
public final class AppState: ObservableObject {
    @Published public private(set) var settings: AppSettings
    @Published public private(set) var snapshot: MonitorSnapshot?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var loginItemEnabled: Bool
    @Published public private(set) var loginItemStatusText: String
    @Published public private(set) var loginItemError: String?
    @Published public private(set) var smartctlVersion: String?
    /// Whether the menu bar icon is currently visible on screen (macOS 26+ may hide it).
    @Published public private(set) var menuBarItemVisible = true

    public let selfTests: SelfTestService

    /// The menu bar controller subscribes here to update its icon.
    public var onSnapshot: ((MonitorSnapshot) -> Void)? {
        didSet {
            if let snapshot { onSnapshot?(snapshot) }
        }
    }

    private let store: SettingsStore
    private let monitor: MonitorService
    private let simulation: SimulationMode?

    public init(
        store: SettingsStore = .shared,
        simulation: SimulationMode? = SimulationMode(arguments: ProcessInfo.processInfo.arguments)
    ) {
        self.store = store
        self.settings = store.load()
        self.simulation = simulation
        self.monitor = MonitorService()
        self.selfTests = SelfTestService()
        self.loginItemEnabled = LoginItem.isEnabled
        self.loginItemStatusText = LoginItem.statusText

        self.monitor.onSnapshot = { [weak self] snapshot in
            self?.handle(snapshot)
        }
        self.monitor.onScanStarted = { [weak self] in
            self?.isRefreshing = true
        }
        self.selfTests.onFinished = { [weak self] key, message in
            guard let self else { return }
            let name = self.snapshot?.drives.first(where: { $0.id == key })?.drive.displayName ?? "Laufwerk"
            Notifier.shared.post(
                title: "SMART-Selbsttest beendet",
                body: "\(name): \(message)",
                identifier: "selftest-\(key)"
            )
        }

        detectSmartctl()
    }

    // MARK: Lifecycle

    public func start() {
        monitor.start(settings: settings)
    }

    public func refresh() {
        monitor.refreshNow()
    }

    public func setMenuBarItemVisible(_ visible: Bool) {
        guard menuBarItemVisible != visible else { return }
        menuBarItemVisible = visible
    }

    public var simulationMode: SimulationMode? { simulation }

    // MARK: Snapshot handling

    private func handle(_ incoming: MonitorSnapshot) {
        var snapshot = incoming
        isRefreshing = false
        smartctlVersion = snapshot.smartctlVersion

        let hasConnectedDevices = snapshot.drives.contains(where: \.isConnected)
            || snapshot.raids.contains(where: \.isConnected)

        if !settings.defaultSelectionApplied && hasConnectedDevices {
            var updated = settings
            updated.selectedDrives = snapshot.drives.filter(\.isConnected).map { StoredDrive(drive: $0.drive) }
            updated.selectedRaids = snapshot.raids.filter(\.isConnected).map { StoredRaid(raid: $0.raid) }
            updated.defaultSelectionApplied = true
            settings = updated
            store.save(updated)
            monitor.update(settings: updated)
        } else if settings.defaultSelectionApplied {
            reconcileStoredMetadata(with: snapshot)
        }

        snapshot.applySelection(from: settings)
        if let simulation {
            snapshot = StatusCollector.apply(simulation: simulation, to: snapshot)
        }
        snapshot.recalculateOverall()

        let previous = self.snapshot
        notifyTransitions(from: previous, to: snapshot)

        self.snapshot = snapshot
        onSnapshot?(snapshot)
    }

    private func reconcileStoredMetadata(with snapshot: MonitorSnapshot) {
        var updated = settings
        var changed = false

        for index in updated.selectedDrives.indices {
            let stored = updated.selectedDrives[index]
            guard let status = snapshot.drives.first(where: { status in
                guard status.isConnected else { return false }
                if status.drive.id == stored.id { return true }
                if let serial = stored.serial, !serial.isEmpty, status.drive.serial == serial { return true }
                return false
            }) else { continue }

            var entry = stored
            entry.name = status.drive.displayName
            entry.model = status.drive.model
            entry.sizeBytes = status.drive.sizeBytes
            entry.serial = status.drive.serial
            if entry != stored {
                updated.selectedDrives[index] = entry
                changed = true
            }
        }

        for index in updated.selectedRaids.indices {
            let stored = updated.selectedRaids[index]
            guard let status = snapshot.raids.first(where: { $0.isConnected && $0.raid.id == stored.id }) else { continue }
            var entry = stored
            entry.name = status.raid.displayName
            entry.level = status.raid.level
            entry.sizeBytes = status.raid.sizeBytes
            if entry != stored {
                updated.selectedRaids[index] = entry
                changed = true
            }
        }

        if changed {
            settings = updated
            store.save(updated)
        }
    }

    // MARK: Settings mutation

    private func mutateSettings(_ block: (inout AppSettings) -> Void, rescan: Bool = false) {
        var updated = settings
        block(&updated)
        guard updated != settings else { return }

        settings = updated
        store.save(updated)
        monitor.update(settings: updated)

        if var current = snapshot {
            current.applySelection(from: updated)
            current.recalculateOverall()
            snapshot = current
            onSnapshot?(current)
        }

        if rescan {
            refresh()
        }
    }

    public func setInterval(_ seconds: Double) {
        mutateSettings { $0.intervalSeconds = seconds }
    }

    public func setNotifyOnChange(_ enabled: Bool) {
        mutateSettings { $0.notifyOnChange = enabled }
    }

    public func setThresholds(_ thresholds: HealthThresholds) {
        mutateSettings { $0.thresholds = thresholds }
        refresh()
    }

    public func setUseSmartctl(_ enabled: Bool) {
        mutateSettings { $0.useSmartctl = enabled }
        refresh()
    }

    public func setSmartctlPathOverride(_ path: String?) {
        mutateSettings { $0.smartctlPathOverride = path }
        detectSmartctl()
        refresh()
    }

    public func setDriveMonitored(_ drive: DriveInfo, monitored: Bool) {
        mutateSettings { settings in
            settings.selectedDrives.removeAll { entry in
                if entry.id == drive.id { return true }
                if let serial = entry.serial, !serial.isEmpty, entry.serial == drive.serial { return true }
                return false
            }
            if monitored {
                settings.selectedDrives.append(StoredDrive(drive: drive))
            }
        }
    }

    public func setRaidMonitored(_ raid: RaidSetInfo, monitored: Bool) {
        mutateSettings { settings in
            settings.selectedRaids.removeAll { $0.id == raid.id }
            if monitored {
                settings.selectedRaids.append(StoredRaid(raid: raid))
            }
        }
    }

    public func setAllDrivesMonitored(_ monitored: Bool) {
        let connected = snapshot?.drives.filter(\.isConnected).map(\.drive) ?? []
        mutateSettings { settings in
            if monitored {
                for drive in connected where !settings.selectedDrives.contains(where: { $0.id == drive.id }) {
                    settings.selectedDrives.append(StoredDrive(drive: drive))
                }
            } else {
                settings.selectedDrives.removeAll()
            }
        }
    }

    public func setAllRaidsMonitored(_ monitored: Bool) {
        let connected = snapshot?.raids.filter(\.isConnected).map(\.raid) ?? []
        mutateSettings { settings in
            if monitored {
                for raid in connected where !settings.selectedRaids.contains(where: { $0.id == raid.id }) {
                    settings.selectedRaids.append(StoredRaid(raid: raid))
                }
            } else {
                settings.selectedRaids.removeAll()
            }
        }
    }

    public func isMonitored(_ drive: DriveInfo) -> Bool {
        settings.selectedDrives.contains { entry in
            if entry.id == drive.id { return true }
            if let serial = entry.serial, !serial.isEmpty, entry.serial == drive.serial { return true }
            return false
        }
    }

    public func isMonitored(_ raid: RaidSetInfo) -> Bool {
        settings.selectedRaids.contains { $0.id == raid.id }
    }

    // MARK: Login item

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled: enabled)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        loginItemEnabled = LoginItem.isEnabled
        loginItemStatusText = LoginItem.statusText
    }

    public func refreshLoginItemState() {
        loginItemEnabled = LoginItem.isEnabled
        loginItemStatusText = LoginItem.statusText
    }

    // MARK: SMART

    public var effectiveSmartctlPath: String? {
        SmartctlLocator.locate(override: settings.smartctlPathOverride)
    }

    public func detectSmartctl() {
        if let path = effectiveSmartctlPath {
            if smartctlVersion == nil {
                smartctlVersion = SmartctlLocator.version(at: path)
            }
        } else {
            smartctlVersion = nil
        }
    }

    public func startSelfTest(for status: DriveStatus) {
        guard status.isConnected, let path = effectiveSmartctlPath else { return }
        selfTests.start(bsdName: status.drive.bsdName, smartctlPath: path, key: status.id)
    }

    public func startSelfTestWithAdministrator(for status: DriveStatus) {
        guard status.isConnected, let path = effectiveSmartctlPath else { return }
        selfTests.startWithAdministrator(bsdName: status.drive.bsdName, smartctlPath: path, key: status.id)
    }

    // MARK: Notifications

    private func problemKeys(in snapshot: MonitorSnapshot) -> Set<String> {
        var keys = Set<String>()
        for status in snapshot.drives where status.isMonitored && status.health == .problem {
            keys.insert("drive:\(status.id)")
        }
        for status in snapshot.raids where status.isMonitored && status.health == .problem {
            keys.insert("raid:\(status.id)")
        }
        return keys
    }

    private func notifyTransitions(from previous: MonitorSnapshot?, to current: MonitorSnapshot) {
        guard settings.notifyOnChange, let previous else { return }

        let oldKeys = problemKeys(in: previous)
        let newKeys = problemKeys(in: current)
        let added = newKeys.subtracting(oldKeys)
        let resolved = oldKeys.subtracting(newKeys)

        for key in added {
            let text = description(for: key, in: current)
            Notifier.shared.post(
                title: "Laufwerksproblem erkannt",
                body: text,
                identifier: "problem-\(key)-\(Int(Date().timeIntervalSince1970))"
            )
        }
        for key in resolved {
            let text = description(for: key, in: previous)
            Notifier.shared.post(
                title: "Laufwerksproblem behoben",
                body: text,
                identifier: "resolved-\(key)-\(Int(Date().timeIntervalSince1970))"
            )
        }
    }

    private func description(for key: String, in snapshot: MonitorSnapshot) -> String {
        let parts = key.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return key }
        let kind = String(parts[0])
        let identifier = String(parts[1])
        if kind == "drive", let status = snapshot.drives.first(where: { $0.id == identifier }) {
            return "\(status.drive.displayName): \(status.reasons.joined(separator: " · "))"
        }
        if kind == "raid", let status = snapshot.raids.first(where: { $0.id == identifier }) {
            return "\(status.raid.displayName): \(status.reasons.joined(separator: " · "))"
        }
        return key
    }
}

extension MonitorSnapshot {
    public mutating func applySelection(from settings: AppSettings) {
        let available = drives.map(\.drive)
        let matched = SelectionMatcher.matchedDriveIDs(settings.selectedDrives, available: available)
        for index in drives.indices {
            drives[index].isMonitored = matched.contains(drives[index].drive.id)
        }
        for index in raids.indices {
            raids[index].isMonitored = settings.selectedRaidKeys.contains(raids[index].raid.id)
        }
        recalculateOverall()
    }
}

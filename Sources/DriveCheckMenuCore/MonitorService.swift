import Foundation
import Combine

@MainActor
public final class MonitorService {
    public var onSnapshot: ((MonitorSnapshot) -> Void)?
    public var onScanStarted: (() -> Void)?

    public private(set) var isScanning = false

    private var settings = AppSettings()
    private var timer: Timer?

    public init() {}

    public func start(settings: AppSettings) {
        self.settings = settings
        scheduleTimer()
        refreshNow()
    }

    public func update(settings: AppSettings) {
        let intervalChanged = abs(settings.intervalSeconds - self.settings.intervalSeconds) > 0.5
        let smartctlChanged = settings.useSmartctl != self.settings.useSmartctl
            || settings.smartctlPathOverride != self.settings.smartctlPathOverride
        self.settings = settings
        if intervalChanged {
            scheduleTimer()
        }
        if intervalChanged || smartctlChanged {
            refreshNow()
        }
    }

    public func refreshNow() {
        performScan()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = max(30, settings.intervalSeconds)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performScan()
            }
        }
        timer.tolerance = min(30, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func performScan() {
        guard !isScanning else { return }
        isScanning = true
        onScanStarted?()

        let settings = self.settings

        Task.detached(priority: .utility) {
            let snapshot = StatusCollector.collect(settings: settings)
            await MainActor.run {
                self.isScanning = false
                self.onSnapshot?(snapshot)
            }
        }
    }
}

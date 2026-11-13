import Foundation
import Combine

@MainActor
public final class SelfTestService: ObservableObject {
    public struct TestState: Equatable, Sendable {
        public var running: Bool
        public var message: String
        public var percentRemaining: Double?
        public var startedAt: Date
        public var finished: Bool
        public var requiresAdmin: Bool
        public var hasSeenRunning: Bool
    }

    @Published public private(set) var states: [String: TestState] = [:]

    /// Called with (drive key, final message) when a self-test completes.
    public var onFinished: ((String, String) -> Void)?

    private var pollTasks: [String: Task<Void, Never>] = [:]

    public init() {}

    public func state(forKey key: String) -> TestState? {
        states[key]
    }

    public func isRunning(forKey key: String) -> Bool {
        states[key]?.running == true
    }

    // MARK: Start

    public func start(bsdName: String, smartctlPath: String, key: String) {
        guard validate(bsdName: bsdName) else {
            states[key] = TestState(
                running: false,
                message: "Ungültiges Gerät",
                startedAt: Date(),
                finished: true,
                requiresAdmin: false,
                hasSeenRunning: false
            )
            return
        }

        states[key] = TestState(
            running: false,
            message: "Selbsttest wird gestartet …",
            startedAt: Date(),
            finished: false,
            requiresAdmin: false,
            hasSeenRunning: false
        )

        Task.detached(priority: .userInitiated) {
            let result = Shell.run(smartctlPath, ["-t", "short", bsdName], timeout: 30)
            await MainActor.run {
                self.handleStartResult(result, bsdName: bsdName, smartctlPath: smartctlPath, key: key)
            }
        }
    }

    public func startWithAdministrator(bsdName: String, smartctlPath: String, key: String) {
        guard validate(bsdName: bsdName), validate(path: smartctlPath) else {
            states[key] = TestState(
                running: false,
                message: "Ungültiger Befehl",
                startedAt: Date(),
                finished: true,
                requiresAdmin: false,
                hasSeenRunning: false
            )
            return
        }

        states[key] = TestState(
            running: false,
            message: "Selbsttest wird mit Administratorrechten gestartet …",
            startedAt: Date(),
            finished: false,
            requiresAdmin: false,
            hasSeenRunning: false
        )

        let command = "\(smartctlPath) -t short \(bsdName)"
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        Task.detached(priority: .userInitiated) {
            let result = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 120)
            await MainActor.run {
                if result.status != 0 {
                    let combined = result.combinedOutput.lowercased()
                    let canceled = combined.contains("-128") || combined.contains("user canceled") || combined.contains("abbruch")
                    self.states[key] = TestState(
                        running: false,
                        message: canceled ? "Abgebrochen" : self.errorMessage(from: result),
                        startedAt: Date(),
                        finished: true,
                        requiresAdmin: false,
                        hasSeenRunning: false
                    )
                    return
                }
                self.markStarted(bsdName: bsdName, smartctlPath: smartctlPath, key: key)
            }
        }
    }

    private func handleStartResult(_ result: Shell.Result, bsdName: String, smartctlPath: String, key: String) {
        if result.status == 0 {
            markStarted(bsdName: bsdName, smartctlPath: smartctlPath, key: key)
            return
        }

        let combined = result.combinedOutput
        let lower = combined.lowercased()
        let requiresAdmin = lower.contains("permission denied")
            || lower.contains("operation not permitted")
            || lower.contains("must be root")
            || lower.contains("requires root")

        states[key] = TestState(
            running: false,
            message: requiresAdmin
                ? "Administratorrechte erforderlich"
                : errorMessage(from: result),
            startedAt: Date(),
            finished: !requiresAdmin,
            requiresAdmin: requiresAdmin,
            hasSeenRunning: false
        )
    }

    private func markStarted(bsdName: String, smartctlPath: String, key: String) {
        states[key] = TestState(
            running: true,
            message: "Selbsttest läuft …",
            startedAt: Date(),
            finished: false,
            requiresAdmin: false,
            hasSeenRunning: false
        )
        beginPolling(key: key, bsdName: bsdName, smartctlPath: smartctlPath)
    }

    // MARK: Polling

    private func beginPolling(key: String, bsdName: String, smartctlPath: String) {
        pollTasks[key]?.cancel()
        pollTasks[key] = Task { [weak self] in
            var attempts = 0
            while !Task.isCancelled, attempts < 180 {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { return }

                let result = await Task.detached(priority: .utility) {
                    Shell.run(smartctlPath, ["-l", "selftest", "-j", bsdName], timeout: 20)
                }.value

                guard let self else { return }
                guard let status = SelfTestParser.parse(output: result.stdout) else {
                    attempts += 1
                    continue
                }

                guard var state = self.states[key] else { return }
                if status.running {
                    state.hasSeenRunning = true
                    state.running = true
                    state.finished = false
                    state.message = status.message.isEmpty ? "Selbsttest läuft …" : status.message
                    state.percentRemaining = status.percentRemaining
                    self.states[key] = state
                } else if status.finished {
                    if !state.hasSeenRunning && attempts < 3 {
                        attempts += 1
                        continue
                    }
                    state.running = false
                    state.finished = true
                    state.message = status.message.isEmpty ? "Selbsttest beendet" : status.message
                    state.percentRemaining = nil
                    self.states[key] = state
                    self.pollTasks[key] = nil
                    self.onFinished?(key, state.message)
                    return
                }
                attempts += 1
            }

            guard let self else { return }
            if var state = self.states[key], state.running {
                state.running = false
                state.finished = true
                state.message = "Zeitüberschreitung bei der Fortschrittsabfrage"
                self.states[key] = state
            }
            self.pollTasks[key] = nil
        }
    }

    // MARK: Helpers

    public func clearState(forKey key: String) {
        pollTasks[key]?.cancel()
        pollTasks[key] = nil
        states.removeValue(forKey: key)
    }

    private func errorMessage(from result: Shell.Result) -> String {
        let output = result.combinedOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("{") && !$0.hasPrefix("\"") }
            .first
        if let output { return output }
        return "Selbsttest konnte nicht gestartet werden (Code \(result.status))"
    }

    private func validate(bsdName: String) -> Bool {
        bsdName.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil
    }

    private func validate(path: String) -> Bool {
        path.range(of: #"^[A-Za-z0-9/._+-]+$"#, options: .regularExpression) != nil
    }
}

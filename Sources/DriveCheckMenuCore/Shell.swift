import Foundation

public enum Shell {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool

        public var combinedOutput: String {
            [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    /// Runs a command line tool and captures stdout/stderr. Never blocks longer than `timeout` seconds.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 20
    ) -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return Result(status: 127, stdout: "", stderr: "Nicht ausführbar: \(executable)", timedOut: false)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        do {
            try process.run()
        } catch {
            return Result(status: 126, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }

        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            usleep(200_000)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        _ = group.wait(timeout: .now() + 3)
        process.waitUntilExit()

        let stdout = String(data: stdoutBox.data, encoding: .utf8) ?? ""
        let stderr = String(data: stderrBox.data, encoding: .utf8) ?? ""

        return Result(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    /// GUI apps do not inherit a login shell PATH. Provide a sane PATH for helper tools.
    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let defaults = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = defaults + ":" + existing
        } else {
            env["PATH"] = defaults
        }
        env["LC_ALL"] = "C"
        env["LANG"] = "en_US.UTF-8"
        return env
    }
}

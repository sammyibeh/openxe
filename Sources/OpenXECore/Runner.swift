import Foundation

public enum LaunchOutcome: Sendable {
    case launched
    case refused(PEVerdict)
    case crashed(exitCode: Int32, logTail: String)
}

/// Launches Windows programs; owns the subprocess environment and the
/// wineserver lifecycle. Spec §4.3. Wine is spawned unmodified, subprocess only.
public final class Runner: Sendable {
    /// Seconds after which a still-running program counts as launched (spec §4.3).
    public static let launchWatchSeconds: TimeInterval = 15

    private let paths: OpenXEPaths
    private let engine: EngineManager

    public init(paths: OpenXEPaths) {
        self.paths = paths
        self.engine = EngineManager(paths: paths)
    }

    private var environment: [String: String] {
        WineEnvironment.build(engineCurrent: paths.engineCurrent, prefix: paths.prefix)
    }

    // MARK: wineserver lifecycle

    /// Start a persistent wineserver for the prefix if none is running.
    /// `wineserver -p` daemonizes and outlives individual programs, making
    /// repeat launches near-instant.
    public func ensureWineserverWarm() {
        _ = try? Subprocess.run(engine.activeWineserverBinary, arguments: ["-p"],
                                environment: environment, timeout: 60,
                                captureOutput: false)
    }

    /// Settings action: "Shut Down Windows Environment".
    public func shutdownWineserver() {
        _ = try? Subprocess.run(engine.activeWineserverBinary, arguments: ["-k"],
                                environment: environment, timeout: 30,
                                captureOutput: false)
    }

    // MARK: launching

    /// Gate on the PE header, then spawn under a warm wineserver and watch
    /// for an early crash. Returns after at most `launchWatchSeconds`.
    public func launch(exe: URL) throws -> LaunchOutcome {
        let verdict = try PEParser.classify(fileAt: exe)
        guard verdict.isLaunchable else { return .refused(verdict) }

        ensureWineserverWarm()
        let log = try openLog(sessionNote: exe.lastPathComponent)
        defer { try? log.close() }

        let process = Process()
        process.executableURL = engine.activeWineBinary
        process.arguments = [exe.path]
        process.environment = environment
        process.currentDirectoryURL = exe.deletingLastPathComponent()
        process.standardOutput = log
        process.standardError = log

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        if exited.wait(timeout: .now() + Self.launchWatchSeconds) == .success,
           process.terminationStatus != 0 {
            return .crashed(exitCode: process.terminationStatus, logTail: logTail())
        }
        // Still running after the watch window (or exited cleanly): launched.
        return .launched
    }

    /// Run a Windows program via wine and capture its combined output.
    /// Used by the end-to-end test (`cmd /c echo …`) and prefix tooling.
    public func runCapturingOutput(arguments: [String], timeout: TimeInterval) throws -> String {
        ensureWineserverWarm()
        let result = try Subprocess.run(engine.activeWineBinary, arguments: arguments,
                                        environment: environment, timeout: timeout)
        return result.output
    }

    // MARK: log

    /// Last `lines` lines of wine.log, for crash alerts (spec §6).
    public func logTail(lines: Int = 40) -> String {
        guard let text = try? String(contentsOf: paths.wineLog, encoding: .utf8) else {
            return "(no log available)"
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lines).joined(separator: "\n")
    }

    public var logURL: URL { paths.wineLog }

    private func openLog(sessionNote: String) throws -> FileHandle {
        let fm = FileManager.default
        let url = paths.wineLog
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let stamp = ISO8601DateFormatter().string(from: Date())
        try handle.write(contentsOf: Data("\n===== \(stamp) \(sessionNote) =====\n".utf8))
        return handle
    }
}

/// Rosetta 2 gate for the x86_64 engine on Apple Silicon. Spec §5 step 2, §6.
public enum RosettaCheck {
    /// True on Apple Silicon (where the x86_64 engine needs Rosetta).
    public static var isNeeded: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let ok = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return ok == 0 && value == 1
    }

    /// True when x86_64 binaries can run (native Intel, or Rosetta installed).
    public static var canRunX86_64: Bool {
        guard isNeeded else { return true }
        let result = try? Subprocess.run(URL(fileURLWithPath: "/usr/bin/arch"),
                                         arguments: ["-x86_64", "/usr/bin/true"],
                                         timeout: 10)
        return result?.status == 0
    }

    /// Runs Apple's Rosetta installer; returns its combined output and status.
    public static func install() -> (status: Int32, output: String) {
        let result = try? Subprocess.run(
            URL(fileURLWithPath: "/usr/sbin/softwareupdate"),
            arguments: ["--install-rosetta", "--agree-to-license"],
            timeout: 600)
        return (result?.status ?? -1, result?.output ?? "softwareupdate could not be run")
    }
}

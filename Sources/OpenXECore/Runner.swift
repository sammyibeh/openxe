import Foundation
import CryptoKit

public enum LaunchOutcome: Sendable {
    /// The program launched; `pid` is the wine process, for window activation.
    case launched(pid: Int32)
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
    private let appConfigs: AppConfigStore

    public init(paths: OpenXEPaths) {
        self.paths = paths
        self.engine = EngineManager(paths: paths)
        self.appConfigs = AppConfigStore(paths: paths)
    }

    private var environment: [String: String] {
        WineEnvironment.build(engineCurrent: paths.engineCurrent, prefix: paths.prefix)
    }

    // MARK: wineserver lifecycle

    /// How long the warm wineserver lingers after its last client exits, in
    /// seconds (passed as `wineserver -p<n>`). While NWS runs it holds a client,
    /// so this timeout only applies once every program has quit. 300s keeps
    /// repeat launches near-instant across a quit-and-reopen or a crash-relaunch,
    /// while self-terminating three orders of magnitude below the multi-day
    /// window in which macOS reaps the server's `/tmp` socket — so the orphaned,
    /// unreachable server that triggers "Can't check in server_mach_port" can
    /// never form (diagnosed 2026-07-20).
    static let warmServerIdleSeconds = 300

    /// Identity of the running OpenXE build, for the one-time upgrade reap. The
    /// app's Info.plist version isn't bumped per release, so we key off the
    /// executable itself (name + size + mtime): a new install replaces the
    /// binary and changes this, which is exactly "first launch of a new build".
    /// Public because `setup.log`'s run header identifies the build the same way
    /// (spec §4.4).
    public static var currentBuildID: String {
        guard let exe = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path)
        else { return "unknown" }
        let size = (attrs[.size] as? Int) ?? 0
        let mtime = (attrs[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970) } ?? 0
        return "\(exe.lastPathComponent)-\(size)-\(mtime)"
    }

    /// Marker recording the build that last warmed a server (for the upgrade reap).
    private var buildMarker: URL { paths.root.appendingPathComponent(".warm-server-build") }

    /// Start a persistent-but-idle-bounded wineserver for the prefix if none is
    /// running. `wineserver -p<n>` daemonizes and outlives individual programs,
    /// making repeat launches near-instant. Two guards run first so this launch
    /// can never collide on the Mach bootstrap name: on the first launch of a new
    /// build, reap any wineserver left by the previous build; then sweep an
    /// unreachable/orphaned server for this prefix (including one holding an
    /// already-unlinked server dir, found by its open WINEPREFIX handle).
    public func ensureWineserverWarm() {
        WineServerHousekeeping.upgradeReapIfNeeded(forPrefix: paths.prefix,
                                                   buildID: Self.currentBuildID,
                                                   markerURL: buildMarker)
        WineServerHousekeeping.sweepStaleServer(forPrefix: paths.prefix)
        _ = try? Subprocess.run(engine.activeWineserverBinary,
                                arguments: ["-p\(Self.warmServerIdleSeconds)"],
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

        // Per-app "bottle-lean" config (spec §4.6): apply the app's Windows
        // version (Wine AppDefaults registry key) and carry its DLL overrides /
        // env into the launch environment. Best-effort — a config problem must
        // never block a launch.
        let config = appConfigs.config(for: exe)
        applyWindowsVersion(config, exe: exe)

        let log = try openLog(sessionNote: exe.lastPathComponent)
        defer { try? log.close() }

        // Launch through a per-exe icon-wrapper .app when one can be built, so
        // the program shows its own icon and name in the Dock (spec §9.5). Fall
        // back to the plain wine binary — the wrapper is never a launch blocker.
        var env = WineEnvironment.buildLaunch(engineCurrent: paths.engineCurrent,
                                              prefix: paths.prefix, config: config)
        let executable: URL
        if let loader = iconWrapperLoader(for: exe) {
            executable = loader
            env["WINELOADER"] = loader.path
        } else {
            executable = engine.activeWineBinary
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = [exe.path]
        process.environment = env
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
        return .launched(pid: process.processIdentifier)
    }

    /// Applies the app's per-app Windows version by writing Wine's native
    /// per-application key `HKCU\Software\Wine\AppDefaults\<exe>\Version` (the
    /// same mechanism winecfg's Applications tab uses). Wine reads it per-process
    /// keyed by the running exe's file name, so this delivers a CrossOver-style
    /// per-app Windows version inside the single shared prefix (spec §4.6).
    /// Best-effort and idempotent; when the config is Default the key is removed
    /// so the app falls back to the prefix-global version.
    private func applyWindowsVersion(_ config: AppConfig?, exe: URL) {
        let appKey = #"HKCU\Software\Wine\AppDefaults\"# + exe.lastPathComponent
        let env = environment
        if let value = config?.windowsVersion.wineValue {
            _ = try? Subprocess.run(engine.activeWineBinary,
                                    arguments: ["reg", "add", appKey, "/v", "Version",
                                                "/t", "REG_SZ", "/d", value, "/f"],
                                    environment: env, timeout: 60, captureOutput: false)
        } else {
            // No per-app version requested: clear any stale key we wrote before.
            _ = try? Subprocess.run(engine.activeWineBinary,
                                    arguments: ["reg", "delete", appKey, "/v", "Version", "/f"],
                                    environment: env, timeout: 60, captureOutput: false)
        }
    }

    /// Run a Windows program via wine and capture its combined output.
    /// Used by the end-to-end test (`cmd /c echo …`) and prefix tooling.
    public func runCapturingOutput(arguments: [String], timeout: TimeInterval) throws -> String {
        ensureWineserverWarm()
        let result = try Subprocess.run(engine.activeWineBinary, arguments: arguments,
                                        environment: environment, timeout: timeout)
        return result.output
    }

    // MARK: Dock identity (spec §9.5)

    /// Builds (and caches) a per-exe `.app` whose CFBundleExecutable is a symlink
    /// to the engine's unix wine loader, with the exe's own icon and product name.
    /// Launching the program through this bundle gives it a real Dock tile —
    /// its icon and "New World Scheduler"-style name instead of a generic Wine
    /// icon. Returns the loader path to exec, or nil if the wrapper can't be
    /// built (the caller then uses the plain wine binary). Best-effort — the
    /// Dock icon must never block or fail a launch.
    ///
    /// The loader is a *symlink* through `engine/current`, so the wrapper follows
    /// engine swaps for free; a stale wrapper (pointing at a previous engine) is
    /// rebuilt. Verified 2026-07-07: NWS presents its own icon and name.
    ///
    /// The wrapper's `CFBundleExecutable` (the loader file) is named after the
    /// program — *not* `wine` — because the Dock/menu-bar identity of a
    /// wine-exec'd process falls back to the executable's file name
    /// (`argv[0]` / `NSProcessInfo.processName`) on any surface that can't read
    /// the bundle. Naming it `wine` is exactly what put "wine" in the Dock;
    /// naming it after the app closes that gap while `CFBundleName` drives the
    /// primary label.
    private func iconWrapperLoader(for exe: URL) -> URL? {
        let fm = FileManager.default
        let loaderTarget = paths.unixWineLoader
        guard fm.fileExists(atPath: loaderTarget.path) else { return nil }

        let digest = String(SHA256.hash(data: Data(exe.path.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(12))

        // Human-readable label (Dock tile, menu bar) — the exe's PE ProductName,
        // falling back to its file-name stem.
        let displayName = PEResources.productName(fromFileAt: exe)
            ?? exe.deletingPathExtension().lastPathComponent
        // File-name-safe form for the loader / CFBundleExecutable.
        let execName = Self.sanitizedExecutableName(displayName)

        // The .app directory is *named after the program*, nested under the
        // digest: LaunchServices derives an unregistered bundle's display name
        // from its directory name (CFBundleName/CFBundleDisplayName in the
        // Info.plist do not override it), and the Dock renders that — a
        // digest-named bundle put a raw "ffee102d6c83" tile in the Dock.
        // The digest parent keeps wrappers unique per exe path.
        let bundle = paths.appBundles
            .appendingPathComponent(digest, isDirectory: true)
            .appendingPathComponent("\(execName).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let loader = macOS.appendingPathComponent(execName)

        // Reuse a cached wrapper only if its loader still points at the *current*
        // engine (an engine swap changes the target) and carries the current
        // name (a renamed exe/ProductName changes `execName`, so the old loader
        // file won't be found → rebuild).
        if (try? fm.destinationOfSymbolicLink(atPath: loader.path)) == loaderTarget.path,
           fm.fileExists(atPath: contents.appendingPathComponent("Info.plist").path) {
            return loader
        }

        do {
            try? fm.removeItem(at: bundle)
            // Drop a pre-display-name wrapper (`AppBundles/<digest>.app`) so the
            // hex-named bundle can't linger beside the fixed one.
            try? fm.removeItem(at: paths.appBundles.appendingPathComponent("\(digest).app"))
            try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: loader.path, withDestinationPath: loaderTarget.path)

            var hasIcon = false
            let iconURL = resources.appendingPathComponent("exeIcon.icns")
            if let ico = PEResources.extractPrimaryIconICO(fromFileAt: exe),
               IconBuilder.makeICNS(fromICO: ico, output: iconURL) {
                hasIcon = true
            }

            var plist: [String: Any] = [
                "CFBundleName": displayName,
                "CFBundleDisplayName": displayName,
                "CFBundleIdentifier": "dev.openxe.app.\(digest)",
                "CFBundleExecutable": execName,
                "CFBundlePackageType": "APPL",
                "CFBundleInfoDictionaryVersion": "6.0",
            ]
            if hasIcon { plist["CFBundleIconFile"] = "exeIcon" }
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return loader
        } catch {
            return nil
        }
    }

    /// A file-name-safe form of the program name for the wrapper's
    /// `CFBundleExecutable`. Spaces are kept (macOS allows them and they render
    /// correctly in the Dock/menu bar); path separators (`/`, `:`) and control
    /// characters become spaces; runs of whitespace collapse; the result is
    /// trimmed, length-capped, and never empty (so it is never accidentally
    /// `wine` — the value falls back only to `app`).
    static func sanitizedExecutableName(_ name: String) -> String {
        var chars = String.UnicodeScalarView()
        for s in name.unicodeScalars {
            if s == "/" || s == ":" || s.value < 0x20 {
                chars.append(" ")
            } else {
                chars.append(s)
            }
        }
        var out = String(chars).trimmingCharacters(in: .whitespaces)
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        if out.count > 60 {
            out = String(out.prefix(60)).trimmingCharacters(in: .whitespaces)
        }
        return out.isEmpty ? "app" : out
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
///
/// OpenXE ships universal and runs on both kinds of Mac. Only Apple silicon
/// needs Rosetta; an Intel Mac runs the x86_64 engine natively and must never
/// be told anything about Rosetta at all.
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
        canRunX86_64(isAppleSilicon: isNeeded, probe: probeTranslation)
    }

    /// Architecture is a parameter so the Intel path is testable on an Apple
    /// silicon machine (and vice versa) — it is otherwise unreachable, and
    /// unreachable behaviour regresses silently.
    static func canRunX86_64(isAppleSilicon: Bool, probe: () -> Bool) -> Bool {
        // Intel: native. Answer without spawning anything.
        guard isAppleSilicon else { return true }
        return probe()
    }

    /// The direct experiment: run an x86_64 binary and see.
    static func probeTranslation() -> Bool {
        let result = try? Subprocess.run(URL(fileURLWithPath: "/usr/bin/arch"),
                                         arguments: ["-x86_64", "/usr/bin/true"],
                                         timeout: 10)
        return result?.status == 0
    }

    /// Runs Apple's Rosetta installer; returns its combined output and status.
    ///
    /// `softwareupdate` authorizes through the Security framework and can refuse
    /// outright — its own strings include "Require authorization from admin but
    /// user is not admin" and "Error: failed to authorize for installation."
    /// Whether it raises an interactive panel when spawned from a GUI app is not
    /// something we can rely on, so this is the *cheap* attempt and
    /// `installWithAdministratorAuthorization()` is the fallback that is
    /// guaranteed to ask.
    public static func install() -> (status: Int32, output: String) {
        guard !isRunningUnderTest else { return refusedUnderTest }
        let result = try? Subprocess.run(
            URL(fileURLWithPath: "/usr/sbin/softwareupdate"),
            arguments: ["--install-rosetta", "--agree-to-license"],
            timeout: 600)
        return (result?.status ?? -1, result?.output ?? "softwareupdate could not be run")
    }

    /// Same install, but explicitly authorized, so macOS puts up its familiar
    /// password panel. Used only after the direct attempt fails for a reason a
    /// password could plausibly fix — a user who cannot open Terminal has no
    /// other way past an authorization refusal.
    ///
    /// The prompt text is ours; the command never appears in it. Cancelling
    /// yields "User canceled. (-128)" and installs nothing.
    public static func installWithAdministratorAuthorization()
        -> (status: Int32, output: String) {
        guard !isRunningUnderTest else { return refusedUnderTest }
        let command = "/usr/sbin/softwareupdate --install-rosetta --agree-to-license"
        let script = "do shell script \"\(escapeForAppleScript(command))\""
            + " with prompt \"\(escapeForAppleScript(SetupCopy.rosettaAuthorizationPrompt))\""
            + " with administrator privileges"
        // Generous timeout: the panel waits on a human.
        let result = try? Subprocess.run(URL(fileURLWithPath: "/usr/bin/osascript"),
                                         arguments: ["-e", script],
                                         timeout: 900)
        return (result?.status ?? -1,
                result?.output ?? "the authorized installer could not be run")
    }

    /// A hard stop, not a convenience. These two functions modify the machine —
    /// one of them raises a password panel — and a test run must never do
    /// either. On a developer's Mac without Rosetta, an accidental call would
    /// silently install system software mid-suite; with Rosetta present it
    /// still reinstalls Apple's package as root. Injection is the primary
    /// defence (see `RosettaGate.live`); this is the backstop for when someone
    /// adds a new dependency with a live default and forgets.
    static var isRunningUnderTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || ProcessInfo.processInfo.environment["OPENXE_DISABLE_SYSTEM_INSTALLERS"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static let refusedUnderTest: (status: Int32, output: String) =
        (-1, "refused: system installers are disabled under test")

    private static func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

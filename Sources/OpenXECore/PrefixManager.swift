import Foundation

/// Stage-4 sub-progress (spec §5.1). Weights are measured, not estimated:
/// wineboot 24 s dominates; fonts are one batched import at ~1.5 s (spec §5.3).
public enum PrefixProgress: Sendable {
    public enum SubStep: String, Sendable, CaseIterable {
        case boot, drain, verify, registry, fonts, linking, marker

        public var weight: Int {
            switch self {
            case .boot:     return 82
            case .drain:    return 3
            case .verify:   return 2
            case .registry: return 6
            case .fonts:    return 5
            case .linking:  return 1
            case .marker:   return 1
            }
        }

        public var detail: String {
            switch self {
            case .boot:     return "Setting up Windows for the first time…"
            case .drain:    return "Finishing background setup…"
            case .verify:   return "Checking .NET and browser support…"
            case .registry: return "Configuring display settings…"
            case .fonts:    return "Registering fonts…"
            case .linking:  return "Linking your Documents and Downloads…"
            case .marker:   return "Finishing up…"
            }
        }

        /// Cumulative weight of every sub-step before this one.
        var offset: Int {
            var total = 0
            for s in SubStep.allCases {
                if s == self { break }
                total += s.weight
            }
            return total
        }
    }

    case step(SubStep, fraction: Double, detail: String)

    /// Files a completed `wineboot --init` leaves in the prefix (measured,
    /// spec §3.1). Denominator for 4a's coarse determinate bar.
    public static let expectedPrefixEntries = 2027

    /// 4a progress from prefix file count (spec §5.1, closes R3a). Advisory:
    /// clamped to 1.0, and the caller keeps a running maximum so the bar can
    /// never rewind. A wrong denominator yields a lazy bar, never a wrong one.
    public static func bootFraction(filesSeen: Int) -> Double {
        min(Double(filesSeen) / Double(expectedPrefixEntries), 1.0)
    }

    /// Overall 0...1 position within stage 4.
    public static func fraction(at step: SubStep, within inner: Double) -> Double {
        let clamped = min(max(inner, 0), 1)
        return (Double(step.offset) + Double(step.weight) * clamped) / 100.0
    }
}

/// Turns the stage-4 event stream into a bar position that never rewinds.
///
/// `PrefixProgress` puts that guarantee on the caller by design: the boot
/// poller's file count is advisory and sub-steps each report their own 0...1,
/// so a transient dip must not drag the bar backwards. Lives here rather than
/// in the window controller so it is covered by tests — the surface should
/// hold no logic worth testing.
public struct PrefixProgressTracker: Sendable {
    private var highWater: Double = 0

    public init() {}

    /// The position to display, or nil when this event would move the bar
    /// backwards and the caller should leave it where it is.
    public mutating func position(for update: PrefixProgress) -> Double? {
        guard case .step(let step, let inner, _) = update else { return nil }
        let overall = PrefixProgress.fraction(at: step, within: inner)
        guard overall > highWater else { return nil }
        highWater = overall
        return overall
    }

    /// The status text for an event. Always shown, even when the bar holds.
    public static func detail(for update: PrefixProgress) -> String {
        guard case .step(_, _, let detail) = update else { return "" }
        return detail
    }
}

public enum PrefixError: Error, LocalizedError {
    case bootFailed(status: Int32, detail: String)
    case monoOrGeckoMissing(String)

    public var errorDescription: String? {
        switch self {
        case .bootFailed(let status, let detail):
            return "Windows environment setup failed (wineboot exited \(status)): \(detail)"
        case .monoOrGeckoMissing(let detail):
            return "Windows environment is incomplete — \(detail). "
                + ".NET and embedded-browser support are required; the environment was not marked ready."
        }
    }
}

/// Owns the single persistent prefix — the durable memory (registry, C: drive,
/// user profile). Spec §4.2. Idempotent via a ready-marker file.
public final class PrefixManager: Sendable {
    private let paths: OpenXEPaths
    private let engine: EngineManager
    private static let readyMarker = ".openxe-ready"

    public init(paths: OpenXEPaths) {
        self.paths = paths
        self.engine = EngineManager(paths: paths)
    }

    /// The engine id recorded when the prefix was last built, if any.
    private var markerEngineID: String? {
        let marker = paths.prefix.appendingPathComponent(Self.readyMarker)
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("engine=") {
            return String(line.dropFirst("engine=".count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The prefix is ready only when it was built for the *currently active*
    /// engine. A Wine prefix is bound to its engine (Wine does not support
    /// downgrades), so switching engines invalidates it and forces a rebuild
    /// (spec §4.2, §8).
    public var isReady: Bool {
        guard let built = markerEngineID else { return false }
        return built == (engine.activeEngineID ?? "")
    }

    /// 28 substitutions x 2 registry tables + 1 FontAwesome registration.
    public static var fontWriteCount: Int { FontProvisioning.substitutions.count * 2 + 1 }

    public func ensurePrefix(log: SetupLog? = nil,
                             progress: (@Sendable (PrefixProgress) -> Void)? = nil) throws {
        guard !isReady else { return }
        // Stage 4 opens only when there is real work: an already-ready prefix
        // must not put a zero-second stage into the calibration log.
        let stage4 = log?.startStage(.preparePrefix)
        let fm = FileManager.default

        // A prefix left over from a different engine must be wiped first —
        // never reuse a mismatched prefix.
        if fm.fileExists(atPath: paths.prefix.path), markerEngineID != engine.activeEngineID {
            shutdownServer()
            try? fm.removeItem(at: paths.prefix)
        }
        try fm.createDirectory(at: paths.prefix, withIntermediateDirectories: true)
        let env = WineEnvironment.build(engineCurrent: paths.engineCurrent, prefix: paths.prefix)

        // 1. Boot. Bundled shared Mono/Gecko auto-install here (spec §4.1);
        //    allow generous time for that one-time work.
        progress?(.step(.boot, fraction: 0, detail: PrefixProgress.SubStep.boot.detail))
        log?.note("wineboot --init starting")

        // Coarse determinate bar for 4a from prefix file count (spec §5.1,
        // closes R3a). Shares the 1 Hz cadence the liveness signal needs; the
        // running maximum is what guarantees the bar never rewinds.
        let bootProgress = BootProgressPoller(prefix: paths.prefix) { fraction in
            progress?(.step(.boot, fraction: fraction,
                            detail: PrefixProgress.SubStep.boot.detail))
        }
        bootProgress.start()
        // The explicit stop below covers the success path; this defer covers a
        // throw. stop() is idempotent. Deviation from the plan sketch, which
        // relied on the defer alone and so left the poller emitting .boot
        // events during sub-steps 4b-4g — visibly rewinding the bar.
        defer { bootProgress.stop() }
        // No onLine here on purpose. It used to publish a hardcoded
        // `fraction: 0.5` on every wineboot log line — fake movement that
        // slammed 4a to its midpoint (≈41 % of stage 4) the instant Wine
        // printed anything, then fought the poller for the rest of the boot.
        // The poller is the better liveness signal anyway: if wineboot wedges,
        // the prefix file count stops climbing and the bar visibly stalls,
        // whereas fixme spam would have kept "proving" liveness. Subprocess
        // tees to logHandle independently of onLine, so nothing is lost.
        let boot = try Subprocess.run(engine.activeWineBinary,
                                      arguments: ["wineboot", "--init"],
                                      environment: env, timeout: 900,
                                      logHandle: log?.handle)
        bootProgress.stop()
        guard boot.status == 0 else {
            throw PrefixError.bootFailed(status: boot.status, detail: String(boot.output.suffix(400)))
        }
        // Wait for background services (mono/gecko installers) to finish.
        progress?(.step(.drain, fraction: 0, detail: PrefixProgress.SubStep.drain.detail))
        _ = try? Subprocess.run(engine.activeWineserverBinary, arguments: ["-w"],
                                environment: env, timeout: 900,
                                logHandle: log?.handle, captureOutput: false)

        // 2. Verify Mono + Gecko — hard requirement; fail loudly, never degrade.
        //    The bundled builds install both as *shared* (used in place from the
        //    engine's share/wine/, registered into the prefix) — so Mono is
        //    verified via its registry registration, not drive_c/windows/mono.
        progress?(.step(.verify, fraction: 0, detail: PrefixProgress.SubStep.verify.detail))
        let driveC = paths.prefix.appendingPathComponent("drive_c")
        let systemReg = (try? String(contentsOf: paths.prefix.appendingPathComponent("system.reg"),
                                     encoding: .utf8)) ?? ""
        guard systemReg.contains("Wine Mono") else {
            throw PrefixError.monoOrGeckoMissing("Wine Mono (.NET) is not registered in the prefix")
        }
        try verifyNonEmptyDirectory(driveC.appendingPathComponent("windows/system32/gecko"), name: "Wine Gecko (embedded browser)")

        // 3. Retina rendering.
        progress?(.step(.registry, fraction: 0, detail: PrefixProgress.SubStep.registry.detail))
        try registryAdd(key: #"HKCU\Software\Wine\Mac Driver"#, value: "RetinaMode",
                        type: "REG_SZ", data: "y", env: env, log: log)
        try registryAdd(key: #"HKCU\Control Panel\Desktop"#, value: "LogPixels",
                        type: "REG_DWORD", data: "192", env: env, log: log)

        // 3a. Font provisioning (spec §4.2). Best-effort — font issues must never
        //     block a launch. Generalized from the NWS-specific fix into a base
        //     applied to every prefix: install the one font macOS lacks
        //     (FontAwesome) and register broad fallback substitutions so any
        //     Windows font we cannot supply degrades to a close available face
        //     instead of NULL-derefing wine-mono's WPF text layout. See
        //     FontProvisioning for the base-fonts-from-macOS rationale.
        provisionFonts(env: env, log: log, progress: progress)

        // 3b. Software rendering default (spec §4.2, §8). OpenXE ships no GPU
        //     stack (no MoltenVK/DXVK), so WPF's hardware render tier hits the
        //     Mac GL/Vulkan path and logs GL_INVALID_FRAMEBUFFER_OPERATION /
        //     failed vulkan_init. Forcing WPF onto its software render tier
        //     (Avalon.Graphics\DisableHWAcceleration=1) keeps GPU-leaning apps on
        //     a path that actually works here. The map/3D view degrades; the main
        //     UI renders. Best-effort; a per-app override can re-enable it later.
        regBestEffort([#"HKCU\Software\Microsoft\Avalon.Graphics"#,
                       "/v", "DisableHWAcceleration", "/t", "REG_DWORD", "/d", "1", "/f"],
                      env: env, log: log)

        // 4. Link the Mac's real folders into the Windows user profile.
        //    Best-effort: folder linking must NEVER abort ensurePrefix, or the
        //    ready-marker (step 5) is never written, `isReady` stays false, and
        //    the *next* open wipes and rebuilds the prefix — destroying installed
        //    apps on every launch. The Windows profile directory name is
        //    engine-dependent (CrossOver's wineboot creates `users/crossover`,
        //    Gcenx uses the unix user name), so link into whatever real profiles
        //    wineboot created rather than assuming `NSUserName()`.
        progress?(.step(.linking, fraction: 0, detail: PrefixProgress.SubStep.linking.detail))
        let home = fm.homeDirectoryForCurrentUser
        let usersDir = driveC.appendingPathComponent("users")
        let profiles = ((try? fm.contentsOfDirectory(atPath: usersDir.path)) ?? [])
            .filter { $0 != "Public" && !$0.hasPrefix(".") }
        for profile in profiles {
            let winUser = usersDir.appendingPathComponent(profile)
            for folder in ["Documents", "Downloads", "Desktop"] {
                let winFolder = winUser.appendingPathComponent(folder)
                let target = home.appendingPathComponent(folder)
                guard fm.fileExists(atPath: target.path) else { continue }
                // Only replace what wineboot freshly created: an empty real directory.
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: winFolder.path, isDirectory: &isDir) {
                    let isSymlink = (try? fm.destinationOfSymbolicLink(atPath: winFolder.path)) != nil
                    if isSymlink { continue } // already linked
                    guard isDir.boolValue,
                          let contents = try? fm.contentsOfDirectory(atPath: winFolder.path),
                          contents.isEmpty
                    else { continue } // never delete user data
                    try? fm.removeItem(at: winFolder)
                }
                try? fm.createSymbolicLink(atPath: winFolder.path, withDestinationPath: target.path)
            }
        }

        // 5. Ready marker records the creating engine id (the rebuild key).
        progress?(.step(.marker, fraction: 0, detail: PrefixProgress.SubStep.marker.detail))
        let engineID = engine.activeEngineID ?? "unknown"
        try Data("engine=\(engineID)\n".utf8)
            .write(to: paths.prefix.appendingPathComponent(Self.readyMarker))

        // Closed only here, on success. A `begin` with no `end` is how the log
        // says the prefix build is where the run died.
        if let stage4 { log?.endStage(.preparePrefix, startedAt: stage4) }
    }

    /// Destructive: shuts the environment down and deletes the prefix.
    /// The Shell confirms with the user before calling this (spec §4.2).
    public func reset() throws {
        shutdownServer()
        try FileManager.default.removeItem(at: paths.prefix)
    }

    private func shutdownServer() {
        let env = WineEnvironment.build(engineCurrent: paths.engineCurrent, prefix: paths.prefix)
        _ = try? Subprocess.run(engine.activeWineserverBinary, arguments: ["-k"],
                                environment: env, timeout: 30, captureOutput: false)
        _ = try? Subprocess.run(engine.activeWineserverBinary, arguments: ["-w"],
                                environment: env, timeout: 60, captureOutput: false)
    }

    // MARK: helpers

    private func verifyNonEmptyDirectory(_ url: URL, name: String) throws {
        let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        guard let contents, !contents.isEmpty else {
            throw PrefixError.monoOrGeckoMissing("\(name) is missing at \(url.path)")
        }
    }

    /// Font provisioning (spec §4.2 step 3a): install the one bundled font macOS
    /// lacks and register the broad fallback substitution table from
    /// `FontProvisioning`. Idempotent and best-effort: any failure is swallowed
    /// so it can never block prefix readiness.
    private func provisionFonts(env: [String: String], log: SetupLog?,
                                progress: (@Sendable (PrefixProgress) -> Void)?) {
        let fm = FileManager.default
        let fontsDir = paths.prefix.appendingPathComponent("drive_c/windows/Fonts")
        try? fm.createDirectory(at: fontsDir, withIntermediateDirectories: true)

        // The bundled font file must be copied either way — the registry value
        // only names it.
        if let src = Bundle.main.url(forResource: FontProvisioning.bundledFontResource,
                                     withExtension: "ttf") {
            let dst = fontsDir.appendingPathComponent(FontProvisioning.bundledFontFileName)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }

        progress?(.step(.fonts, fraction: 0, detail: "Registering fonts…"))

        if FontProvisioning.useBatchedImport, importFontRegistry(env: env, log: log) {
            progress?(.step(.fonts, fraction: 1, detail: "Registering fonts…"))
            return
        }

        // Fallback: the proven per-write path (spec §5.3).
        log?.note("font batch import unavailable or failed; using per-write fallback")
        provisionFontsPerWrite(env: env, log: log, progress: progress)
    }

    /// One `wine regedit <file>` import. Best-effort: returns false on any
    /// failure so the caller falls back. Never throws — font provisioning must
    /// never fail the prefix build.
    private func importFontRegistry(env: [String: String], log: SetupLog?) -> Bool {
        let fm = FileManager.default
        let regURL = paths.prefix.appendingPathComponent("openxe-fonts.reg")
        defer { try? fm.removeItem(at: regURL) }

        do {
            // ASCII by construction (spec §5.3); .ascii encoding makes that a
            // hard guarantee rather than an assumption.
            guard let data = FontProvisioning.regFileContents().data(using: .ascii) else {
                log?.note("font .reg contents were not ASCII; falling back")
                return false
            }
            try data.write(to: regURL)
        } catch {
            log?.note("could not write font .reg: \(error.localizedDescription)")
            return false
        }

        let result = try? Subprocess.run(engine.activeWineBinary,
                                         arguments: ["regedit", regURL.path],
                                         environment: env, timeout: 120,
                                         logHandle: log?.handle)
        guard let result, result.status == 0 else {
            log?.note("regedit import exited \(result?.status.description ?? "n/a")")
            return false
        }
        log?.note("font registry imported in one pass (\(PrefixManager.fontWriteCount) values)")
        return true
    }

    /// The proven 57-spawn path, retained behind `FontProvisioning.useBatchedImport`
    /// (spec §5.3). Its per-write counter is now the fallback path's progress
    /// reporting.
    private func provisionFontsPerWrite(env: [String: String], log: SetupLog?,
                                        progress: (@Sendable (PrefixProgress) -> Void)?) {
        let fm = FileManager.default
        let fontsDir = paths.prefix.appendingPathComponent("drive_c/windows/Fonts")
        try? fm.createDirectory(at: fontsDir, withIntermediateDirectories: true)

        let total = Self.fontWriteCount
        var done = 0
        func tick() {
            done += 1
            progress?(.step(.fonts, fraction: Double(done) / Double(total),
                            detail: "Registering fonts (\(done) of \(total))…"))
        }

        // Install the bundled FontAwesome so family-name fallback resolves it
        // when wine-mono cannot load an app's embedded copy. Every other common
        // font (the Microsoft corefonts) is already provided by the Mac driver
        // from macOS — see FontProvisioning for why we do not bundle those.
        if let src = Bundle.main.url(forResource: FontProvisioning.bundledFontResource,
                                     withExtension: "ttf") {
            let dst = fontsDir.appendingPathComponent(FontProvisioning.bundledFontFileName)
            try? fm.removeItem(at: dst)
            if (try? fm.copyItem(at: src, to: dst)) != nil {
                regBestEffort([#"HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts"#,
                               "/v", "FontAwesome (TrueType)", "/t", "REG_SZ",
                               "/d", FontProvisioning.bundledFontFileName, "/f"],
                              env: env, log: log)
            }
        }
        tick() // counted whether or not the bundled font was present

        // Broad fallback substitutions. Set both the GDI table (which wine-mono
        // reads for WPF) and wine's own Replacements table so a missing font
        // degrades to a close available face rather than crashing.
        for (from, to) in FontProvisioning.substitutions {
            regBestEffort([#"HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes"#,
                           "/v", from, "/t", "REG_SZ", "/d", to, "/f"], env: env, log: log)
            tick()
            regBestEffort([#"HKCU\Software\Wine\Fonts\Replacements"#,
                           "/v", from, "/t", "REG_SZ", "/d", to, "/f"], env: env, log: log)
            tick()
        }
    }

    private func regBestEffort(_ args: [String], env: [String: String], log: SetupLog?) {
        _ = try? Subprocess.run(engine.activeWineBinary, arguments: ["reg", "add"] + args,
                                environment: env, timeout: 60,
                                logHandle: log?.handle, captureOutput: false)
    }

    private func registryAdd(key: String, value: String, type: String, data: String,
                             env: [String: String], log: SetupLog?) throws {
        let result = try Subprocess.run(
            engine.activeWineBinary,
            arguments: ["reg", "add", key, "/v", value, "/t", type, "/d", data, "/f"],
            environment: env, timeout: 120, logHandle: log?.handle)
        guard result.status == 0 else {
            throw PrefixError.bootFailed(status: result.status,
                                         detail: "reg add \(key)\\\(value): \(result.output.suffix(200))")
        }
    }
}

/// Polls the prefix's file count at 1 Hz to give sub-step 4a a coarse
/// determinate bar (spec §5.1, closes R3a). `wineboot` reports no progress of
/// its own, and after font batching 4a covers 82 % of stage 4 — this is the
/// second, independent signal that keeps the stage from resting on liveness
/// evidence alone.
///
/// Advisory by construction: the reported fraction is a running maximum, so a
/// poll that transiently counts fewer entries cannot rewind the bar, and the
/// count never gates completion — `wineboot` exiting does.
final class BootProgressPoller: @unchecked Sendable {
    private let prefix: URL
    private let onProgress: (Double) -> Void
    private var timer: DispatchSourceTimer?
    private var highWater: Double = 0
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.openxe.boot-progress")

    init(prefix: URL, onProgress: @escaping (Double) -> Void) {
        self.prefix = prefix
        self.onProgress = onProgress
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.pollOnce() }
        lock.lock(); timer = t; lock.unlock()
        t.resume()
    }

    /// Idempotent — the boot path calls this on success and again from a defer
    /// that covers the throw path.
    func stop() {
        lock.lock(); let t = timer; timer = nil; lock.unlock()
        t?.cancel()
    }

    /// One poll. Internal rather than private so the monotonicity guarantee is
    /// testable without waiting on a 1 Hz timer.
    func pollOnce() {
        let count = Self.entryCount(at: prefix)
        let fraction = PrefixProgress.bootFraction(filesSeen: count)
        lock.lock()
        guard fraction > highWater else { lock.unlock(); return }
        highWater = fraction
        lock.unlock()
        onProgress(fraction)
    }

    /// ~10 ms on a 2,027-entry prefix (measured), i.e. ~1 % of one core at
    /// 1 Hz. Cheap enough not to warrant a smarter mechanism.
    static func entryCount(at url: URL) -> Int {
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return 0 }
        var n = 0
        for case _ as URL in e { n += 1 }
        return n
    }
}

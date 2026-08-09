import Foundation
import CryptoKit

/// A Wine engine OpenXE can install and run. Spec §4.1. The download source
/// (URL + checksum) and the wine loader binary name are parameters, not
/// hardcoded — so a self-built Wine-Crossover engine drops in beside the
/// stock Gcenx build behind the same `engine/current` contract.
public struct EngineDescriptor: Sendable, Equatable, Codable {
    public let id: String              // stable dir name, e.g. "gcenx-stable-11.0_1"
    public let displayName: String     // shown in settings
    public let version: String         // human version string
    public let url: URL                // download source
    public let sha256: String          // expected archive checksum
    public let wineBinaryName: String  // "wine" (new-wow64 Gcenx) or "wine64" (older CrossOver)

    public init(id: String, displayName: String, version: String,
                url: URL, sha256: String, wineBinaryName: String) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.wineBinaryName = wineBinaryName
    }
}

/// Known-good engines. The stock Gcenx build is the only trusted default;
/// other engines (e.g. a self-built Wine-Crossover) are installed explicitly
/// and never shipped as the default from an unofficial mirror. Spec §4.1, §8.
public enum EngineCatalog {
    /// Pinned Gcenx Wine 11.0 stable — verified against the live release
    /// 2026-07-06 (checksum computed by us at pin time; upstream publishes none).
    public static let stock = EngineDescriptor(
        id: "gcenx-stable-11.0_1",
        displayName: "Wine 11.0 (Gcenx stable)",
        version: "wine-stable-11.0_1",
        url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz")!,
        sha256: "b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388",
        wineBinaryName: "wine")

    /// The engine installed and activated on first run.
    public static let `default` = stock

    public static let builtIn: [EngineDescriptor] = [stock]
}

public enum EngineProgress: Sendable {
    case downloading(fraction: Double) // 0...1; -1 when total size unknown
    case verifying
    case extracting
    /// Entries unpacked so far. Deliberately a count, not a fraction: the
    /// archive's entry total is not known until the archive has been read, so
    /// there is no honest denominator. Drives the status line while the bar
    /// stays indeterminate — movement we can prove, rather than a bar position
    /// we would have to invent.
    case unpacking(entries: Int)
}

public enum EngineError: Error, LocalizedError {
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case layoutUnexpected(String)
    case notInstalled(String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let detail):
            return "Engine download failed: \(detail)"
        case .checksumMismatch(let expected, let actual):
            return "Downloaded engine failed verification (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)"
        case .layoutUnexpected(let detail):
            return "Engine archive layout unexpected: \(detail)"
        case .notInstalled(let id):
            return "Engine '\(id)' is not installed"
        }
    }
}

/// Streaming SHA-256 (CryptoKit), 1 MiB chunks.
public enum FileHasher {
    public static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Owns engine/ exclusively: acquire, verify, install multiple engines, and
/// select the active one. Spec §4.1. Other components reach Wine only through
/// `engine/current` (the swap point) resolved via `activeWineBinary`.
public final class EngineManager: Sendable {
    private let paths: OpenXEPaths

    public init(paths: OpenXEPaths) {
        self.paths = paths
    }

    // MARK: installed-engine inventory

    /// IDs of every fully installed engine (has a wine root and descriptor).
    public func installedEngineIDs() -> [String] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: paths.engineVersions,
                                                   includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { dir -> String? in
            guard dir.hasDirectoryPath, dir.lastPathComponent != "current" else { return nil }
            return descriptor(forInstalledID: dir.lastPathComponent) != nil ? dir.lastPathComponent : nil
        }.sorted()
    }

    /// The saved descriptor for an installed engine (engine/<id>/descriptor.json).
    /// Auto-heals pre-multi-engine installs: if descriptor.json is absent but a
    /// legacy `version` file and a `wine/bin/wine` loader exist, synthesize a
    /// descriptor (persisting it) so an existing install is not forced through
    /// a needless re-download and prefix rebuild.
    public func descriptor(forInstalledID id: String) -> EngineDescriptor? {
        let engineDir = paths.engineVersions.appendingPathComponent(id)
        let jsonURL = engineDir.appendingPathComponent("descriptor.json")
        if let data = try? Data(contentsOf: jsonURL),
           let d = try? JSONDecoder().decode(EngineDescriptor.self, from: data) {
            return d
        }
        // Legacy backfill: a "version" marker + a `wine` loader is the old
        // single-engine layout. Adopt the stock catalog metadata when the
        // version matches; otherwise synthesize a minimal descriptor.
        // The backfill must not resurrect a half-committed engine: an install
        // killed between the move and stripQuarantine leaves a `version` file
        // and a `wine` loader that is still quarantined and can never run.
        let fm = FileManager.default
        let wineLoader = engineDir.appendingPathComponent("wine/bin/wine")
        guard fm.isExecutableFile(atPath: wineLoader.path),
              !Self.isQuarantined(at: wineLoader),
              let version = try? String(contentsOf: engineDir.appendingPathComponent("version"),
                                        encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }

        let healed: EngineDescriptor
        if version == EngineCatalog.stock.version {
            healed = EngineDescriptor(id: id, displayName: EngineCatalog.stock.displayName,
                                      version: version, url: EngineCatalog.stock.url,
                                      sha256: EngineCatalog.stock.sha256, wineBinaryName: "wine")
        } else {
            healed = EngineDescriptor(id: id, displayName: version, version: version,
                                      url: URL(string: "about:blank")!,
                                      sha256: String(repeating: "0", count: 64), wineBinaryName: "wine")
        }
        if let out = try? JSONEncoder().encode(healed) { try? out.write(to: jsonURL) }
        return healed
    }

    public func isInstalled(_ id: String) -> Bool {
        guard let d = descriptor(forInstalledID: id) else { return false }
        let wine = paths.engineVersions.appendingPathComponent(id)
            .appendingPathComponent("wine/bin/\(d.wineBinaryName)")
        return FileManager.default.isExecutableFile(atPath: wine.path)
    }

    // MARK: active engine

    /// The active engine id = the target of the engine/current symlink.
    public var activeEngineID: String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: paths.engineCurrent.path)
    }

    public var activeDescriptor: EngineDescriptor? {
        activeEngineID.flatMap { descriptor(forInstalledID: $0) }
    }

    /// True when the active symlink resolves to a runnable engine.
    public var isActiveInstalled: Bool {
        guard let id = activeEngineID else { return false }
        return isInstalled(id)
    }

    /// For settings display.
    public var installedVersion: String? { activeDescriptor?.version }

    /// The active engine's wine loader (name varies per engine). Runner and
    /// PrefixManager spawn Wine through this.
    public var activeWineBinary: URL {
        let name = activeDescriptor?.wineBinaryName ?? "wine"
        return paths.engineCurrent.appendingPathComponent("wine/bin/\(name)")
    }

    /// wineserver is named consistently across the engines we support.
    public var activeWineserverBinary: URL {
        paths.engineCurrent.appendingPathComponent("wine/bin/wineserver")
    }

    /// Point engine/current at an installed engine. Returns true when the
    /// active engine actually changed — the caller must then rebuild the
    /// prefix, because a Wine prefix is bound to its engine and Wine does not
    /// support prefix downgrades (spec §4.1, §4.2).
    @discardableResult
    public func setActive(_ id: String) throws -> Bool {
        guard isInstalled(id) else { throw EngineError.notInstalled(id) }
        let previous = activeEngineID
        guard previous != id else { return false }
        let fm = FileManager.default
        try? fm.removeItem(at: paths.engineCurrent)
        try fm.createSymbolicLink(atPath: paths.engineCurrent.path, withDestinationPath: id)
        return true
    }

    // MARK: install

    /// Download (HTTP-range resumable) → verify SHA-256 (one automatic
    /// re-download on mismatch) → extract → strip quarantine → record
    /// descriptor. Does NOT activate; call `setActive` for that. If this is
    /// the first engine installed, it is auto-activated as a convenience.
    public func install(_ descriptor: EngineDescriptor,
                        log: SetupLog? = nil,
                        onEntry: (@Sendable (Int) -> Void)? = nil,
                        progress: @escaping @Sendable (EngineProgress) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.engineVersions, withIntermediateDirectories: true)
        let partial = paths.engineVersions.appendingPathComponent("download-\(descriptor.id).partial")

        var lastError: EngineError?
        for attempt in 1...2 { // one automatic retry on checksum mismatch (spec §6)
            // Stage 2 spans transfer AND verification: spec §4.2 makes the
            // checksum the terminal act of the download stage, not the opening
            // act of the unpack. The two halves are noted separately so the
            // calibration can still split them.
            let stage2 = log?.startStage(.downloadEngine, attempt: attempt)
            let transferStart = DispatchTime.now()
            try await download(descriptor, to: partial, progress: progress)
            log?.note("engine archive transferred", since: transferStart)

            progress(.verifying)
            let verifyStart = DispatchTime.now()
            let actual = try FileHasher.sha256Hex(of: partial)
            log?.note("engine archive sha256 verified", since: verifyStart)

            if actual == descriptor.sha256 {
                if let stage2 { log?.endStage(.downloadEngine, startedAt: stage2) }
                progress(.extracting)
                let stage3 = log?.startStage(.unpackEngine)
                try extractAndInstall(descriptor, archive: partial, log: log,
                                      onEntry: Self.unpackReporter(forwarding: onEntry,
                                                                   to: progress))
                if let stage3 { log?.endStage(.unpackEngine, startedAt: stage3) }
                try? fm.removeItem(at: partial)
                if activeEngineID == nil { try setActive(descriptor.id) }
                return
            }
            // Stage 2 failed: its `begin` marker stays unterminated on purpose,
            // and attempt 2 opens a new one.
            log?.note("checksum mismatch (expected \(descriptor.sha256.prefix(12))…, "
                      + "got \(actual.prefix(12))…); re-downloading")
            lastError = .checksumMismatch(expected: descriptor.sha256, actual: actual)
            try? fm.removeItem(at: partial) // poisoned artifact; start clean
        }
        throw lastError ?? EngineError.downloadFailed("unknown")
    }

    /// Install a pre-downloaded engine archive (used by the from-source build
    /// path and by tests, avoiding a network round-trip). Verifies the
    /// checksum, extracts, records the descriptor. Does not activate unless
    /// it is the first engine.
    public func installLocalArchive(_ descriptor: EngineDescriptor, archive: URL,
                                    log: SetupLog? = nil,
                                    onEntry: (@Sendable (Int) -> Void)? = nil) throws {
        let verifyStart = DispatchTime.now()
        let actual = try FileHasher.sha256Hex(of: archive)
        log?.note("engine archive sha256 verified", since: verifyStart)
        guard actual == descriptor.sha256 else {
            log?.note("checksum mismatch (expected \(descriptor.sha256.prefix(12))…, "
                      + "got \(actual.prefix(12))…)")
            throw EngineError.checksumMismatch(expected: descriptor.sha256, actual: actual)
        }
        let stage3 = log?.startStage(.unpackEngine)
        try extractAndInstall(descriptor, archive: archive, log: log, onEntry: onEntry)
        if let stage3 { log?.endStage(.unpackEngine, startedAt: stage3) }
        if activeEngineID == nil { try setActive(descriptor.id) }
    }

    /// Convenience for the first-run/launch path: ensure the default engine is
    /// installed and active. `log` carries the setup narrative (stages 2 and 3).
    public func ensureDefaultActive(log: SetupLog? = nil,
                                    progress: @escaping @Sendable (EngineProgress) -> Void) async throws {
        if isActiveInstalled { return }
        let def = EngineCatalog.default
        if !isInstalled(def.id) {
            try await install(def, log: log, progress: progress)
        }
        try setActive(def.id)
    }

    // MARK: unpack reporting

    /// One event per this many tar entries. `tar -xvf` on the engine archive
    /// emits thousands of lines in a few seconds and every event costs a hop
    /// to the main actor; the user cannot read a counter faster than this
    /// anyway.
    static let unpackReportInterval = 25

    /// Bridges the tar entry stream onto the `EngineProgress` channel.
    ///
    /// Stage 3 published nothing because `ensureDefaultActive` never supplied
    /// an `onEntry` and so `extractAndInstall`'s counter fed a nil closure.
    /// Rather than thread a second closure through every call site — leaving
    /// the surface to interleave two channels for one stage — `install`
    /// synthesizes the reporter from the progress closure it already has. Any
    /// caller-supplied `onEntry` still receives every entry, unthrottled.
    static func unpackReporter(forwarding onEntry: (@Sendable (Int) -> Void)?,
                               to progress: @escaping @Sendable (EngineProgress) -> Void)
        -> @Sendable (Int) -> Void {
        { n in
            onEntry?(n)
            // n == 1 so a small archive still reports at least once.
            if n == 1 || n % unpackReportInterval == 0 { progress(.unpacking(entries: n)) }
        }
    }

    // MARK: download

    private func download(_ descriptor: EngineDescriptor, to partial: URL,
                          progress: @escaping @Sendable (EngineProgress) -> Void) async throws {
        let fm = FileManager.default
        let existing = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? Int64).flatMap { $0 } ?? 0

        var request = URLRequest(url: descriptor.url)
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }

        // ProgressiveDownload, not `URLSession.shared.download(for:delegate:)`:
        // the async convenience delivers ZERO didWriteData callbacks, so the
        // engine bar sat at its start position for the entire 314 s transfer.
        // See ProgressiveDownload for the measurement.
        let downloaded: DownloadedFile
        do {
            downloaded = try await ProgressiveDownload.fetch(request) { counts in
                progress(.downloading(fraction: counts.fraction(resumedFrom: existing) ?? -1))
            }
        } catch let error as DownloadError {
            throw EngineError.downloadFailed(error.errorDescription ?? "\(error)")
        }
        let tempURL = downloaded.url
        let http = downloaded.response

        switch http.statusCode {
        case 206: // server honored the range: append the remainder
            let dst = try FileHandle(forWritingTo: partial)
            defer { try? dst.close() }
            try dst.seekToEnd()
            let src = try FileHandle(forReadingFrom: tempURL)
            defer { try? src.close() }
            while let chunk = try src.read(upToCount: 1 << 20), !chunk.isEmpty {
                try dst.write(contentsOf: chunk)
            }
            try? fm.removeItem(at: tempURL)
        case 200: // full body (fresh download, or server ignored the range)
            try? fm.removeItem(at: partial)
            try fm.moveItem(at: tempURL, to: partial)
        case 416: // partial file is already complete; verification decides its fate
            try? fm.removeItem(at: tempURL)
        default:
            throw EngineError.downloadFailed("HTTP \(http.statusCode)")
        }
    }

    // MARK: extract + record

    private func extractAndInstall(_ descriptor: EngineDescriptor, archive: URL,
                                   log: SetupLog? = nil,
                                   onEntry: (@Sendable (Int) -> Void)? = nil) throws {
        let fm = FileManager.default
        let staging = paths.engineVersions.appendingPathComponent("staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // `tar -xvf` auto-detects xz/gz — engine-agnostic archive format. The
        // -v turns the only long silent stretch of stage 3 into a countable
        // stream (spec §5.2).
        let counter = EntryCounter()
        let untar = try Subprocess.run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xvf", archive.path, "-C", staging.path],
            timeout: 900,
            logHandle: nil,               // sampled below, not teed verbatim
            onLine: { _ in
                let n = counter.increment()
                // Bound log volume: every 200th path, per spec §5.2.
                if n % 200 == 0 { log?.note("unpacked \(n) entries") }
                onEntry?(n)
            })
        guard untar.status == 0 else {
            throw EngineError.layoutUnexpected("tar exited \(untar.status): \(untar.output.suffix(300))")
        }

        // Engine-agnostic layout discovery: find the directory containing
        // bin/<wineBinaryName>. Handles Gcenx (*.app/Contents/Resources/wine)
        // and CrossOver-style (top-level dir) archives alike.
        guard let wineRoot = Self.findWineRoot(in: staging, binaryName: descriptor.wineBinaryName) else {
            throw EngineError.layoutUnexpected(
                "no directory containing bin/\(descriptor.wineBinaryName) found in archive")
        }

        let engineDir = paths.engineVersions.appendingPathComponent(descriptor.id, isDirectory: true)
        try? fm.removeItem(at: engineDir)
        try fm.createDirectory(at: engineDir, withIntermediateDirectories: true)
        try fm.moveItem(at: wineRoot, to: engineDir.appendingPathComponent("wine"))

        // De-quarantine BEFORE recording the descriptor. Gatekeeper would block
        // the unsigned Wine binaries otherwise, and until 2026-08-08 a kill in
        // this window left an engine that reported installed but could never
        // run, with no code path to repair it (spec §10.1).
        try Self.stripQuarantine(at: engineDir)

        // Legacy plain-text version marker (kept for humans).
        try Data("\(descriptor.version)\n".utf8)
            .write(to: engineDir.appendingPathComponent("version"))

        // descriptor.json is the atomic commit point: its existence means
        // "fully installed and de-quarantined". Written via a temp file so a
        // crash mid-write cannot leave a truncated descriptor behind.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let descriptorURL = engineDir.appendingPathComponent("descriptor.json")
        let tmp = engineDir.appendingPathComponent("descriptor.json.tmp")
        try encoder.encode(descriptor).write(to: tmp)
        _ = try fm.replaceItemAt(descriptorURL, withItemAt: tmp)
    }

    /// Entries the pinned engine archive contains. MEASURED via `tar -tf`
    /// (spec §5.2) — not the installed tree's 5,324, which excludes the outer
    /// `.app` wrapper `findWineRoot` discards and includes two files written
    /// after extraction. Re-derive only if the engine is repinned; see
    /// Task 7 Step 4 of the setup-resilience plan for the exact command.
    /// Progress clamps as a safety net.
    ///
    /// Measured 2026-08-09: `tar -tf wine-stable-11.0_1-osx64.tar.xz | wc -l`
    /// = 5,333, against an archive whose SHA-256 matched the pin exactly.
    public static let expectedArchiveEntries = 5_333

    /// Depth-limited search for a directory holding `bin/<binaryName>`.
    static func findWineRoot(in staging: URL, binaryName: String) -> URL? {
        let fm = FileManager.default
        var frontier = [staging]
        var depth = 0
        while !frontier.isEmpty, depth < 6 {
            var next: [URL] = []
            for dir in frontier {
                let candidate = dir.appendingPathComponent("bin/\(binaryName)")
                if fm.isExecutableFile(atPath: candidate.path) {
                    return dir
                }
                let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                next.append(contentsOf: children.filter { $0.hasDirectoryPath })
            }
            frontier = next
            depth += 1
        }
        return nil
    }

    /// Engine-agnostic quarantine strip (spec §4.1). Ensures owner-write
    /// first: some engine tarballs (e.g. CrossOver-derived builds) unpack
    /// read-only, and `xattr -d` fails silently on read-only files — which
    /// leaves Gatekeeper dialogs and dylib load failures at first launch.
    /// True when the file still carries com.apple.quarantine. Used to refuse
    /// the legacy backfill for an engine that was never de-quarantined.
    static func isQuarantined(at url: URL) -> Bool {
        let result = try? Subprocess.run(URL(fileURLWithPath: "/usr/bin/xattr"),
                                         arguments: ["-p", "com.apple.quarantine", url.path],
                                         timeout: 10)
        return result?.status == 0
    }

    static func stripQuarantine(at directory: URL) throws {
        try Subprocess.run(URL(fileURLWithPath: "/bin/chmod"),
                           arguments: ["-R", "u+w", directory.path],
                           timeout: 300)
        try Subprocess.run(URL(fileURLWithPath: "/usr/bin/xattr"),
                           arguments: ["-dr", "com.apple.quarantine", directory.path],
                           timeout: 300)
    }
}

/// Thread-safe entry counter for the unpack progress stream.
final class EntryCounter: @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}

// The engine download's URLSession delegate now lives in ProgressiveDownload,
// together with the fraction arithmetic (`TransferCounts`). The old
// `DownloadProgressDelegate` was correct in isolation and never called: it was
// handed to `URLSession.download(for:delegate:)`, which does not deliver
// incremental callbacks to it on any session.

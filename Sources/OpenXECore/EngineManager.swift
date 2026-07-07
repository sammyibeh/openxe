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
    public func descriptor(forInstalledID id: String) -> EngineDescriptor? {
        let url = paths.engineVersions.appendingPathComponent(id)
            .appendingPathComponent("descriptor.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EngineDescriptor.self, from: data)
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
                        progress: @escaping @Sendable (EngineProgress) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.engineVersions, withIntermediateDirectories: true)
        let partial = paths.engineVersions.appendingPathComponent("download-\(descriptor.id).partial")

        var lastError: EngineError?
        for _ in 0..<2 { // one automatic retry on checksum mismatch (spec §6)
            try await download(descriptor, to: partial, progress: progress)
            progress(.verifying)
            let actual = try FileHasher.sha256Hex(of: partial)
            if actual == descriptor.sha256 {
                progress(.extracting)
                try extractAndInstall(descriptor, archive: partial)
                try? fm.removeItem(at: partial)
                if activeEngineID == nil { try setActive(descriptor.id) }
                return
            }
            lastError = .checksumMismatch(expected: descriptor.sha256, actual: actual)
            try? fm.removeItem(at: partial) // poisoned artifact; start clean
        }
        throw lastError ?? EngineError.downloadFailed("unknown")
    }

    /// Install a pre-downloaded engine archive (used by the from-source build
    /// path and by tests, avoiding a network round-trip). Verifies the
    /// checksum, extracts, records the descriptor. Does not activate unless
    /// it is the first engine.
    public func installLocalArchive(_ descriptor: EngineDescriptor, archive: URL) throws {
        let actual = try FileHasher.sha256Hex(of: archive)
        guard actual == descriptor.sha256 else {
            throw EngineError.checksumMismatch(expected: descriptor.sha256, actual: actual)
        }
        try extractAndInstall(descriptor, archive: archive)
        if activeEngineID == nil { try setActive(descriptor.id) }
    }

    /// Convenience for the first-run/launch path: ensure the default engine is
    /// installed and active.
    public func ensureDefaultActive(progress: @escaping @Sendable (EngineProgress) -> Void) async throws {
        if isActiveInstalled { return }
        let def = EngineCatalog.default
        if !isInstalled(def.id) {
            try await install(def, progress: progress)
        }
        try setActive(def.id)
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

        let delegate = DownloadProgressDelegate(alreadyHave: existing, progress: progress)
        let (tempURL, response) = try await URLSession.shared.download(for: request, delegate: delegate)

        guard let http = response as? HTTPURLResponse else {
            throw EngineError.downloadFailed("no HTTP response")
        }
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

    private func extractAndInstall(_ descriptor: EngineDescriptor, archive: URL) throws {
        let fm = FileManager.default
        let staging = paths.engineVersions.appendingPathComponent("staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // `tar -xf` auto-detects xz/gz — engine-agnostic archive format.
        let untar = try Subprocess.run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xf", archive.path, "-C", staging.path],
            timeout: 900)
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

        // Record the descriptor so the engine is self-describing on disk.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(descriptor).write(to: engineDir.appendingPathComponent("descriptor.json"))
        // Legacy plain-text version marker (kept for humans).
        try Data("\(descriptor.version)\n".utf8).write(to: engineDir.appendingPathComponent("version"))

        // Gatekeeper would block the unsigned Wine binaries if quarantined.
        try Self.stripQuarantine(at: engineDir)
    }

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
    static func stripQuarantine(at directory: URL) throws {
        try Subprocess.run(URL(fileURLWithPath: "/bin/chmod"),
                           arguments: ["-R", "u+w", directory.path],
                           timeout: 300)
        try Subprocess.run(URL(fileURLWithPath: "/usr/bin/xattr"),
                           arguments: ["-dr", "com.apple.quarantine", directory.path],
                           timeout: 300)
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let alreadyHave: Int64
    private let progress: @Sendable (EngineProgress) -> Void

    init(alreadyHave: Int64, progress: @escaping @Sendable (EngineProgress) -> Void) {
        self.alreadyHave = alreadyHave
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else {
            progress(.downloading(fraction: -1))
            return
        }
        let done = Double(alreadyHave + totalBytesWritten)
        let total = Double(alreadyHave + totalBytesExpectedToWrite)
        progress(.downloading(fraction: done / total))
    }
}

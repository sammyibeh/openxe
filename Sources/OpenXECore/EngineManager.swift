import Foundation
import CryptoKit

/// The pinned Wine engine. Verified against the live GitHub release on
/// 2026-07-06 (spec §4.1). The SHA-256 was computed by us at pin time —
/// upstream publishes no checksum.
public struct EnginePin: Sendable {
    public let version: String
    public let url: URL
    public let sha256: String

    public static let current = EnginePin(
        version: "wine-stable-11.0_1",
        url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz")!,
        sha256: "b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388"
    )
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

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let detail):
            return "Engine download failed: \(detail)"
        case .checksumMismatch(let expected, let actual):
            return "Downloaded engine failed verification (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)"
        case .layoutUnexpected(let detail):
            return "Engine archive layout unexpected: \(detail)"
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

/// Owns engine/ exclusively: acquire, verify, install, report. Spec §4.1.
/// Other components reach Wine only through engine/current (the swap point).
public final class EngineManager: Sendable {
    private let paths: OpenXEPaths
    private let pin: EnginePin

    public init(paths: OpenXEPaths, pin: EnginePin = .current) {
        self.paths = paths
        self.pin = pin
    }

    /// engine/current/wine/bin/wine exists and the version marker matches the pin.
    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: paths.wineBinary.path)
            && installedVersion == pin.version
    }

    /// Contents of engine/current/version, for settings display.
    public var installedVersion: String? {
        try? String(contentsOf: paths.engineCurrent.appendingPathComponent("version"),
                    encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Download (HTTP-range resumable) → verify SHA-256 (one automatic
    /// re-download on mismatch) → extract → strip quarantine → swap in.
    public func install(progress: @escaping @Sendable (EngineProgress) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.engineVersions, withIntermediateDirectories: true)
        let partial = paths.engineVersions.appendingPathComponent("download.partial")

        var lastError: EngineError?
        for _ in 0..<2 { // one automatic retry on checksum mismatch (spec §6)
            try await download(to: partial, progress: progress)
            progress(.verifying)
            let actual = try FileHasher.sha256Hex(of: partial)
            if actual == pin.sha256 {
                progress(.extracting)
                try extractAndSwapIn(archive: partial)
                try? fm.removeItem(at: partial)
                return
            }
            lastError = .checksumMismatch(expected: pin.sha256, actual: actual)
            try? fm.removeItem(at: partial) // poisoned artifact; start clean
        }
        throw lastError ?? EngineError.downloadFailed("unknown")
    }

    // MARK: download

    private func download(to partial: URL,
                          progress: @escaping @Sendable (EngineProgress) -> Void) async throws {
        let fm = FileManager.default
        let existing = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? Int64).flatMap { $0 } ?? 0

        var request = URLRequest(url: pin.url)
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

    // MARK: extract + swap

    private func extractAndSwapIn(archive: URL) throws {
        let fm = FileManager.default
        let staging = paths.engineVersions.appendingPathComponent("staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let untar = try Subprocess.run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xJf", archive.path, "-C", staging.path],
            timeout: 900)
        guard untar.status == 0 else {
            throw EngineError.layoutUnexpected("tar exited \(untar.status): \(untar.output.suffix(300))")
        }

        // Verified layout: <Something>.app/Contents/Resources/wine/{bin,lib,share}.
        // Search one level deep so stable/devel/staging naming all work.
        guard let appDir = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }),
            fm.fileExists(atPath: appDir.appendingPathComponent("Contents/Resources/wine/bin/wine").path)
        else {
            throw EngineError.layoutUnexpected("no *.app/Contents/Resources/wine/bin/wine in archive")
        }
        let wineTree = appDir.appendingPathComponent("Contents/Resources/wine")

        let versionDir = paths.engineVersions.appendingPathComponent(pin.version, isDirectory: true)
        try? fm.removeItem(at: versionDir)
        try fm.createDirectory(at: versionDir, withIntermediateDirectories: true)
        try fm.moveItem(at: wineTree, to: versionDir.appendingPathComponent("wine"))
        try Data("\(pin.version)\n".utf8)
            .write(to: versionDir.appendingPathComponent("version"))

        // Gatekeeper would block the unsigned Wine binaries if quarantined.
        try Subprocess.run(URL(fileURLWithPath: "/usr/bin/xattr"),
                           arguments: ["-dr", "com.apple.quarantine", versionDir.path],
                           timeout: 300)

        // Swap point: engine/current -> <version> (relative symlink).
        try? fm.removeItem(at: paths.engineCurrent)
        try fm.createSymbolicLink(atPath: paths.engineCurrent.path,
                                  withDestinationPath: pin.version)
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

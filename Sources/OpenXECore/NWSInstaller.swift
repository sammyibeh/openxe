import Foundation

/// Fetches and installs New World Scheduler (NWS) into the shared prefix.
/// Spec §4.7. OpenXE is an unofficial, purpose-built runner for NWS on macOS;
/// this component is the guided-setup engine behind the wizard (Shell §4.4).
///
/// COMPLIANCE (hard rules, spec §4.7):
/// - The NWS installer `.exe` is NEVER bundled, mirrored, cached for
///   redistribution, or committed to the repo. It is downloaded at RUNTIME from
///   the vendor's official GitHub release (or the vendor's own fallback URL) into
///   the user's own machine, run once, then removed.
/// - The downloaded size is verified against the size the release API reports.
/// - Activation (the 60-day trial) is never touched — it is handled in-app by NWS.
public final class NWSInstaller: Sendable {

    // MARK: official sources (spec §4.7)

    /// GitHub REST: the latest published release.
    public static let latestReleaseAPI = URL(string:
        "https://api.github.com/repos/NWScheduler/New-World-Scheduler/releases/latest")!

    /// GitHub REST: all releases (for version pinning). 100 is the API max page.
    public static let releasesAPI = URL(string:
        "https://api.github.com/repos/NWScheduler/New-World-Scheduler/releases?per_page=100")!

    /// Vendor's own download endpoint. Used ONLY when GitHub is blocked or
    /// rate-limited; it 302-redirects to the same official GitHub asset.
    public static let vendorFallbackDownload = URL(string:
        "https://nwscheduler.com/?smd_process_download=1&download_id=10395")!

    /// The GitHub repo owner/name, for constructing pinned download URLs.
    static let repoSlug = "NWScheduler/New-World-Scheduler"

    /// Where an installed NWS lands (spec §4.7 verification target).
    static let installFolderName = "New World Scheduler"
    static let installedExeName = "NWS Desktop.exe"

    private let paths: OpenXEPaths
    private let engine: EngineManager

    public init(paths: OpenXEPaths) {
        self.paths = paths
        self.engine = EngineManager(paths: paths)
    }

    // MARK: parsing (pure, unit-tested against the real API shape)

    /// One NWS release, distilled from the GitHub release JSON.
    public struct Release: Sendable, Equatable, Codable {
        public let tag: String          // e.g. "8.2.1460"
        public let name: String         // e.g. "NW Scheduler v8.2 Build #1460"
        public let assetName: String    // e.g. "NWS-Desktop-Setup_8.2_1460.exe"
        public let downloadURL: URL     // the official GitHub asset URL
        public let size: Int64          // exact byte size the API reports

        public init(tag: String, name: String, assetName: String,
                    downloadURL: URL, size: Int64) {
            self.tag = tag
            self.name = name
            self.assetName = assetName
            self.downloadURL = downloadURL
            self.size = size
        }

        /// A human label for the wizard, e.g. "8.2.1460 (~48 MB)".
        public var displayLabel: String {
            let mb = Double(size) / 1_048_576
            return size > 0 ? String(format: "%@ (~%.0f MB)", tag, mb) : tag
        }
    }

    // GitHub's JSON shapes (only the fields we read).
    private struct GHRelease: Decodable {
        let tag_name: String
        let name: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [GHAsset]
    }
    private struct GHAsset: Decodable {
        let name: String
        let browser_download_url: URL
        let size: Int64
    }

    /// The NWS setup asset within a release's asset list: prefer the
    /// `NWS-Desktop-Setup_*.exe`, else the first `.exe`, else the first asset.
    private static func setupAsset(in assets: [GHAsset]) -> GHAsset? {
        if let named = assets.first(where: {
            $0.name.lowercased().hasPrefix("nws-desktop-setup")
                && $0.name.lowercased().hasSuffix(".exe")
        }) { return named }
        if let anyExe = assets.first(where: { $0.name.lowercased().hasSuffix(".exe") }) {
            return anyExe
        }
        return assets.first
    }

    private static func release(from gh: GHRelease) throws -> Release {
        guard let asset = setupAsset(in: gh.assets) else {
            throw NWSError.noAsset(gh.tag_name)
        }
        return Release(tag: gh.tag_name,
                       name: gh.name ?? gh.tag_name,
                       assetName: asset.name,
                       downloadURL: asset.browser_download_url,
                       size: asset.size)
    }

    /// Parse the `releases/latest` response.
    public static func parseLatest(_ data: Data) throws -> Release {
        let gh: GHRelease
        do { gh = try JSONDecoder().decode(GHRelease.self, from: data) }
        catch { throw NWSError.parseFailed(String(describing: error)) }
        return try release(from: gh)
    }

    /// Parse the `releases?per_page=100` response, newest first, skipping
    /// drafts/prereleases and any release with no usable asset.
    public static func parseReleases(_ data: Data) throws -> [Release] {
        let list: [GHRelease]
        do { list = try JSONDecoder().decode([GHRelease].self, from: data) }
        catch { throw NWSError.parseFailed(String(describing: error)) }
        return list.compactMap { gh in
            guard gh.draft != true, gh.prerelease != true else { return nil }
            return try? release(from: gh)
        }
    }

    /// Construct the official pinned-download URL for a tag WITHOUT the API,
    /// per spec §4.7: `…/releases/download/<ver>.<build>/NWS-Desktop-Setup_<ver>_<build>.exe`.
    /// The tag is `<ver>.<build>` where `<build>` is the last dotted component
    /// (e.g. tag `8.2.1460` → ver `8.2`, build `1460`). Returns nil for a tag
    /// that does not split into at least a version and a build.
    public static func pinnedDownloadURL(tag: String) -> URL? {
        let parts = tag.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let build = parts.last, !build.isEmpty else { return nil }
        let version = parts.dropLast().joined(separator: ".")
        guard !version.isEmpty else { return nil }
        let asset = "NWS-Desktop-Setup_\(version)_\(build).exe"
        return URL(string:
            "https://github.com/\(repoSlug)/releases/download/\(tag)/\(asset)")
    }

    /// The exact Inno Setup silent-install arguments (spec §4.7). Pure so the
    /// install command is unit-tested without running Wine.
    public static func innoSilentArguments(installerPath: String) -> [String] {
        [installerPath, "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"]
    }

    // MARK: install state

    /// The installed `NWS Desktop.exe`, if present. NWS installs to
    /// `C:\Program Files\New World Scheduler\` (64-bit) — but a 32-bit build's
    /// Inno installer lands it under `Program Files (x86)`, so both are checked.
    public var installedExe: URL? {
        let driveC = paths.prefix.appendingPathComponent("drive_c")
        for programFiles in ["Program Files", "Program Files (x86)"] {
            let candidate = driveC
                .appendingPathComponent(programFiles)
                .appendingPathComponent(Self.installFolderName)
                .appendingPathComponent(Self.installedExeName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public var isInstalled: Bool { installedExe != nil }

    // MARK: fetch

    /// Fetch the latest release from the GitHub API (read-only, public).
    public func fetchLatest() async throws -> Release {
        let data = try await getJSON(from: Self.latestReleaseAPI)
        return try Self.parseLatest(data)
    }

    /// Fetch all releases for version pinning (newest first).
    public func fetchAllReleases() async throws -> [Release] {
        let data = try await getJSON(from: Self.releasesAPI)
        return try Self.parseReleases(data)
    }

    private func getJSON(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        // GitHub requires a User-Agent and honors the v3 media type.
        request.setValue("OpenXE", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NWSError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NWSError.network("no HTTP response")
        }
        switch http.statusCode {
        case 200: return data
        case 403, 429:
            // GitHub signals an exhausted unauthenticated quota this way.
            let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            if remaining == "0" || http.statusCode == 429 { throw NWSError.rateLimited }
            throw NWSError.network("HTTP 403")
        default:
            throw NWSError.network("HTTP \(http.statusCode)")
        }
    }

    // MARK: download

    /// Directory the installer is downloaded into (the user's app-support area,
    /// never the repo). Cleared after a successful install.
    var downloadDirectory: URL { paths.root.appendingPathComponent("nws-download", isDirectory: true) }

    /// Download a specific release's official asset, verifying the byte size
    /// against what the API reported (spec §4.7 integrity rule). Returns the
    /// on-disk installer path. `expectedSize == 0` (unknown, e.g. the vendor
    /// fallback path) skips the exact-size check but still requires a plausibly
    /// large file.
    public func download(_ release: Release, log: SetupLog? = nil,
                         progress: @escaping @Sendable (NWSProgress) -> Void) async throws -> URL {
        log?.note("downloading New World Scheduler \(release.tag) (\(release.size) bytes)")
        return try await download(from: release.downloadURL,
                                  expectedSize: release.size,
                                  fileName: release.assetName,
                                  log: log,
                                  progress: progress)
    }

    /// Download via the vendor's fallback endpoint (follows the redirect to the
    /// official GitHub asset). Used when the GitHub API is blocked/rate-limited,
    /// so the exact size is unknown; a Content-Length sanity floor still applies.
    public func downloadViaFallback(
        log: SetupLog? = nil,
        progress: @escaping @Sendable (NWSProgress) -> Void) async throws -> URL {
        log?.note("downloading New World Scheduler via the vendor fallback link")
        return try await download(from: Self.vendorFallbackDownload,
                                  expectedSize: 0,
                                  fileName: "NWS-Desktop-Setup.exe",
                                  log: log,
                                  progress: progress)
    }

    private func download(from url: URL, expectedSize: Int64, fileName: String,
                          log: SetupLog? = nil,
                          progress: @escaping @Sendable (NWSProgress) -> Void) async throws -> URL {
        // Stage 5 covers transfer AND the size check: an installer that fails
        // verification has not been downloaded, in the sense that matters.
        let stage5 = log?.startStage(.downloadNWS)
        let fm = FileManager.default
        try fm.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        let destination = downloadDirectory.appendingPathComponent(fileName)
        try? fm.removeItem(at: destination)

        var request = URLRequest(url: url)
        request.setValue("OpenXE", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 600

        let delegate = NWSDownloadDelegate(progress: progress)
        let tempURL: URL, response: URLResponse
        do {
            (tempURL, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        } catch {
            throw NWSError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NWSError.network("download HTTP \(code)")
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: tempURL, to: destination)

        // Integrity: exact size when the API told us; otherwise a sanity floor.
        let actual = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? Int64)
            .flatMap { $0 } ?? 0
        if expectedSize > 0 {
            guard actual == expectedSize else {
                try? fm.removeItem(at: destination)
                throw NWSError.sizeMismatch(expected: expectedSize, actual: actual)
            }
        } else {
            guard actual > 1_000_000 else { // < 1 MB is not a real NWS installer
                try? fm.removeItem(at: destination)
                throw NWSError.sizeMismatch(expected: 0, actual: actual)
            }
        }
        if let stage5 { log?.endStage(.downloadNWS, startedAt: stage5) }
        return destination
    }

    // MARK: install

    /// Run the downloaded installer under the active engine's Wine with Inno
    /// silent flags (spec §4.7), then verify `NWS Desktop.exe` landed. Assumes
    /// the prefix is already ready (the wizard's environment step guarantees it).
    /// Idempotent: re-running over an existing install upgrades in place; it
    /// never wipes the prefix (respects the PrefixManager data-loss fix).
    public func install(installerAt installer: URL, log: SetupLog? = nil,
                        progress: @escaping @Sendable (NWSProgress) -> Void) async throws {
        progress(.installing)
        let stage6 = log?.startStage(.installNWS)
        let env = WineEnvironment.build(engineCurrent: paths.engineCurrent, prefix: paths.prefix)
        let args = Self.innoSilentArguments(installerPath: installer.path)
        // Two different logs: `wineLog` is the verbatim Wine transcript in
        // wine.log; `log` is the setup narrative. Never the same file.
        let wineLog = try? openInstallLog()
        defer { try? wineLog?.close() }

        let result = try Subprocess.run(engine.activeWineBinary, arguments: args,
                                        environment: env, timeout: 1200, logHandle: wineLog)

        progress(.verifying)
        guard let exe = installedExe else {
            throw NWSError.installFailed(status: result.status,
                                         detail: String(result.output.suffix(500)))
        }
        _ = exe
        if let stage6 { log?.endStage(.installNWS, startedAt: stage6) }
    }

    /// Remove the downloaded installer (called after a successful install so
    /// nothing is cached/persisted).
    public func cleanupDownloads() {
        try? FileManager.default.removeItem(at: downloadDirectory)
    }

    private func openInstallLog() throws -> FileHandle {
        let fm = FileManager.default
        let url = paths.wineLog
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let stamp = ISO8601DateFormatter().string(from: Date())
        try handle.write(contentsOf: Data("\n===== \(stamp) NWS silent install =====\n".utf8))
        return handle
    }
}

public enum NWSProgress: Sendable {
    case downloading(fraction: Double) // 0...1; -1 when total size unknown
    case installing
    case verifying
}

public enum NWSError: Error, LocalizedError {
    case network(String)
    case rateLimited
    case noAsset(String)
    case parseFailed(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case installFailed(status: Int32, detail: String)

    public var errorDescription: String? {
        switch self {
        case .network(let detail):
            return "Couldn't reach the New World Scheduler download service (\(detail)). "
                + "Check your internet connection and try again."
        case .rateLimited:
            return "GitHub is temporarily limiting downloads from this network. "
                + "OpenXE will try the vendor's own download link instead."
        case .noAsset(let tag):
            return "The New World Scheduler release \(tag) has no installer to download."
        case .parseFailed(let detail):
            return "Couldn't read the New World Scheduler release information (\(detail))."
        case .sizeMismatch(let expected, let actual):
            return "The downloaded installer is the wrong size (expected \(expected) bytes, "
                + "got \(actual)). The download may have been interrupted — please try again."
        case .installFailed(let status, let detail):
            return "The New World Scheduler installer did not finish (code \(status)): \(detail)"
        }
    }
}

/// URLSession download-progress bridge for the installer fetch.
private final class NWSDownloadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: @Sendable (NWSProgress) -> Void
    init(progress: @escaping @Sendable (NWSProgress) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else {
            progress(.downloading(fraction: -1)); return
        }
        progress(.downloading(fraction: Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }
}

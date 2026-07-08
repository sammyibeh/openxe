import XCTest
@testable import OpenXECore

/// Spec §4.7. The parse fixtures below mirror the EXACT shape returned by the
/// live GitHub API on 2026-07-08 (captured read-only from
/// `…/releases/latest` and `…/releases?per_page=100`). A gated live test
/// (`OPENXE_NWS_LIVE=1`) re-confirms the shape against the real endpoint.
final class NWSInstallerTests: XCTestCase {

    // Real `releases/latest` shape (fields OpenXE reads), verified live 2026-07-08.
    private let latestFixture = """
    {
      "tag_name": "8.2.1460",
      "name": "NW Scheduler v8.2 Build #1460",
      "draft": false,
      "prerelease": false,
      "assets": [
        {
          "name": "NWS-Desktop-Setup_8.2_1460.exe",
          "size": 50109120,
          "browser_download_url": "https://github.com/NWScheduler/New-World-Scheduler/releases/download/8.2.1460/NWS-Desktop-Setup_8.2_1460.exe"
        }
      ]
    }
    """

    // Real `releases?per_page=100` shape (truncated to a few entries).
    private let releasesFixture = """
    [
      { "tag_name": "8.2.1460", "name": "NW Scheduler v8.2 Build #1460", "draft": false, "prerelease": false,
        "assets": [ { "name": "NWS-Desktop-Setup_8.2_1460.exe", "size": 50109120,
          "browser_download_url": "https://github.com/NWScheduler/New-World-Scheduler/releases/download/8.2.1460/NWS-Desktop-Setup_8.2_1460.exe" } ] },
      { "tag_name": "8.2.1459", "name": "NW Scheduler v8.2 Build #1459", "draft": false, "prerelease": false,
        "assets": [ { "name": "NWS-Desktop-Setup_8.2_1459.exe", "size": 50086760,
          "browser_download_url": "https://github.com/NWScheduler/New-World-Scheduler/releases/download/8.2.1459/NWS-Desktop-Setup_8.2_1459.exe" } ] },
      { "tag_name": "8.1.1458", "name": "NW Scheduler v8.1 Build #1458", "draft": false, "prerelease": false,
        "assets": [ { "name": "NWS-Desktop-Setup_8.1_1458.exe", "size": 54182400,
          "browser_download_url": "https://github.com/NWScheduler/New-World-Scheduler/releases/download/8.1.1458/NWS-Desktop-Setup_8.1_1458.exe" } ] },
      { "tag_name": "8.1.0-beta", "name": "beta", "draft": false, "prerelease": true, "assets": [] }
    ]
    """

    func testParseLatestMatchesLiveShape() throws {
        let r = try NWSInstaller.parseLatest(Data(latestFixture.utf8))
        XCTAssertEqual(r.tag, "8.2.1460")
        XCTAssertEqual(r.name, "NW Scheduler v8.2 Build #1460")
        XCTAssertEqual(r.assetName, "NWS-Desktop-Setup_8.2_1460.exe")
        XCTAssertEqual(r.size, 50109120)
        XCTAssertEqual(r.downloadURL.absoluteString,
            "https://github.com/NWScheduler/New-World-Scheduler/releases/download/8.2.1460/NWS-Desktop-Setup_8.2_1460.exe")
    }

    func testDisplayLabelRoundsToMegabytes() throws {
        let r = try NWSInstaller.parseLatest(Data(latestFixture.utf8))
        XCTAssertEqual(r.displayLabel, "8.2.1460 (~48 MB)") // 50109120 / 1048576 ≈ 47.8
    }

    func testParseReleasesNewestFirstAndSkipsPrerelease() throws {
        let list = try NWSInstaller.parseReleases(Data(releasesFixture.utf8))
        XCTAssertEqual(list.map(\.tag), ["8.2.1460", "8.2.1459", "8.1.1458"]) // beta dropped
        XCTAssertEqual(list[0].size, 50109120)
        XCTAssertEqual(list[2].assetName, "NWS-Desktop-Setup_8.1_1458.exe")
    }

    /// Spec §4.7 pinning: reconstruct the official asset URL from a tag alone,
    /// with no API round-trip. Must equal the URL the API actually serves.
    func testPinnedDownloadURLMatchesAPIURL() throws {
        let url = NWSInstaller.pinnedDownloadURL(tag: "8.2.1460")
        XCTAssertEqual(url?.absoluteString,
            "https://github.com/NWScheduler/New-World-Scheduler/releases/download/8.2.1460/NWS-Desktop-Setup_8.2_1460.exe")
        // And an older build.
        XCTAssertEqual(NWSInstaller.pinnedDownloadURL(tag: "8.1.1458")?.absoluteString,
            "https://github.com/NWScheduler/New-World-Scheduler/releases/download/8.1.1458/NWS-Desktop-Setup_8.1_1458.exe")
    }

    func testPinnedDownloadURLRejectsMalformedTag() {
        XCTAssertNil(NWSInstaller.pinnedDownloadURL(tag: "8"))
        XCTAssertNil(NWSInstaller.pinnedDownloadURL(tag: ""))
        XCTAssertNil(NWSInstaller.pinnedDownloadURL(tag: "8.2."))
    }

    /// Spec §4.7: the exact Inno silent-install command.
    func testInnoSilentArguments() {
        let args = NWSInstaller.innoSilentArguments(installerPath: "/tmp/NWS-Desktop-Setup_8.2_1460.exe")
        XCTAssertEqual(args, ["/tmp/NWS-Desktop-Setup_8.2_1460.exe",
                              "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"])
    }

    /// Asset selection prefers the NWS-Desktop-Setup exe even when other assets
    /// are present and ordered ahead of it.
    func testSetupAssetSelectionPrefersNWSExe() throws {
        let json = """
        { "tag_name": "9.0.1", "name": "n", "draft": false, "prerelease": false, "assets": [
          { "name": "release-notes.txt", "size": 10, "browser_download_url": "https://example.invalid/notes.txt" },
          { "name": "NWS-Desktop-Setup_9.0_1.exe", "size": 12345, "browser_download_url": "https://example.invalid/NWS-Desktop-Setup_9.0_1.exe" }
        ] }
        """
        let r = try NWSInstaller.parseLatest(Data(json.utf8))
        XCTAssertEqual(r.assetName, "NWS-Desktop-Setup_9.0_1.exe")
        XCTAssertEqual(r.size, 12345)
    }

    func testInstalledExeDetectionAcrossProgramFilesVariants() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("openxe-nws-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let installer = NWSInstaller(paths: OpenXEPaths(root: root))
        XCTAssertNil(installer.installedExe)
        XCTAssertFalse(installer.isInstalled)

        // Simulate a 32-bit install under "Program Files (x86)".
        let dir = root.appendingPathComponent(
            "prefix/drive_c/Program Files (x86)/New World Scheduler")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appendingPathComponent("NWS Desktop.exe")
        fm.createFile(atPath: exe.path, contents: Data("MZ".utf8))
        XCTAssertEqual(installer.installedExe?.path, exe.path)
        XCTAssertTrue(installer.isInstalled)
    }

    func testReleaseCodableRoundTrip() throws {
        let r = try NWSInstaller.parseLatest(Data(latestFixture.utf8))
        let back = try JSONDecoder().decode(NWSInstaller.Release.self,
                                            from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
    }

    /// Gated real end-to-end (spec §4.7): against the user's already-installed
    /// engine + prefix, fetch the latest release, download the real ~50 MB
    /// installer, verify its byte size against the API, run the silent Inno
    /// install, confirm `NWS Desktop.exe` landed, and launch it. Reinstalling the
    /// same latest build over an existing install is safe and non-destructive
    /// (it never wipes the prefix). Run with `OPENXE_NWS_E2E=1`.
    func testFullDownloadInstallLaunch() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENXE_NWS_E2E"] == "1",
                          "set OPENXE_NWS_E2E=1 to run the full NWS download+install e2e")
        let paths = OpenXEPaths.standard
        let engine = EngineManager(paths: paths)
        let prefixManager = PrefixManager(paths: paths)
        try XCTSkipUnless(engine.isActiveInstalled && prefixManager.isReady,
                          "engine + prefix must already be set up for this e2e")

        let installer = NWSInstaller(paths: paths)
        let latest = try await installer.fetchLatest()
        print("e2e: latest \(latest.tag) size \(latest.size)")

        // Download + size verification (download() throws sizeMismatch otherwise).
        let file = try await installer.download(latest) { p in
            if case .downloading(let f) = p, f >= 0, Int(f * 100) % 25 == 0 {
                print("e2e: download \(Int(f * 100))%")
            }
        }
        let onDisk = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64)
        XCTAssertEqual(onDisk, latest.size, "downloaded size must match the API size")

        // Silent install, then verify the exe landed.
        try await installer.install(installerAt: file) { _ in }
        let exe = try XCTUnwrap(installer.installedExe, "NWS Desktop.exe must exist after install")
        XCTAssertEqual(exe.lastPathComponent, "NWS Desktop.exe")
        print("e2e: installed at \(exe.path)")
        installer.cleanupDownloads()
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.downloadDirectory.path),
                       "downloaded installer must be cleaned up (never cached/committed)")

        // Launch it through the shipping Runner.
        let runner = Runner(paths: paths)
        let outcome = try runner.launch(exe: exe)
        if case .launched(let pid) = outcome {
            print("e2e: launched pid \(pid)")
        } else {
            XCTFail("NWS did not launch: \(outcome)")
        }
        runner.shutdownWineserver()
    }

    /// Gated live check (read-only, public API, ~1 request). Confirms the parse
    /// still matches the real endpoint shape. Run with `OPENXE_NWS_LIVE=1`.
    func testLiveLatestParses() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENXE_NWS_LIVE"] == "1",
                          "set OPENXE_NWS_LIVE=1 to hit the live GitHub API")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openxe-nws-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = NWSInstaller(paths: OpenXEPaths(root: root))
        let latest = try await installer.fetchLatest()
        XCTAssertTrue(latest.assetName.lowercased().hasPrefix("nws-desktop-setup"))
        XCTAssertTrue(latest.assetName.lowercased().hasSuffix(".exe"))
        XCTAssertGreaterThan(latest.size, 1_000_000)
        XCTAssertEqual(latest.downloadURL.absoluteString,
                       NWSInstaller.pinnedDownloadURL(tag: latest.tag)?.absoluteString)
    }
}

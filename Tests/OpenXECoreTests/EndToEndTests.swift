import XCTest
@testable import OpenXECore

/// Spec §7: the one integration test. Gated behind OPENXE_E2E=1 because it
/// downloads the real ~185 MB engine, builds the real prefix, and runs a
/// genuine PE binary (the engine's own cmd.exe) end to end.
///
/// Run: OPENXE_E2E=1 swift test --filter EndToEndTests
final class EndToEndTests: XCTestCase {

    func testEngineDownloadPrefixBootAndRunTinyExe() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENXE_E2E"] == "1",
                          "set OPENXE_E2E=1 to run the full end-to-end test")

        let paths = OpenXEPaths.standard

        // 1. Engine: ensure the default (stock) engine is installed and active.
        let engine = EngineManager(paths: paths)
        try await engine.ensureDefaultActive { progress in
            if case .downloading(let fraction) = progress, fraction > 0,
               Int(fraction * 100) % 25 == 0 {
                print("download \(Int(fraction * 100))%")
            }
        }
        XCTAssertTrue(engine.isActiveInstalled)
        XCTAssertEqual(engine.activeEngineID, EngineCatalog.stock.id)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: engine.activeWineBinary.path))
        XCTAssertEqual(engine.installedVersion, EngineCatalog.stock.version)

        // 2. Prefix: boot once, verify Mono + Gecko, Retina keys, folder symlinks.
        let prefixManager = PrefixManager(paths: paths)
        try prefixManager.ensurePrefix()
        XCTAssertTrue(prefixManager.isReady)
        let fm = FileManager.default
        let driveC = paths.prefix.appendingPathComponent("drive_c")
        // Shared Mono/Gecko: Mono registers into the prefix registry; Gecko
        // appears under system32. (Neither is copied to windows/mono.)
        let systemReg = try String(contentsOf: paths.prefix.appendingPathComponent("system.reg"),
                                   encoding: .utf8)
        XCTAssertTrue(systemReg.contains("Wine Mono"))
        XCTAssertTrue(fm.fileExists(atPath: driveC.appendingPathComponent("windows/system32/gecko").path))
        let docs = driveC.appendingPathComponent("users/\(NSUserName())/Documents")
        let dest = try? fm.destinationOfSymbolicLink(atPath: docs.path)
        XCTAssertEqual(dest, (NSHomeDirectory() as NSString).appendingPathComponent("Documents"))

        // 3. Run a tiny known .exe end-to-end and assert on its output.
        let runner = Runner(paths: paths)
        let output = try runner.runCapturingOutput(arguments: ["cmd", "/c", "echo openxe-e2e-ok"],
                                                   timeout: 120)
        XCTAssertTrue(output.contains("openxe-e2e-ok"), "wine cmd output was: \(output)")

        // 4. Launcher generation (spec §9.3) against a real Wine-shipped PE,
        //    into a temporary directory so /Applications stays untouched.
        let notepad = paths.engineCurrent
            .appendingPathComponent("wine/lib/wine/x86_64-windows/notepad.exe")
        XCTAssertTrue(fm.fileExists(atPath: notepad.path), "engine should ship notepad.exe")

        let launcherDir = fm.temporaryDirectory
            .appendingPathComponent("openxe-launchers-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: launcherDir) }
        let launchers = LauncherManager(baseDirectory: launcherDir)

        XCTAssertFalse(launchers.launcherExists(for: notepad))
        let bundle = try launchers.createLauncher(for: notepad, fallbackIcon: nil)
        XCTAssertTrue(launchers.launcherExists(for: notepad))

        // Bundle structure + target path.
        let plistData = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: plistData, format: nil)
            as? [String: Any])
        XCTAssertEqual(plist[LauncherManager.targetPathKey] as? String, notepad.path)
        XCTAssertTrue(fm.isExecutableFile(atPath: bundle.appendingPathComponent("Contents/MacOS/launcher").path))

        // Icon extracted from the real exe's PE resources (no fallback given,
        // so its presence proves extraction worked on a real-world binary).
        XCTAssertTrue(fm.fileExists(atPath: bundle.appendingPathComponent("Contents/Resources/AppIcon.icns").path),
                      "icon extraction from notepad.exe should succeed")

        // Valid ad-hoc signature.
        let verify = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/codesign"),
                                        arguments: ["--verify", bundle.path], timeout: 30)
        XCTAssertEqual(verify.status, 0, "codesign --verify failed: \(verify.output)")

        // Cleanup path: removeAllLaunchers takes ours out again.
        XCTAssertEqual(launchers.removeAllLaunchers(), 1)
        XCTAssertFalse(launchers.launcherExists(for: notepad))
    }

    /// Multi-engine plumbing proof (spec §4.1): install a second, non-Gcenx
    /// engine from a local archive, activate it, confirm the per-engine wine
    /// loader name resolves, and drive it through Runner. Uses a CrossOver-
    /// derived test article (WhiskyWine, wine64 loader) in an isolated root so
    /// the user's real engine/prefix are untouched.
    ///
    /// Run: OPENXE_CW_ARCHIVE=/path/to/whiskywine.tar.gz \
    ///      OPENXE_CW_SHA256=<sha256> swift test --filter testMultiEnginePlumbing
    func testMultiEnginePlumbingWithLocalCrossOverArchive() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["OPENXE_CW_ARCHIVE"] != nil && env["OPENXE_CW_SHA256"] != nil,
            "set OPENXE_CW_ARCHIVE and OPENXE_CW_SHA256 to run the multi-engine plumbing test")
        let archivePath = env["OPENXE_CW_ARCHIVE"]!
        let sha = env["OPENXE_CW_SHA256"]!

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("openxe-plumbing-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let paths = OpenXEPaths(root: root)
        let engine = EngineManager(paths: paths)

        let cw = EngineDescriptor(
            id: "wine-crossover-testarticle",
            displayName: "Wine-Crossover (test article)",
            version: "whiskywine-0.2.3.3",
            url: URL(string: "file://\(archivePath)")!,
            sha256: sha,
            wineBinaryName: "wine64")

        // Install from local archive (no network). The first engine installed
        // is auto-activated, so it becomes current without an explicit switch.
        try engine.installLocalArchive(cw, archive: URL(fileURLWithPath: archivePath))
        XCTAssertEqual(engine.installedEngineIDs(), [cw.id])
        XCTAssertEqual(engine.activeEngineID, cw.id)
        XCTAssertFalse(try engine.setActive(cw.id)) // already active → no rebuild

        // The per-engine loader name resolves to wine64 (not the stock "wine").
        XCTAssertEqual(engine.activeWineBinary.lastPathComponent, "wine64")
        XCTAssertTrue(fm.isExecutableFile(atPath: engine.activeWineBinary.path))

        // Runner drives the CrossOver engine: `wine64 --version` proves Runner
        // resolved and executed *this* engine's loader (CrossOver-based
        // wine-7.x, distinct from the stock 11.0 build) with captured output —
        // deterministic, no prefix/console dependency.
        let runner = Runner(paths: paths)
        let version = try runner.runCapturingOutput(arguments: ["--version"], timeout: 60)
        XCTAssertTrue(version.contains("wine-7."), "active engine wine64 --version was: \(version)")

        // Prefix rebuild-on-engine-change: a prefix built for a different
        // engine must report not-ready under the CrossOver engine.
        try fm.createDirectory(at: paths.prefix, withIntermediateDirectories: true)
        try Data("engine=some-other-engine\n".utf8)
            .write(to: paths.prefix.appendingPathComponent(".openxe-ready"))
        XCTAssertFalse(PrefixManager(paths: paths).isReady,
                       "prefix from a different engine must force a rebuild")

        runner.shutdownWineserver()
    }
}

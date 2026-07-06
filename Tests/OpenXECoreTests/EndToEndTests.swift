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

        // 1. Engine: download (resumable), verify pinned SHA-256, unpack, swap in.
        let engine = EngineManager(paths: paths)
        if !engine.isInstalled {
            try await engine.install { progress in
                if case .downloading(let fraction) = progress, fraction > 0 {
                    // coarse progress trace for CI logs
                    if Int(fraction * 100) % 25 == 0 { print("download \(Int(fraction * 100))%") }
                }
            }
        }
        XCTAssertTrue(engine.isInstalled)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: paths.wineBinary.path))
        XCTAssertEqual(engine.installedVersion, EnginePin.current.version)

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
}

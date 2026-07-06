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
        XCTAssertTrue(fm.fileExists(atPath: driveC.appendingPathComponent("windows/mono").path))
        XCTAssertTrue(fm.fileExists(atPath: driveC.appendingPathComponent("windows/system32/gecko").path))
        let docs = driveC.appendingPathComponent("users/\(NSUserName())/Documents")
        let dest = try? fm.destinationOfSymbolicLink(atPath: docs.path)
        XCTAssertEqual(dest, (NSHomeDirectory() as NSString).appendingPathComponent("Documents"))

        // 3. Run a tiny known .exe end-to-end and assert on its output.
        let runner = Runner(paths: paths)
        let output = try runner.runCapturingOutput(arguments: ["cmd", "/c", "echo openxe-e2e-ok"],
                                                   timeout: 120)
        XCTAssertTrue(output.contains("openxe-e2e-ok"), "wine cmd output was: \(output)")
    }
}

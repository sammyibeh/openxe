import XCTest
@testable import OpenXECore

final class EnvironmentTests: XCTestCase {

    let engineCurrent = URL(fileURLWithPath: "/Users/x/Library/Application Support/OpenXE/engine/current")
    let prefix = URL(fileURLWithPath: "/Users/x/Library/Application Support/OpenXE/prefix")

    func testEnvironmentIsExactlyTheSpeccedSet() {
        let env = WineEnvironment.build(engineCurrent: engineCurrent, prefix: prefix)
        XCTAssertEqual(env, [
            "WINEPREFIX": "/Users/x/Library/Application Support/OpenXE/prefix",
            "PATH": "/Users/x/Library/Application Support/OpenXE/engine/current/wine/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "WINEDEBUG": "fixme-all",
            "DYLD_FALLBACK_LIBRARY_PATH": "/Users/x/Library/Application Support/OpenXE/engine/current/wine/lib:/usr/lib:/usr/local/lib",
        ])
    }

    func testEnvironmentExposesEngineLibForBundledFreetype() {
        // Regression guard for the 2026-07-07 font incident: the engine ships
        // libfreetype.6.dylib in wine/lib and win32u dlopens it by bare soname,
        // so wine/lib MUST be on the dyld fallback path or WPF apps FailFast.
        let env = WineEnvironment.build(engineCurrent: engineCurrent, prefix: prefix)
        let dyld = env["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
        XCTAssertTrue(dyld.hasPrefix(engineCurrent.appendingPathComponent("wine/lib").path + ":"),
                      "engine wine/lib must lead the dyld fallback path; got \(dyld)")
    }

    func testWineBinaryPathResolvesUnderEngineCurrent() {
        let paths = OpenXEPaths(root: URL(fileURLWithPath: "/Users/x/Library/Application Support/OpenXE"))
        XCTAssertEqual(paths.engineCurrent.path, "/Users/x/Library/Application Support/OpenXE/engine/current")
        XCTAssertEqual(paths.wineBinary.path, "/Users/x/Library/Application Support/OpenXE/engine/current/wine/bin/wine")
        XCTAssertEqual(paths.wineserverBinary.path, "/Users/x/Library/Application Support/OpenXE/engine/current/wine/bin/wineserver")
        XCTAssertEqual(paths.prefix.path, "/Users/x/Library/Application Support/OpenXE/prefix")
        XCTAssertEqual(paths.engineVersions.path, "/Users/x/Library/Application Support/OpenXE/engine")
    }

    func testDefaultPathsLiveInApplicationSupportAndLogs() {
        let paths = OpenXEPaths.standard
        XCTAssertTrue(paths.root.path.hasSuffix("/Library/Application Support/OpenXE"))
        XCTAssertTrue(paths.wineLog.path.hasSuffix("/Library/Logs/OpenXE/wine.log"))
    }
}

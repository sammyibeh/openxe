import XCTest
@testable import OpenXECore

final class EnvironmentTests: XCTestCase {

    let engineCurrent = URL(fileURLWithPath: "/Users/x/Library/Application Support/OpenXE/engine/current")
    let prefix = URL(fileURLWithPath: "/Users/x/Library/Application Support/OpenXE/prefix")

    func testEnvironmentIsExactlyTheSpeccedTriple() {
        let env = WineEnvironment.build(engineCurrent: engineCurrent, prefix: prefix)
        XCTAssertEqual(env, [
            "WINEPREFIX": "/Users/x/Library/Application Support/OpenXE/prefix",
            "PATH": "/Users/x/Library/Application Support/OpenXE/engine/current/wine/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "WINEDEBUG": "fixme-all",
        ])
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

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

    func testBuildLaunchWithNilConfigEqualsBaseEnvironment() {
        // A nil (or all-default) config must not perturb the load-bearing env.
        XCTAssertEqual(
            WineEnvironment.buildLaunch(engineCurrent: engineCurrent, prefix: prefix, config: nil),
            WineEnvironment.build(engineCurrent: engineCurrent, prefix: prefix))
    }

    func testBuildLaunchInjectsDllOverridesIntoLaunchedEnv() {
        let config = AppConfig(exePath: "/x/App.exe", windowsVersion: .win10,
                               dllOverrides: [.init(dll: "d3d11", mode: .nativeBuiltin),
                                              .init(dll: "dxgi", mode: .builtin)])
        let env = WineEnvironment.buildLaunch(engineCurrent: engineCurrent, prefix: prefix, config: config)
        XCTAssertEqual(env["WINEDLLOVERRIDES"], "d3d11=n,b;dxgi=b")
        // Base keys are preserved.
        XCTAssertEqual(env["WINEPREFIX"], prefix.path)
    }

    func testBuildLaunchExtraEnvCannotClobberLoadBearingKeys() {
        let config = AppConfig(exePath: "/x/App.exe",
                               environment: ["WINEPREFIX": "/evil", "MY_FLAG": "1"])
        let env = WineEnvironment.buildLaunch(engineCurrent: engineCurrent, prefix: prefix, config: config)
        XCTAssertEqual(env["WINEPREFIX"], prefix.path, "per-app env must not override WINEPREFIX")
        XCTAssertEqual(env["MY_FLAG"], "1")
    }

    func testFontProvisioningSubstitutionsCoverKnownGaps() {
        let map = Dictionary(uniqueKeysWithValues: FontProvisioning.substitutions.map { ($0.from, $0.to) })
        // WPF default + Office fonts macOS does not ship must have a substitute.
        for missing in ["Segoe UI", "Calibri", "Cambria", "Consolas", "Segoe MDL2 Assets"] {
            XCTAssertNotNil(map[missing], "\(missing) needs a fallback substitute")
        }
        // Targets must be macOS-registered faces (never map onto another gap).
        let gaps: Set<String> = ["Segoe UI", "Calibri", "Cambria", "Consolas",
                                 "Candara", "Corbel", "Constantia"]
        for (_, to) in FontProvisioning.substitutions {
            XCTAssertFalse(gaps.contains(to), "substitution target \(to) is itself unavailable on macOS")
        }
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

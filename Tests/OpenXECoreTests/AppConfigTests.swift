import XCTest
@testable import OpenXECore

final class AppConfigTests: XCTestCase {

    // MARK: Windows version mapping

    func testWindowsVersionWineValues() {
        XCTAssertNil(AppConfig.WindowsVersion.default.wineValue)
        XCTAssertEqual(AppConfig.WindowsVersion.winxp.wineValue, "winxp")
        XCTAssertEqual(AppConfig.WindowsVersion.win7.wineValue, "win7")
        XCTAssertEqual(AppConfig.WindowsVersion.win10.wineValue, "win10")
        XCTAssertEqual(AppConfig.WindowsVersion.win11.wineValue, "win11")
    }

    // MARK: DLL override string round-trip

    func testDLLOverridesStringFormatting() {
        let config = AppConfig(exePath: "/x/App.exe", dllOverrides: [
            .init(dll: "d3d11", mode: .nativeBuiltin),
            .init(dll: "dxgi", mode: .builtin),
            .init(dll: "winmm", mode: .disabled),
        ])
        XCTAssertEqual(config.dllOverridesString, "d3d11=n,b;dxgi=b;winmm=")
    }

    func testNoOverridesYieldsNilString() {
        XCTAssertNil(AppConfig(exePath: "/x/App.exe").dllOverridesString)
    }

    func testParseSemicolonSeparated() {
        let parsed = AppConfig.parseDLLOverrides("d3d11=n,b; dxgi=b ; winmm=")
        XCTAssertEqual(parsed, [
            .init(dll: "d3d11", mode: .nativeBuiltin),
            .init(dll: "dxgi", mode: .builtin),
            .init(dll: "winmm", mode: .disabled),
        ])
    }

    func testParseCommaSeparatedWithModeCommas() {
        // Commas both separate entries and appear inside n,b — parser must not
        // split "n,b" into two entries.
        let parsed = AppConfig.parseDLLOverrides("d3d11=n,b,dxgi=b")
        XCTAssertEqual(parsed, [
            .init(dll: "d3d11", mode: .nativeBuiltin),
            .init(dll: "dxgi", mode: .builtin),
        ])
    }

    func testParseRoundTripsWithFormatting() {
        let text = "d3d11=n,b;dxgi=b;winmm="
        let config = AppConfig(exePath: "/x/App.exe",
                               dllOverrides: AppConfig.parseDLLOverrides(text))
        XCTAssertEqual(config.dllOverridesString, text)
    }

    func testParseSkipsGarbage() {
        let parsed = AppConfig.parseDLLOverrides("=b; foo; d3d11=zzz; ok=n")
        XCTAssertEqual(parsed, [.init(dll: "ok", mode: .native)])
    }

    // MARK: AppDefaults key naming

    func testAppDefaultsNameIsExeFileName() {
        XCTAssertEqual(AppConfig(exePath: "/C/Program Files/NWS Desktop.exe").appDefaultsName,
                       "NWS Desktop.exe")
    }

    // MARK: store persistence

    func testStoreSaveLoadRemoveAndDefaultPruning() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("openxe-appcfg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = AppConfigStore(fileURL: tmp)

        XCTAssertNil(store.config(forExePath: "/x/App.exe"))

        let cfg = AppConfig(exePath: "/x/App.exe", windowsVersion: .win10,
                            dllOverrides: [.init(dll: "d3d11", mode: .native)])
        store.save(cfg)
        XCTAssertEqual(store.config(forExePath: "/x/App.exe"), cfg)
        XCTAssertEqual(store.allConfigs().count, 1)

        // Saving an all-default config removes the entry (no clutter).
        store.save(AppConfig(exePath: "/x/App.exe"))
        XCTAssertNil(store.config(forExePath: "/x/App.exe"))
        XCTAssertTrue(store.allConfigs().isEmpty)
    }

    func testConfigCodableRoundTrip() throws {
        let cfg = AppConfig(exePath: "/x/App.exe", windowsVersion: .win11,
                            dllOverrides: [.init(dll: "dxgi", mode: .builtinNative)],
                            environment: ["FOO": "bar"])
        let data = try JSONEncoder().encode(cfg)
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: data), cfg)
    }
}

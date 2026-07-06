import XCTest
@testable import OpenXECore

final class EngineManagerTests: XCTestCase {

    func testSHA256OfKnownData() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openxe-sha-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        // Well-known SHA-256 test vector for "abc".
        XCTAssertEqual(try FileHasher.sha256Hex(of: url),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testEnginePinIsTheVerifiedRelease() {
        let pin = EnginePin.current
        XCTAssertEqual(pin.version, "wine-stable-11.0_1")
        XCTAssertEqual(pin.url.absoluteString,
                       "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz")
        XCTAssertEqual(pin.sha256.count, 64)
        XCTAssertNotEqual(pin.sha256, String(repeating: "0", count: 64))
    }

    func testNotInstalledOnEmptyRoot() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openxe-engine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = EngineManager(paths: OpenXEPaths(root: root))
        XCTAssertFalse(engine.isInstalled)
        XCTAssertNil(engine.installedVersion)
    }
}

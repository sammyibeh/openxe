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

    /// Spec §4.1: the quarantine strip must be engine-agnostic. Some engine
    /// tarballs (e.g. CrossOver-derived builds) unpack read-only, where a bare
    /// `xattr -dr` fails silently — verified live during the WoW64 incident.
    func testStripQuarantineHandlesReadOnlyFiles() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("openxe-q-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let file = dir.appendingPathComponent("lib.dylib")
        try Data("fake dylib".utf8).write(to: file)
        try Subprocess.run(URL(fileURLWithPath: "/usr/bin/xattr"),
                           arguments: ["-w", "com.apple.quarantine", "0081;00000000;;", file.path],
                           timeout: 10)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: file.path) // read-only

        try EngineManager.stripQuarantine(at: dir)

        let check = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/xattr"),
                                       arguments: ["-l", file.path], timeout: 10)
        XCTAssertFalse(check.output.contains("com.apple.quarantine"),
                       "quarantine should be stripped even from read-only files: \(check.output)")
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

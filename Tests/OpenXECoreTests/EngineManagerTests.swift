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

    func testStockCatalogEntryIsTheVerifiedRelease() {
        let stock = EngineCatalog.stock
        XCTAssertEqual(stock.id, "gcenx-stable-11.0_1")
        XCTAssertEqual(stock.version, "wine-stable-11.0_1")
        XCTAssertEqual(stock.wineBinaryName, "wine")
        XCTAssertEqual(stock.url.absoluteString,
                       "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz")
        XCTAssertEqual(stock.sha256.count, 64)
        XCTAssertNotEqual(stock.sha256, String(repeating: "0", count: 64))
        XCTAssertEqual(EngineCatalog.default, stock)
    }

    func testDescriptorRoundTripsThroughJSON() throws {
        let d = EngineCatalog.stock
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(EngineDescriptor.self, from: data)
        XCTAssertEqual(back, d)
    }

    /// Spec §4.1: engine-agnostic layout discovery. A CrossOver-style archive
    /// nests the wine root at the top level with a `wine64` loader; a Gcenx
    /// archive nests it under `*.app/Contents/Resources/wine` with a `wine`
    /// loader. Both must be found.
    func testFindWineRootHandlesBothLayouts() throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("openxe-root-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }

        // Gcenx-style: Some.app/Contents/Resources/wine/bin/wine
        let gcenx = staging.appendingPathComponent("gcenx/Wine.app/Contents/Resources/wine/bin")
        try fm.createDirectory(at: gcenx, withIntermediateDirectories: true)
        let wineExe = gcenx.appendingPathComponent("wine")
        fm.createFile(atPath: wineExe.path, contents: Data("x".utf8),
                      attributes: [.posixPermissions: 0o755])
        let foundG = EngineManager.findWineRoot(in: staging.appendingPathComponent("gcenx"),
                                                binaryName: "wine")
        XCTAssertEqual(foundG?.lastPathComponent, "wine")

        // CrossOver-style: whiskywine-x.y/bin/wine64
        let cw = staging.appendingPathComponent("cw/whiskywine-0.2.3.3/bin")
        try fm.createDirectory(at: cw, withIntermediateDirectories: true)
        let wine64 = cw.appendingPathComponent("wine64")
        fm.createFile(atPath: wine64.path, contents: Data("x".utf8),
                      attributes: [.posixPermissions: 0o755])
        let foundC = EngineManager.findWineRoot(in: staging.appendingPathComponent("cw"),
                                                binaryName: "wine64")
        XCTAssertEqual(foundC?.lastPathComponent, "whiskywine-0.2.3.3")
    }

    /// Install two synthetic engines, switch active, and confirm setActive
    /// reports the change (which drives the prefix rebuild). Spec §4.1/§4.2.
    func testInstalledInventoryAndActiveSwitch() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("openxe-multi-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let paths = OpenXEPaths(root: root)
        let engine = EngineManager(paths: paths)

        for id in ["engine-a", "engine-b"] {
            let dir = paths.engineVersions.appendingPathComponent(id)
            let bin = dir.appendingPathComponent("wine/bin")
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            fm.createFile(atPath: bin.appendingPathComponent("wine").path,
                          contents: Data("x".utf8), attributes: [.posixPermissions: 0o755])
            let d = EngineDescriptor(id: id, displayName: id, version: id,
                                     url: URL(string: "https://example.invalid/\(id)")!,
                                     sha256: String(repeating: "a", count: 64), wineBinaryName: "wine")
            try JSONEncoder().encode(d).write(to: dir.appendingPathComponent("descriptor.json"))
        }

        XCTAssertEqual(engine.installedEngineIDs(), ["engine-a", "engine-b"])
        XCTAssertNil(engine.activeEngineID)

        XCTAssertTrue(try engine.setActive("engine-a"))          // first activation is a change
        XCTAssertEqual(engine.activeEngineID, "engine-a")
        XCTAssertFalse(try engine.setActive("engine-a"))         // no-op, no rebuild
        XCTAssertTrue(try engine.setActive("engine-b"))          // switch => rebuild signal
        XCTAssertEqual(engine.activeDescriptor?.id, "engine-b")

        XCTAssertThrowsError(try engine.setActive("engine-missing"))
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
        XCTAssertFalse(engine.isActiveInstalled)
        XCTAssertNil(engine.activeEngineID)
        XCTAssertNil(engine.installedVersion)
        XCTAssertTrue(engine.installedEngineIDs().isEmpty)
    }
}

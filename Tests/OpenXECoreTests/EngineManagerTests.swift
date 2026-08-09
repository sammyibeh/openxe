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

    /// Spec §10.1: descriptor.json is the atomic commit point. If it exists,
    /// the engine is fully installed AND de-quarantined. A kill before that
    /// must leave the engine reporting not-installed so it is re-extracted.
    func testDescriptorIsWrittenLastSoItActsAsTheCommitPoint() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("openxe-commit-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let paths = OpenXEPaths(root: root)
        let mgr = EngineManager(paths: paths)

        let engineDir = paths.engineVersions.appendingPathComponent("test-engine")
        let binDir = engineDir.appendingPathComponent("wine/bin")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        fm.createFile(atPath: binDir.appendingPathComponent("wine").path,
                      contents: Data("x".utf8), attributes: [.posixPermissions: 0o755])
        // Simulate the interrupted window: the binaries are still quarantined
        // because stripQuarantine had not run yet.
        try Subprocess.run(URL(fileURLWithPath: "/usr/bin/xattr"),
                           arguments: ["-w", "com.apple.quarantine",
                                       "0081;00000000;test;", binDir.appendingPathComponent("wine").path],
                           timeout: 10)
        // version marker present, descriptor.json absent = interrupted mid-commit
        try Data("test\n".utf8).write(to: engineDir.appendingPathComponent("version"))

        XCTAssertNil(mgr.descriptor(forInstalledID: "test-engine"),
                     "a version file without descriptor.json must NOT look installed")
        XCTAssertFalse(mgr.isInstalled("test-engine"))
    }

    /// The legacy backfill still has to work for the case it exists for: a
    /// pre-multi-engine install that was fully committed and de-quarantined.
    func testLegacyBackfillStillHealsAFullyCommittedEngine() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("openxe-legacy-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let paths = OpenXEPaths(root: root)
        let mgr = EngineManager(paths: paths)

        let engineDir = paths.engineVersions.appendingPathComponent("gcenx-stable-11.0_1")
        let binDir = engineDir.appendingPathComponent("wine/bin")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        fm.createFile(atPath: binDir.appendingPathComponent("wine").path,
                      contents: Data("x".utf8), attributes: [.posixPermissions: 0o755])
        try Data("\(EngineCatalog.stock.version)\n".utf8)
            .write(to: engineDir.appendingPathComponent("version"))

        let healed = try XCTUnwrap(mgr.descriptor(forInstalledID: "gcenx-stable-11.0_1"))
        XCTAssertEqual(healed.version, EngineCatalog.stock.version)
        XCTAssertTrue(fm.fileExists(atPath: engineDir.appendingPathComponent("descriptor.json").path),
                      "the backfill must persist what it synthesised")
    }

    /// Measured via `tar -tf`, not estimated: 5,333 entries in the archive whose
    /// SHA-256 matched `EngineCatalog.stock.sha256` on 2026-08-09. The installed
    /// tree is 5,324 entries and is a strict subset of it. Re-derive only if the
    /// engine is repinned.
    func testExpectedArchiveEntriesWasMeasured() {
        XCTAssertEqual(EngineManager.expectedArchiveEntries, 5_333)
        XCTAssertGreaterThan(EngineManager.expectedArchiveEntries, 5_324,
                             "must be the measured archive count, not the installed-tree count")
    }

    // MARK: setup.log instrumentation (instrumentation spec §3.3)

    /// A minimal Gcenx-shaped engine archive, built locally. No network.
    /// Returns the archive URL and its real SHA-256.
    private func makeEngineArchive(in dir: URL) throws -> (URL, String) {
        let fm = FileManager.default
        let staging = dir.appendingPathComponent("src")
        let bin = staging.appendingPathComponent("Wine.app/Contents/Resources/wine/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        fm.createFile(atPath: bin.appendingPathComponent("wine").path,
                      contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let archive = dir.appendingPathComponent("engine.tar.gz")
        let tar = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/tar"),
                                     arguments: ["-czf", archive.path, "-C", staging.path, "."],
                                     timeout: 60)
        XCTAssertEqual(tar.status, 0, "fixture tar failed: \(tar.output)")
        return (archive, try FileHasher.sha256Hex(of: archive))
    }

    /// The one stage bracket that is fully exercisable offline. `unpackEngine`
    /// wraps `extractAndInstall`, which the network `install()` path shares, and
    /// the verify note is what lets the calibration split stage 2.
    func testUnpackEngineStageIsBracketedInTheSetupLog() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("openxe-unpacklog-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let (archive, sha) = try makeEngineArchive(in: dir)
        let paths = OpenXEPaths(root: dir.appendingPathComponent("root"))
        let logURL = dir.appendingPathComponent("setup.log")
        let log = try SetupLog(url: logURL)
        let descriptor = EngineDescriptor(id: "fixture-engine", displayName: "Fixture",
                                          version: "fixture-1", url: URL(string: "file://\(archive.path)")!,
                                          sha256: sha, wineBinaryName: "wine")

        try EngineManager(paths: paths).installLocalArchive(descriptor, archive: archive, log: log)
        log.close()

        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(text.contains("stage unpackEngine begin (attempt 1)"), text)
        XCTAssertTrue(text.contains("stage unpackEngine end"), text)
        XCTAssertTrue(text.contains("engine archive sha256 verified in"), text)
    }

    /// A checksum failure is a stage-2 failure: the unpack stage never opens, so
    /// a reader of setup.log cannot mistake it for one that started and hung.
    func testChecksumMismatchOpensNoUnpackStage() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("openxe-unpackbad-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let (archive, _) = try makeEngineArchive(in: dir)
        let paths = OpenXEPaths(root: dir.appendingPathComponent("root"))
        let logURL = dir.appendingPathComponent("setup.log")
        let log = try SetupLog(url: logURL)
        let descriptor = EngineDescriptor(id: "fixture-engine", displayName: "Fixture",
                                          version: "fixture-1", url: URL(string: "file://\(archive.path)")!,
                                          sha256: String(repeating: "b", count: 64), wineBinaryName: "wine")

        XCTAssertThrowsError(try EngineManager(paths: paths)
            .installLocalArchive(descriptor, archive: archive, log: log))
        log.close()

        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(text.contains("stage unpackEngine"), text)
        XCTAssertTrue(text.contains("checksum mismatch"), text)
    }
}

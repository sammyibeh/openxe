import XCTest
@testable import OpenXECore

final class WineServerHousekeepingTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("openxe-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // Wine derives the per-prefix server dir from the WINEPREFIX's dev/inode in
    // hex. Anchored to a live-observed value (2026-07-20) so the format can't
    // silently drift and mis-scope the sweep. dev 0x1000011, ino 0x57ed7b9.
    func testServerDirNameMatchesWineFormat() {
        XCTAssertEqual(
            WineServerHousekeeping.serverDirName(dev: 16_777_233, ino: 92_198_841),
            "server-1000011-57ed7b9")
    }

    // The socket dir is /tmp/.wine-<uid>/server-<dev>-<ino> for the prefix.
    func testServerDirPathIsPrefixScoped() throws {
        let dir = try XCTUnwrap(
            WineServerHousekeeping.serverDir(forPrefix: scratch, uid: 501))
        XCTAssertEqual(dir.deletingLastPathComponent().path, "/tmp/.wine-501")
        XCTAssertTrue(dir.lastPathComponent.hasPrefix("server-"))
    }

    func testServerDirNilForMissingPrefix() {
        let missing = scratch.appendingPathComponent("does-not-exist")
        XCTAssertNil(WineServerHousekeeping.serverDir(forPrefix: missing, uid: 501))
    }

    // Stale = the decayed husk that breaks the next launch: lock present, socket
    // reaped.
    func testStaleWhenLockWithoutSocket() throws {
        let dir = scratch.appendingPathComponent("server-x")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("lock"))
        XCTAssertTrue(WineServerHousekeeping.isStale(serverDir: dir))
    }

    func testHealthyWhenSocketPresent() throws {
        let dir = scratch.appendingPathComponent("server-y")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("lock"))
        try Data().write(to: dir.appendingPathComponent("socket"))
        XCTAssertFalse(WineServerHousekeeping.isStale(serverDir: dir))
    }

    func testNotStaleWhenDirMissingOrNoLock() throws {
        let missing = scratch.appendingPathComponent("nope")
        XCTAssertFalse(WineServerHousekeeping.isStale(serverDir: missing))

        let empty = scratch.appendingPathComponent("server-empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertFalse(WineServerHousekeeping.isStale(serverDir: empty))
    }

    // Full sweep against a simulated prefix: a stale server dir (lock, no socket)
    // and no live wineserver holding it is removed; the sweep reports it acted.
    func testSweepRemovesStaleServerDir() throws {
        let dir = try XCTUnwrap(WineServerHousekeeping.serverDir(forPrefix: scratch))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("lock"))
        defer { try? FileManager.default.removeItem(at: dir) }

        let acted = WineServerHousekeeping.sweepStaleServer(forPrefix: scratch)
        XCTAssertTrue(acted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    // A healthy server dir (lock + socket) is left untouched by the sweep.
    func testSweepLeavesHealthyServerDir() throws {
        let dir = try XCTUnwrap(WineServerHousekeeping.serverDir(forPrefix: scratch))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("lock"))
        try Data().write(to: dir.appendingPathComponent("socket"))
        defer { try? FileManager.default.removeItem(at: dir) }

        let acted = WineServerHousekeeping.sweepStaleServer(forPrefix: scratch)
        XCTAssertFalse(acted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }
}

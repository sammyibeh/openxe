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

    // MARK: v0.1.3 — detect by open WINEPREFIX handle (lsof -F pc parsing)

    // The parser pulls PIDs whose command begins with the prefix, out of the
    // field-mode records; a healthy real prefix's only holder is `wineserver`.
    func testParseLsofPIDsSelectsMatchingCommand() {
        // Two process records: a wineserver (truncated as lsof does) and an
        // unrelated process holding the same dir — only the wineserver matches.
        let output = """
        p17385
        cwineserve
        f4r
        n/Users/x/prefix
        p900
        cFinder
        f10
        n/Users/x/prefix
        """
        XCTAssertEqual(
            WineServerHousekeeping.parseLsofPIDs(output, commandPrefix: "wineserv"),
            [17385])
    }

    func testParseLsofPIDsDedupesAndHandlesEmpty() {
        XCTAssertEqual(WineServerHousekeeping.parseLsofPIDs("", commandPrefix: "wineserv"), [])
        // Same pid appearing once with a matching command is returned once.
        let output = "p42\ncwineserver\nf4r\np42\ncwineserver"
        XCTAssertEqual(WineServerHousekeeping.parseLsofPIDs(output, commandPrefix: "wineserv"), [42])
    }

    // Against a real scratch prefix with no wineserver, detection finds nothing
    // (exercises the real lsof path; deterministic in CI where no server runs).
    func testWineserverPIDsEmptyForIdlePrefix() {
        XCTAssertTrue(WineServerHousekeeping.wineserverPIDs(forPrefix: scratch).isEmpty)
    }

    // MARK: v0.1.3 — one-time upgrade reap marker logic

    func testUpgradeReapFiresOncePerBuildChange() {
        let marker = scratch.appendingPathComponent(".warm-server-build")

        // First run (no marker): fires and records the build. No wineserver is
        // bound to this scratch prefix, so the reap is a no-op but still fires.
        XCTAssertTrue(WineServerHousekeeping.upgradeReapIfNeeded(
            forPrefix: scratch, buildID: "build-A", markerURL: marker))
        XCTAssertEqual(
            try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            "build-A")

        // Same build again: no-op.
        XCTAssertFalse(WineServerHousekeeping.upgradeReapIfNeeded(
            forPrefix: scratch, buildID: "build-A", markerURL: marker))

        // New build: fires again and records the new id.
        XCTAssertTrue(WineServerHousekeeping.upgradeReapIfNeeded(
            forPrefix: scratch, buildID: "build-B", markerURL: marker))
        XCTAssertEqual(
            try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            "build-B")
    }

    // MARK: v0.1.3 — live proof: reap an orphan holding an UNLINKED server dir
    //
    // The regression v0.1.2 missed: a wineserver whose /tmp server dir has been
    // unlinked is invisible to a path-based lookup, yet it still holds the
    // prefix handle and squats the Mach name. Gated behind OPENXE_WINE_LIVE=1
    // (needs the real engine's wineserver); skipped in CI.
    func testLiveReapsOrphanHoldingUnlinkedServerDir() throws {
        let env = ProcessInfo.processInfo.environment
        let ws = OpenXEPaths.standard.wineserverBinary
        try XCTSkipUnless(env["OPENXE_WINE_LIVE"] == "1"
                          && FileManager.default.isExecutableFile(atPath: ws.path),
                          "set OPENXE_WINE_LIVE=1 with an installed engine to run the live reap test")

        let engineLib = OpenXEPaths.standard.engineCurrent.appendingPathComponent("wine/lib").path
        func startServer() throws {
            let p = Process()
            p.executableURL = ws
            p.arguments = ["-p60"]
            p.environment = ["WINEPREFIX": scratch.path,
                             "DYLD_FALLBACK_LIBRARY_PATH": "\(engineLib):/usr/lib:/usr/local/lib"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            usleep(1_500_000)
        }
        defer { WineServerHousekeeping.reapAllServers(forPrefix: scratch) }

        // Healthy server: detected, has a live socket, and the sweep leaves it.
        try startServer()
        let dir = try XCTUnwrap(WineServerHousekeeping.serverDir(forPrefix: scratch))
        XCTAssertFalse(WineServerHousekeeping.wineserverPIDs(forPrefix: scratch).isEmpty,
                       "a live wineserver must be found by its prefix handle")
        XCTAssertTrue(WineServerHousekeeping.hasLiveServerSocket(forPrefix: scratch),
                      "a healthy server binds a socket at its path")
        XCTAssertFalse(WineServerHousekeeping.sweepStaleServer(forPrefix: scratch),
                       "the sweep must leave a healthy, reachable server untouched")
        XCTAssertFalse(WineServerHousekeeping.wineserverPIDs(forPrefix: scratch).isEmpty)

        // Now unlink its server dir → the exact orphan shape: process alive,
        // socket gone from the path, path lookup blind, prefix handle intact.
        try? FileManager.default.removeItem(at: dir)
        XCTAssertFalse(WineServerHousekeeping.hasLiveServerSocket(forPrefix: scratch),
                       "socket must be gone from the path after unlink")
        XCTAssertFalse(WineServerHousekeeping.wineserverPIDs(forPrefix: scratch).isEmpty,
                       "prefix-handle detection must still find the orphan (path lookup can't)")

        // The enhanced sweep reaps the orphan a path-based sweep would have missed.
        XCTAssertTrue(WineServerHousekeeping.sweepStaleServer(forPrefix: scratch))
        usleep(800_000)
        XCTAssertTrue(WineServerHousekeeping.wineserverPIDs(forPrefix: scratch).isEmpty,
                      "the orphan must be gone after the sweep")
    }
}

import XCTest
@testable import OpenXECore

/// The join nobody was testing.
///
/// `ProgressiveDownloadTests` proves URLSession delivers byte counts.
/// `SetupDisplayTests` proves a fraction becomes a moving bar. Neither proves
/// the segment between them: that `EngineManager.download` and
/// `NWSInstaller.download` actually *forward* those counts onto their progress
/// channels. Delete the body of either `onCounts` closure and both existing
/// suites stay green while the user watches a dead bar — which is the exact
/// failure that shipped twice.
///
/// These tests run the real public entry points against a real socket and
/// assert `EngineProgress.downloading` / `NWSProgress.downloading` arrive with
/// rising fractions. They are slow by design (a paced transfer), because a
/// transfer that completes in one write cannot distinguish a working progress
/// channel from a silent one.
final class DownloadChainTests: XCTestCase {

    // MARK: helpers

    /// Fractions in arrival order, ignoring the `-1` unknown-total sentinel.
    private func assertFractionsRise(_ fractions: [Double],
                                     _ what: String,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        XCTAssertGreaterThan(fractions.count, 2,
                             "\(what) reported \(fractions.count) fractions. The bar is dead "
                             + "again — check the progress closure still forwards TransferCounts.",
                             file: file, line: line)
        XCTAssertEqual(fractions, fractions.sorted(), "\(what) rewound", file: file, line: line)
        XCTAssertGreaterThan(Set(fractions).count, 1,
                             "\(what) never changed value — the bar would not move.",
                             file: file, line: line)
        XCTAssertEqual(fractions.last ?? 0, 1.0, accuracy: 0.001, file: file, line: line)
    }

    /// Bytes gzip cannot shrink, so the archive on the wire keeps the size the
    /// fixture asked for. Seeded and deterministic: a flaky fixture size would
    /// make the chunk count — and so the callback count — non-reproducible.
    static func incompressible(_ count: Int) -> Data {
        var state: UInt64 = 0x9E3779B97F4A7C15
        var bytes = [UInt8](); bytes.reserveCapacity(count)
        while bytes.count < count {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            withUnsafeBytes(of: state.littleEndian) { bytes.append(contentsOf: $0) }
        }
        return Data(bytes[0..<count])
    }

    private func makeScratch(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openxe-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A Gcenx-shaped engine archive padded with incompressible bytes, so the
    /// body is large enough to arrive in many chunks. A 400-byte fixture would
    /// land in a single write and the test could not tell a live progress
    /// channel from a dead one.
    private func makeEngineArchive(in dir: URL, padding: Int) throws -> (URL, String) {
        let fm = FileManager.default
        let staging = dir.appendingPathComponent("src")
        let bin = staging.appendingPathComponent("Wine.app/Contents/Resources/wine/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        fm.createFile(atPath: bin.appendingPathComponent("wine").path,
                      contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        try Self.incompressible(padding)
            .write(to: staging.appendingPathComponent("Wine.app/Contents/Resources/wine/pad.bin"))

        let archive = dir.appendingPathComponent("engine.tar.gz")
        let tar = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/tar"),
                                     arguments: ["-czf", archive.path, "-C", staging.path, "."],
                                     timeout: 120)
        XCTAssertEqual(tar.status, 0, "fixture tar failed: \(tar.output)")
        return (archive, try FileHasher.sha256Hex(of: archive))
    }

    // MARK: stage 2 + 3 — EngineManager

    /// Runs the real `install()` over a real socket: transfer, checksum,
    /// unpack, activation. Asserts the download fractions genuinely arrive.
    func testEngineInstallStreamsRisingDownloadFractions() async throws {
        let dir = try makeScratch("engine-chain")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (archive, sha) = try makeEngineArchive(in: dir, padding: 1_500_000)
        let body = try Data(contentsOf: archive)
        XCTAssertGreaterThan(body.count, 1_000_000, "fixture archive compressed away")

        let server = try TestHTTPServer(body: body, chunkSize: 64 * 1024,
                                        microsecondsPerChunk: 1_000)
        defer { server.stop() }

        let descriptor = EngineDescriptor(id: "chain-engine", displayName: "Chain",
                                          version: "chain-1", url: server.url,
                                          sha256: sha, wineBinaryName: "wine")
        let manager = EngineManager(paths: OpenXEPaths(root: dir.appendingPathComponent("root")))
        let events = EngineEventBox()

        try await manager.install(descriptor) { events.append($0) }

        assertFractionsRise(events.downloadFractions, "EngineProgress.downloading")
        XCTAssertTrue(events.sawVerifying, "stage 2 never reported its checksum step")
        XCTAssertTrue(events.sawExtracting, "stage 3 never opened")
        XCTAssertFalse(events.unpackCounts.isEmpty,
                       "stage 3 published no entry counts — the unpack line would be frozen.")
        XCTAssertTrue(manager.isInstalled("chain-engine"))
    }

    /// A server that sends no Content-Length must surface as the `-1` sentinel
    /// all the way up, not as a fabricated 0 %. `SetupDisplay` turns that into
    /// an animated bar; a fake 0.0 would look identical to a frozen one.
    func testEngineDownloadWithoutContentLengthReportsTheUnknownSentinel() async throws {
        let dir = try makeScratch("engine-nolen")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (archive, sha) = try makeEngineArchive(in: dir, padding: 200_000)
        let server = try TestHTTPServer(body: try Data(contentsOf: archive),
                                        chunkSize: 32 * 1024,
                                        microsecondsPerChunk: 1_000,
                                        announceLength: false)
        defer { server.stop() }

        let descriptor = EngineDescriptor(id: "nolen-engine", displayName: "NoLen",
                                          version: "nolen-1", url: server.url,
                                          sha256: sha, wineBinaryName: "wine")
        let manager = EngineManager(paths: OpenXEPaths(root: dir.appendingPathComponent("root")))
        let events = EngineEventBox()

        try await manager.install(descriptor) { events.append($0) }

        XCTAssertFalse(events.rawDownloadValues.isEmpty, "no download events at all")
        XCTAssertTrue(events.rawDownloadValues.allSatisfy { $0 < 0 },
                      "an unknown total must stay the -1 sentinel, not become a fake 0 %.")
        XCTAssertEqual(SetupDisplay.engine(.downloading(fraction: -1)).bar, .indeterminate)
    }

    // MARK: stage 5 — NWSInstaller

    /// Same join, the other download site. `NWSInstaller.download` uses
    /// `counts.fraction` (no resume), so this pins a different line of code
    /// from the engine test above.
    func testNWSDownloadStreamsRisingFractions() async throws {
        let dir = try makeScratch("nws-chain")
        defer { try? FileManager.default.removeItem(at: dir) }

        // The size gate rejects anything under 1 MB, so the fixture must clear it.
        let body = Self.incompressible(1_400_000)
        let server = try TestHTTPServer(body: body, chunkSize: 64 * 1024,
                                        microsecondsPerChunk: 1_000)
        defer { server.stop() }

        let release = NWSInstaller.Release(tag: "0.0.0", name: "fixture",
                                           assetName: "NWS-Fixture-Setup.exe",
                                           downloadURL: server.url,
                                           size: Int64(body.count))
        let installer = NWSInstaller(paths: OpenXEPaths(root: dir.appendingPathComponent("root")))
        let events = NWSEventBox()

        let installerURL = try await installer.download(release) { events.append($0) }

        assertFractionsRise(events.downloadFractions, "NWSProgress.downloading")
        XCTAssertEqual(try Data(contentsOf: installerURL).count, body.count,
                       "the size gate passed but the bytes on disk are not the bytes served")
    }

    /// The size gate is part of stage 5, and a short body must fail it rather
    /// than handing a truncated installer to Wine.
    func testNWSDownloadRejectsAShortBody() async throws {
        let dir = try makeScratch("nws-short")
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try TestHTTPServer(body: Data(count: 4096), chunkSize: 1024,
                                        microsecondsPerChunk: 100)
        defer { server.stop() }

        let release = NWSInstaller.Release(tag: "0.0.0", name: "fixture",
                                           assetName: "NWS-Fixture-Setup.exe",
                                           downloadURL: server.url, size: 9_999_999)
        let installer = NWSInstaller(paths: OpenXEPaths(root: dir.appendingPathComponent("root")))
        do {
            _ = try await installer.download(release) { _ in }
            XCTFail("a truncated installer must not be accepted")
        } catch is NWSError {
            // expected
        }
    }
}

// MARK: - collectors

private final class EngineEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [EngineProgress] = []

    func append(_ e: EngineProgress) { lock.lock(); events.append(e); lock.unlock() }

    private var snapshot: [EngineProgress] {
        lock.lock(); defer { lock.unlock() }; return events
    }

    /// Raw values including the `-1` unknown-total sentinel.
    var rawDownloadValues: [Double] {
        snapshot.compactMap { if case .downloading(let f) = $0 { return f } else { return nil } }
    }
    var downloadFractions: [Double] { rawDownloadValues.filter { $0 >= 0 } }
    var unpackCounts: [Int] {
        snapshot.compactMap { if case .unpacking(let n) = $0 { return n } else { return nil } }
    }
    var sawVerifying: Bool { snapshot.contains { if case .verifying = $0 { return true } else { return false } } }
    var sawExtracting: Bool { snapshot.contains { if case .extracting = $0 { return true } else { return false } } }
}

private final class NWSEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [NWSProgress] = []

    func append(_ e: NWSProgress) { lock.lock(); events.append(e); lock.unlock() }

    private var snapshot: [NWSProgress] {
        lock.lock(); defer { lock.unlock() }; return events
    }
    var rawDownloadValues: [Double] {
        snapshot.compactMap { if case .downloading(let f) = $0 { return f } else { return nil } }
    }
    var downloadFractions: [Double] { rawDownloadValues.filter { $0 >= 0 } }
}

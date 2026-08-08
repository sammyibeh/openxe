import XCTest
@testable import OpenXECore

final class SetupLogTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openxe-setuplog-\(UUID().uuidString)/setup.log")
    }

    func testWritesRunAndStageMarkers() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let log = try SetupLog(url: url)
        log.beginRun(buildID: "OpenXE-123-456", engineID: "gcenx-stable-11.0_1",
                     freeBytes: 12_000_000_000)
        log.beginStage(.preparePrefix, attempt: 2)
        log.note("Registering fonts (23 of 57)")
        log.endStage(.preparePrefix, elapsed: 59.4)
        log.close()

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("OpenXE-123-456"))
        XCTAssertTrue(text.contains("gcenx-stable-11.0_1"))
        XCTAssertTrue(text.contains("preparePrefix"))
        XCTAssertTrue(text.contains("attempt 2"))
        XCTAssertTrue(text.contains("Registering fonts (23 of 57)"))
        XCTAssertTrue(text.contains("59.4"))
    }

    func testTailReturnsLastLines() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try SetupLog(url: url)
        for i in 1...100 { log.note("line \(i)") }
        log.close()

        let tail = SetupLog.tail(of: url, lines: 3)
        XCTAssertTrue(tail.contains("line 100"))
        XCTAssertTrue(tail.contains("line 98"))
        XCTAssertFalse(tail.contains("line 97"))
    }

    func testTailOnMissingFileIsSafe() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("openxe-absent-\(UUID().uuidString).log")
        XCTAssertEqual(SetupLog.tail(of: missing, lines: 5), "(no setup log yet)")
    }

    /// Spec §4.4: rotate at 5 MB, keep one generation.
    func testRotationMovesOldLogAside() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // 6 MB of filler, over the 5 MB threshold.
        try Data(repeating: 0x41, count: 6 << 20).write(to: url)

        let log = try SetupLog(url: url)
        log.note("after rotation")
        log.close()

        let rotated = url.deletingLastPathComponent().appendingPathComponent("setup.log.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("after rotation"))
        XCTAssertLessThan(text.count, 1 << 20, "fresh log should not carry the old body")
    }
}

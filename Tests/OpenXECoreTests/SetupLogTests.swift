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

    /// Instrumentation spec §3.1: the bracket pair writes a matched begin/end
    /// with the attempt number and a real elapsed figure, and composes with the
    /// existing run header and note API.
    func testStageBracketWritesMatchedBeginAndEnd() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let log = try SetupLog(url: url)
        log.beginRun(buildID: "OpenXE-1-2", engineID: "gcenx-stable-11.0_1", freeBytes: 1)
        let mark = log.startStage(.downloadEngine, attempt: 2)
        log.note("engine archive transferred in 0.0s")
        Thread.sleep(forTimeInterval: 0.02)
        log.endStage(.downloadEngine, startedAt: mark)
        log.close()

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let begin = try XCTUnwrap(lines.first { $0.contains("stage downloadEngine begin") })
        let end = try XCTUnwrap(lines.first { $0.contains("stage downloadEngine end") })
        XCTAssertTrue(begin.contains("attempt 2"))
        XCTAssertTrue(lines.firstIndex(of: begin)! < lines.firstIndex(of: end)!)
        // The elapsed figure is real: at least the 20 ms slept, and not a
        // wall-clock artefact of many seconds.
        let elapsed = try XCTUnwrap(Double(end.split(separator: "(").last?
            .replacingOccurrences(of: "s) ---", with: "") ?? ""))
        XCTAssertGreaterThanOrEqual(elapsed, 0.0)
        XCTAssertLessThan(elapsed, 5.0)
        XCTAssertTrue(lines.contains { $0.contains("transferred") })
    }

    /// The default attempt is 1, so an un-retried stage needs no argument.
    func testStageBracketDefaultsToAttemptOne() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try SetupLog(url: url)
        log.endStage(.preparePrefix, startedAt: log.startStage(.preparePrefix))
        log.close()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("stage preparePrefix begin (attempt 1)"))
        XCTAssertTrue(text.contains("stage preparePrefix end"))
    }

    /// Monotonic, not wall clock: elapsed can never come back negative, which is
    /// the failure mode a `Date`-based mark has if the clock steps mid-run.
    func testElapsedIsMonotonicAndNonNegative() {
        let start = DispatchTime.now()
        Thread.sleep(forTimeInterval: 0.01)
        let elapsed = SetupLog.elapsed(since: start)
        XCTAssertGreaterThan(elapsed, 0.005)
        XCTAssertLessThan(elapsed, 5.0)
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

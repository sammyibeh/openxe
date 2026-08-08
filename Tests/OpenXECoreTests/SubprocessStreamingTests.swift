import XCTest
@testable import OpenXECore

final class SubprocessStreamingTests: XCTestCase {

    func testOnLineReceivesEachLineAsItArrives() throws {
        let lock = NSLock()
        nonisolated(unsafe) var lines: [String] = []
        _ = try Subprocess.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo alpha; echo beta; echo gamma"],
            timeout: 30,
            onLine: { line in lock.lock(); lines.append(line); lock.unlock() })

        lock.lock(); let got = lines; lock.unlock()
        XCTAssertEqual(got, ["alpha", "beta", "gamma"])
    }

    func testPartialLinesAreBufferedUntilNewline() throws {
        let lock = NSLock()
        nonisolated(unsafe) var lines: [String] = []
        _ = try Subprocess.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'one'; sleep 0.2; printf 'two\\n'"],
            timeout: 30,
            onLine: { line in lock.lock(); lines.append(line); lock.unlock() })

        lock.lock(); let got = lines; lock.unlock()
        XCTAssertEqual(got, ["onetwo"], "a split line must be reassembled, not emitted twice")
    }

    /// A final line with no terminating newline must still be delivered.
    func testUnterminatedFinalLineIsFlushed() throws {
        let lock = NSLock()
        nonisolated(unsafe) var lines: [String] = []
        _ = try Subprocess.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'alpha\\nomega'"],
            timeout: 30,
            onLine: { line in lock.lock(); lines.append(line); lock.unlock() })

        lock.lock(); let got = lines; lock.unlock()
        XCTAssertEqual(got, ["alpha", "omega"])
    }

    func testStillCapturesCombinedOutput() throws {
        let r = try Subprocess.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo out; echo err 1>&2"],
            timeout: 30)
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.output.contains("out"))
        XCTAssertTrue(r.output.contains("err"))
    }
}

import XCTest
@testable import OpenXECore

// The delegate tests that used to live here have been deleted, not moved.
//
// They asserted `responds(to:)` on `DownloadProgressDelegate` /
// `NWSDownloadDelegate` and then called `urlSession(_:downloadTask:didWriteData:…)`
// by hand. Every one of them passed against a build where URLSession never
// called the delegate at all, because `URLSession.download(for:delegate:)`
// delivers no incremental callbacks. A test that cannot fail when the user
// sees nothing move manufactures false confidence, so it is gone.
//
// Replacements, both real:
//   - `ProgressiveDownloadTests` runs a download over a real socket through a
//     real URLSession and asserts the fractions arrive and rise.
//   - `TransferCountsTests` covers the fraction arithmetic those tests were
//     nominally about.

/// Stage 3 published nothing because `ensureDefaultActive` never supplied an
/// `onEntry`, so `extractAndInstall`'s counter fed a nil closure. `install`
/// now synthesizes the reporter from the progress closure it already holds.
final class UnpackReporterTests: XCTestCase {

    private func drain(entries: Int) -> (events: [Int], forwarded: [Int]) {
        let events = CountBox(), forwarded = CountBox()
        let reporter = EngineManager.unpackReporter(
            forwarding: { n in forwarded.append(n) },
            to: { p in if case .unpacking(let n) = p { events.append(n) } })
        for n in 1...entries { reporter(n) }
        return (events.values, forwarded.values)
    }

    /// The defect this replaces: zero events for the whole unpack.
    func testUnpackPublishesProgressEvents() {
        XCTAssertFalse(drain(entries: 500).events.isEmpty,
                       "Stage 3 is silent again — the unpack bar will not move.")
    }

    /// A caller-supplied onEntry keeps every entry; only the UI channel throttles.
    func testCallerSuppliedOnEntryIsNotThrottled() {
        XCTAssertEqual(drain(entries: 500).forwarded.count, 500)
    }

    func testUnpackEventsAreThrottledAndMonotonic() {
        let events = drain(entries: 500).events
        // n == 1 plus every 25th entry.
        XCTAssertEqual(events.first, 1)
        XCTAssertEqual(events.count, 1 + 500 / EngineManager.unpackReportInterval)
        XCTAssertEqual(events, events.sorted(), "counts must never rewind")
        XCTAssertEqual(events.last, 500)
    }

    /// A tiny archive must still report once, not sit silent below the throttle.
    func testSmallArchiveStillReportsOnce() {
        XCTAssertEqual(drain(entries: 3).events, [1])
    }

    /// The count is never dressed up as a download fraction.
    func testUnpackDoesNotEmitDownloadEvents() {
        let reporter = EngineManager.unpackReporter(forwarding: nil, to: { p in
            if case .downloading = p { XCTFail("unpack must not emit a download fraction") }
        })
        for n in 1...100 { reporter(n) }
    }
}

private final class CountBox: @unchecked Sendable {
    private var storage: [Int] = []
    private let lock = NSLock()
    func append(_ n: Int) { lock.lock(); storage.append(n); lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return storage }
}

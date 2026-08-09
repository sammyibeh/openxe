import XCTest
@testable import OpenXECore

/// Pins the one defect the Swift type checker cannot see.
///
/// `URLSession` dispatches progress callbacks through
/// `respondsToSelector:`. Under SE-0160 a Swift method is only exposed to the
/// Objective-C runtime when it satisfies a requirement of an adopted `@objc`
/// protocol. Both progress delegates originally declared
/// `URLSessionTaskDelegate` while implementing `didWriteData`, which is a
/// `URLSessionDownloadDelegate` requirement — so the method compiled, looked
/// correct in review, and was never called. The bar sat at 0.0 for the entire
/// engine and NWS transfers.
///
/// These assertions fail if either the conformance is narrowed OR the `@objc`
/// exposure is lost by any other means, because both regressions land on the
/// same observable: `responds(to:)`.
final class ProgressDelegateTests: XCTestCase {

    /// The exact selector URLSession probes before reporting transfer progress.
    private static let didWriteData = NSSelectorFromString(
        "URLSession:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:")

    /// The selector that makes the download-delegate conformance legal. Note
    /// the trailing `URL:` — Foundation's ObjC name, not the Swift spelling.
    /// Verified against `class_copyMethodList`, not guessed.
    private static let didFinishDownloading = NSSelectorFromString(
        "URLSession:downloadTask:didFinishDownloadingToURL:")

    // MARK: engine archive delegate

    func testEngineDelegateExposesDidWriteDataToObjCRuntime() {
        let delegate = DownloadProgressDelegate(alreadyHave: 0, progress: { _ in })
        XCTAssertTrue(delegate.responds(to: Self.didWriteData),
                      "DownloadProgressDelegate no longer answers didWriteData through the "
                      + "Objective-C runtime — URLSession will silently never report engine "
                      + "download progress. Check it still conforms to URLSessionDownloadDelegate.")
        XCTAssertTrue(delegate.responds(to: Self.didFinishDownloading))
    }

    func testEngineDelegateAdoptsDownloadDelegateProtocol() {
        let delegate = DownloadProgressDelegate(alreadyHave: 0, progress: { _ in })
        XCTAssertTrue(delegate is URLSessionDownloadDelegate,
                      "URLSessionTaskDelegate alone does not expose didWriteData.")
        // Objective-C conformance, which is what URLSession's dispatch consults.
        XCTAssertTrue(delegate.conforms(to: URLSessionDownloadDelegate.self))
    }

    // MARK: NWS installer delegate

    func testNWSDelegateExposesDidWriteDataToObjCRuntime() {
        let delegate = NWSDownloadDelegate(progress: { _ in })
        XCTAssertTrue(delegate.responds(to: Self.didWriteData),
                      "NWSDownloadDelegate no longer answers didWriteData through the "
                      + "Objective-C runtime — the NWS download bar will pin at 0. "
                      + "Check it still conforms to URLSessionDownloadDelegate.")
        XCTAssertTrue(delegate.responds(to: Self.didFinishDownloading))
    }

    func testNWSDelegateAdoptsDownloadDelegateProtocol() {
        let delegate = NWSDownloadDelegate(progress: { _ in })
        XCTAssertTrue(delegate is URLSessionDownloadDelegate)
        XCTAssertTrue(delegate.conforms(to: URLSessionDownloadDelegate.self))
    }

    // MARK: the callbacks actually publish

    /// Guards the arithmetic as well as the plumbing: a resumed transfer must
    /// report its fraction against the *whole* file, not the remaining range.
    func testEngineDelegateReportsFractionIncludingResumedBytes() {
        let box = FractionBox()
        let delegate = DownloadProgressDelegate(alreadyHave: 50, progress: { p in
            if case .downloading(let f) = p { box.record(f) }
        })
        // 50 bytes already on disk, server sending the remaining 50.
        delegate.urlSession(URLSession.shared,
                            downloadTask: URLSession.shared.downloadTask(
                                with: URL(string: "https://example.invalid/x")!),
                            didWriteData: 25, totalBytesWritten: 25,
                            totalBytesExpectedToWrite: 50)
        XCTAssertEqual(box.last ?? -1, 0.75, accuracy: 0.0001)
    }

    /// Unknown total length must surface as indeterminate, never as a fake 0.
    func testEngineDelegateReportsIndeterminateWhenTotalUnknown() {
        let box = FractionBox()
        let delegate = DownloadProgressDelegate(alreadyHave: 0, progress: { p in
            if case .downloading(let f) = p { box.record(f) }
        })
        delegate.urlSession(URLSession.shared,
                            downloadTask: URLSession.shared.downloadTask(
                                with: URL(string: "https://example.invalid/x")!),
                            didWriteData: 10, totalBytesWritten: 10,
                            totalBytesExpectedToWrite: -1)
        XCTAssertEqual(box.last ?? 0, -1, accuracy: 0.0001)
    }

    func testNWSDelegateReportsFraction() {
        let box = FractionBox()
        let delegate = NWSDownloadDelegate(progress: { p in
            if case .downloading(let f) = p { box.record(f) }
        })
        delegate.urlSession(URLSession.shared,
                            downloadTask: URLSession.shared.downloadTask(
                                with: URL(string: "https://example.invalid/x")!),
                            didWriteData: 40, totalBytesWritten: 40,
                            totalBytesExpectedToWrite: 200)
        XCTAssertEqual(box.last ?? -1, 0.2, accuracy: 0.0001)
    }

    func testNWSDelegateReportsIndeterminateWhenTotalUnknown() {
        let box = FractionBox()
        let delegate = NWSDownloadDelegate(progress: { p in
            if case .downloading(let f) = p { box.record(f) }
        })
        delegate.urlSession(URLSession.shared,
                            downloadTask: URLSession.shared.downloadTask(
                                with: URL(string: "https://example.invalid/x")!),
                            didWriteData: 1, totalBytesWritten: 1,
                            totalBytesExpectedToWrite: 0)
        XCTAssertEqual(box.last ?? 0, -1, accuracy: 0.0001)
    }
}

/// Minimal thread-safe sink; the delegates take `@Sendable` closures.
private final class FractionBox: @unchecked Sendable {
    private var value: Double?
    private let lock = NSLock()
    func record(_ f: Double) { lock.lock(); value = f; lock.unlock() }
    var last: Double? { lock.lock(); defer { lock.unlock() }; return value }
}

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

    /// The count is never dressed up as a bar fraction: there is no denominator.
    func testUnpackCarriesNoFraction() {
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

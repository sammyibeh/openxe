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

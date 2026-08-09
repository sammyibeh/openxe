import XCTest
@testable import OpenXECore

/// The test that had to exist and did not.
///
/// `ProgressDelegateTests` asserted `responds(to:)` and then called the
/// delegate method by hand. Both assertions passed for a build in which
/// URLSession never called the delegate at all, because
/// `URLSession.download(for:delegate:)` does not deliver incremental
/// callbacks — on the shared session or on any other. A user watched a bar sit
/// still for 314 seconds while the suite was green.
///
/// These tests put real bytes through a real socket into a real `URLSession`
/// and assert the fractions arrive. They fail if the bar stops moving.
final class ProgressiveDownloadTests: XCTestCase {

    private func collect(from server: TestHTTPServer,
                         timeout: TimeInterval = 30) async throws
        -> (file: DownloadedFile, counts: [TransferCounts]) {
        let box = CountsBox()
        let file = try await ProgressiveDownload.fetch(URLRequest(url: server.url)) { counts in
            box.append(counts)
        }
        return (file, box.values)
    }

    // MARK: the regression itself

    /// Directly pins the defect: a paced 512 KB body must produce SEVERAL
    /// progress callbacks before completion, not zero and not one.
    func testDownloadReportsIncrementalProgress() async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }

        let (file, counts) = try await collect(from: server)
        defer { try? FileManager.default.removeItem(at: file.url) }

        XCTAssertGreaterThan(
            counts.count, 2,
            "The download reported \(counts.count) progress callbacks. The progress bar "
            + "is dead again — check ProgressiveDownload still uses a classic "
            + "downloadTask, not URLSession.download(for:delegate:).")

        let fractions = counts.compactMap(\.fraction)
        XCTAssertEqual(fractions.count, counts.count,
                       "A Content-Length response must yield a real fraction every time.")
        XCTAssertEqual(fractions, fractions.sorted(), "progress must never rewind")
        XCTAssertGreaterThan(Set(fractions).count, 1,
                             "The fraction never changed — the bar would not move.")
        XCTAssertEqual(fractions.last ?? 0, 1.0, accuracy: 0.0001)
    }

    /// The file has to survive the delegate's temp-file deletion window.
    func testDownloadDeliversTheCompleteFile() async throws {
        let server = try TestHTTPServer(totalBytes: 256 * 1024, chunkSize: 32 * 1024)
        defer { server.stop() }

        let (file, _) = try await collect(from: server)
        defer { try? FileManager.default.removeItem(at: file.url) }

        XCTAssertEqual(file.response.statusCode, 200)
        let size = (try? FileManager.default
            .attributesOfItem(atPath: file.url.path)[.size] as? Int) ?? 0
        XCTAssertEqual(size, 256 * 1024)
    }

    /// No Content-Length ⇒ no denominator ⇒ indeterminate, never a fake 0 %.
    func testMissingContentLengthReportsNoFraction() async throws {
        let server = try TestHTTPServer(totalBytes: 128 * 1024, chunkSize: 16 * 1024,
                                        announceLength: false)
        defer { server.stop() }

        let (file, counts) = try await collect(from: server)
        defer { try? FileManager.default.removeItem(at: file.url) }

        XCTAssertFalse(counts.isEmpty, "callbacks must still arrive without a length")
        XCTAssertTrue(counts.allSatisfy { $0.fraction == nil },
                      "An unknown total must surface as indeterminate, not as a number.")
    }

    func testTransportFailureSurfacesAsDownloadError() async throws {
        // Nothing listens on this port; the connection is refused.
        let dead = URL(string: "http://127.0.0.1:9/never")!
        do {
            let file = try await ProgressiveDownload.fetch(URLRequest(url: dead)) { _ in }
            try? FileManager.default.removeItem(at: file.url)
            XCTFail("expected a transport failure")
        } catch is DownloadError {
            // expected
        }
    }

    // MARK: runtime-visibility guard (kept, but no longer the only guard)

    /// Narrowing the collector's conformance to `URLSessionTaskDelegate` makes
    /// `didWriteData` invisible to the ObjC runtime with no compiler
    /// diagnostic. Cheap to pin; `testDownloadReportsIncrementalProgress` is
    /// what actually proves delivery.
    func testCollectorExposesDidWriteDataToObjCRuntime() {
        let collector = DownloadCollector(onCounts: { _ in })
        XCTAssertTrue(collector.responds(to: NSSelectorFromString(
            "URLSession:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:")))
        XCTAssertTrue(collector.responds(to: NSSelectorFromString(
            "URLSession:downloadTask:didFinishDownloadingToURL:")))
        XCTAssertTrue(collector.responds(to: NSSelectorFromString(
            "URLSession:task:didCompleteWithError:")))
    }
}

/// Pure arithmetic, split out of the delegates so it is testable without a
/// network at all.
final class TransferCountsTests: XCTestCase {

    func testFractionOfThisTransfer() {
        XCTAssertEqual(TransferCounts(received: 40, expected: 200).fraction ?? -1,
                       0.2, accuracy: 0.0001)
    }

    func testUnknownTotalHasNoFraction() {
        XCTAssertNil(TransferCounts(received: 10, expected: -1).fraction)
        XCTAssertNil(TransferCounts(received: 10, expected: 0).fraction)
    }

    /// A resumed transfer must report against the WHOLE file. Reporting the
    /// range would drop the bar back to 0 % on every resume.
    func testResumedFractionCountsBytesAlreadyOnDisk() {
        let counts = TransferCounts(received: 25, expected: 50)
        XCTAssertEqual(counts.fraction(resumedFrom: 50) ?? -1, 0.75, accuracy: 0.0001)
    }

    func testResumedFractionWithUnknownTotalIsNil() {
        XCTAssertNil(TransferCounts(received: 25, expected: -1).fraction(resumedFrom: 50))
    }

    func testFractionIsClampedToOne() {
        XCTAssertEqual(TransferCounts(received: 300, expected: 200).fraction ?? -1,
                       1.0, accuracy: 0.0001)
    }
}

private final class CountsBox: @unchecked Sendable {
    private var storage: [TransferCounts] = []
    private let lock = NSLock()
    func append(_ c: TransferCounts) { lock.lock(); storage.append(c); lock.unlock() }
    var values: [TransferCounts] { lock.lock(); defer { lock.unlock() }; return storage }
}

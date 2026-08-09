import Foundation

/// A file download that actually reports its progress.
///
/// ## Why this exists
///
/// `URLSession.download(for:delegate:)` — the async/await convenience — does
/// **not** deliver `didWriteData` to the delegate it is handed. Measured
/// 2026-08-09 against a local 8 MB source served in 64 KB chunks:
///
/// ```
/// A: URLSession.shared.download(for:delegate:)                 callbacks=0
/// B: URLSession(configuration:delegate:delegateQueue:).download callbacks=0
/// C: same session, classic downloadTask(with:) + resume        callbacks=128
/// ```
///
/// So the *task API* is what has to change, not merely the session: the
/// completion-handler-backed convenience swallows the incremental callbacks
/// regardless of which session it runs on. `NSURLSession.h` documents this
/// ("does not support incremental delivery"); the measurement above is the
/// proof, and `ProgressiveDownloadTests` re-runs it in CI against an
/// in-process HTTP server so the regression cannot come back silently.
///
/// This type therefore owns a session, starts a classic `URLSessionDownloadTask`,
/// and bridges completion back to `async` through a continuation.
public enum ProgressiveDownload {

    /// Downloads `request` to a temporary file, calling `onCounts` for every
    /// chunk the session writes.
    ///
    /// The returned file is the caller's property: move it or delete it.
    /// `onCounts` is invoked on URLSession's delegate queue, never the caller's.
    public static func fetch(
        _ request: URLRequest,
        onCounts: @escaping @Sendable (TransferCounts) -> Void
    ) async throws -> DownloadedFile {
        let collector = DownloadCollector(onCounts: onCounts)
        let configuration = URLSessionConfiguration.default
        // A 177 MB engine archive has no business in the URL cache, and a
        // cached body would defeat the resume-by-range logic above us.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration,
                                 delegate: collector, delegateQueue: nil)
        // The session retains its delegate until invalidated; without this the
        // collector, the continuation and the session all leak per download.
        defer { session.finishTasksAndInvalidate() }

        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.attach(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// Byte counts exactly as URLSession reports them, with the fraction
/// arithmetic that used to live (untested against a real transfer) inside the
/// two download delegates.
public struct TransferCounts: Sendable, Equatable {
    /// Bytes written by *this* transfer. On a resumed range request this is
    /// the range, not the whole file.
    public let received: Int64
    /// Bytes this transfer is expected to write, or a non-positive value when
    /// the server sent no usable Content-Length.
    public let expected: Int64

    public init(received: Int64, expected: Int64) {
        self.received = received
        self.expected = expected
    }

    /// Fraction of this transfer, or nil when there is no honest denominator.
    public var fraction: Double? {
        guard expected > 0 else { return nil }
        return min(max(Double(received) / Double(expected), 0), 1)
    }

    /// Fraction of the *whole* file when `alreadyHave` bytes are already on
    /// disk and this transfer carries only the remaining range. A resumed
    /// download that reported its range fraction would show the bar jumping
    /// back to 0 % and racing to 100 % over the last few megabytes.
    public func fraction(resumedFrom alreadyHave: Int64) -> Double? {
        guard expected > 0 else { return nil }
        let done = Double(alreadyHave + received)
        let total = Double(alreadyHave + expected)
        guard total > 0 else { return nil }
        return min(max(done / total, 0), 1)
    }
}

public struct DownloadedFile: Sendable {
    /// A temporary file owned by the caller.
    public let url: URL
    public let response: HTTPURLResponse
}

public enum DownloadError: Error, LocalizedError {
    case noHTTPResponse
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .noHTTPResponse:
            return "The server did not return an HTTP response."
        case .transport(let detail):
            return detail
        }
    }
}

/// The delegate URLSession actually talks to.
///
/// `didWriteData` is a `URLSessionDownloadDelegate` requirement. Under SE-0160
/// a Swift method is exposed to the Objective-C runtime only when it satisfies
/// a requirement of an adopted `@objc` protocol, and URLSession dispatches
/// through `respondsToSelector:` — so narrowing this conformance to
/// `URLSessionTaskDelegate` would silently disable progress with no compiler
/// diagnostic. `ProgressiveDownloadTests` pins both the runtime visibility and,
/// more importantly, real delivery over a real socket.
///
/// Internal rather than private so the tests can reach it.
final class DownloadCollector: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onCounts: @Sendable (TransferCounts) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DownloadedFile, Error>?
    private var staged: URL?
    private var stagingError: Error?

    init(onCounts: @escaping @Sendable (TransferCounts) -> Void) {
        self.onCounts = onCounts
    }

    func attach(_ continuation: CheckedContinuation<DownloadedFile, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    /// Resumes exactly once, whichever delegate callback gets there first.
    private func finish(_ result: Result<DownloadedFile, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        pending.resume(with: result)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onCounts(TransferCounts(received: totalBytesWritten,
                                expected: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // URLSession deletes `location` the moment this method returns, so the
        // move MUST happen here and synchronously — not after the continuation
        // hands the URL to an async caller.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("openxe-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock(); staged = destination; lock.unlock()
        } catch {
            lock.lock(); stagingError = error; lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        if let error {
            lock.lock(); let orphan = staged; staged = nil; lock.unlock()
            if let orphan { try? FileManager.default.removeItem(at: orphan) }
            finish(.failure(DownloadError.transport(error.localizedDescription)))
            return
        }
        lock.lock()
        let file = staged
        let stagingFailure = stagingError
        lock.unlock()
        if let stagingFailure {
            finish(.failure(DownloadError.transport(stagingFailure.localizedDescription)))
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            if let file { try? FileManager.default.removeItem(at: file) }
            finish(.failure(DownloadError.noHTTPResponse))
            return
        }
        guard let file else {
            finish(.failure(DownloadError.transport("the download produced no file")))
            return
        }
        finish(.success(DownloadedFile(url: file, response: http)))
    }
}

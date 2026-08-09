import Foundation

/// The setup narrative log (spec §4.4). Every subprocess spawned during setup
/// tees into this; today stages 1-10 write nothing anywhere, which is why a
/// failed install on someone else's Mac cannot be diagnosed.
///
/// Session-appended, rotated at 5 MB with one generation kept. Deliberately
/// separate from wine.log, which stays scoped to program launches.
public final class SetupLog: @unchecked Sendable {

    static let rotateThreshold = 5 << 20

    private let url: URL
    private let fileHandle: FileHandle
    private let lock = NSLock()

    /// Guarded by `lock` — ISO8601DateFormatter is not documented as
    /// thread-safe, and every timestamped write already holds the lock.
    private let stamper = ISO8601DateFormatter()

    /// The handle to hand to `Subprocess.run(logHandle:)`.
    public var handle: FileHandle { fileHandle }
    public var fileURL: URL { url }

    public init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        Self.rotateIfNeeded(at: url)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try FileHandle(forWritingTo: url)
        try fileHandle.seekToEnd()
    }

    static func rotateIfNeeded(at url: URL) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size >= rotateThreshold else { return }
        let rotated = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".1")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: url, to: rotated)
    }

    private func emit(_ line: String, at instant: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let stamp = stamper.string(from: instant)
        try? fileHandle.write(contentsOf: Data("\(stamp) \(line)\n".utf8))
    }

    public func beginRun(buildID: String, engineID: String, freeBytes: Int64) {
        emit("===== setup run begin =====")
        emit("build=\(buildID) engine=\(engineID) freeBytes=\(freeBytes) "
             + "os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    public func beginStage(_ stage: SetupStage.ID, attempt: Int) {
        emit("--- stage \(stage.rawValue) begin (attempt \(attempt)) ---")
    }

    public func endStage(_ stage: SetupStage.ID, elapsed: TimeInterval) {
        emit(String(format: "--- stage %@ end (%.1fs) ---", stage.rawValue, elapsed))
    }

    /// Open a stage bracket and return a MONOTONIC mark to close it with
    /// (instrumentation spec §3.1). `DispatchTime`, not `Date`: a multi-minute
    /// cold run can outlive an NTP step, and a wall-clock delta would then be
    /// inflated or negative.
    ///
    /// This is a timing bracket and nothing else — no retry, no ceiling, no
    /// cancellation. Task 15's `ProductionStageRunner` owns those and calls
    /// `beginStage`/`endStage(_:elapsed:)` directly; this pair is deleted then.
    @discardableResult
    public func startStage(_ stage: SetupStage.ID, attempt: Int = 1) -> DispatchTime {
        beginStage(stage, attempt: attempt)
        return DispatchTime.now()
    }

    /// Close a bracket opened by `startStage`. Emitted only on success: an
    /// unterminated `begin` is how the log says where the run died.
    public func endStage(_ stage: SetupStage.ID, startedAt: DispatchTime) {
        endStage(stage, elapsed: Self.elapsed(since: startedAt))
    }

    static func elapsed(since start: DispatchTime) -> TimeInterval {
        // Unsigned wrapping subtraction: uptimeNanoseconds is monotonic, so the
        // result is always the true forward interval.
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000_000
    }

    public func note(_ message: String) { emit(message) }

    /// Write a line carrying an instant that is not "now".
    ///
    /// The one caller is cleanup's transcript replay: the removal deletes the
    /// directory its own log lives in, re-creates the file and writes every line
    /// again. Stamping those writes at write time collapses the whole run onto a
    /// single instant — a real 2.7s removal replayed as twenty lines all reading
    /// `19:46:57` — and per-line timing is exactly what is wanted when a large
    /// delete stalls. The instant is captured once, when the line is first said,
    /// and travels with it.
    public func note(_ message: String, at instant: Date) { emit(message, at: instant) }

    /// A sub-stage measurement the six stage brackets do not carry — the engine
    /// transfer/verify split, the Rosetta install. Kept when Task 14 supersedes
    /// the brackets themselves.
    public func note(_ message: String, since start: DispatchTime) {
        emit(String(format: "%@ in %.1fs", message, Self.elapsed(since: start)))
    }

    /// Raw subprocess bytes, written verbatim without a timestamp prefix.
    public func write(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        try? fileHandle.write(contentsOf: data)
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        try? fileHandle.close()
    }

    /// Last `lines` lines, for the disclosure triangle and failure state.
    ///
    /// The trailing newline every emitted line carries is dropped before
    /// splitting: otherwise a tail of N spends one of its N slots on the empty
    /// string after the final newline, and shows N-1 real lines.
    public static func tail(of url: URL, lines: Int = 40) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "(no setup log yet)"
        }
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        return body.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lines).joined(separator: "\n")
    }
}

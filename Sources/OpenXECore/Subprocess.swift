import Foundation

public struct SubprocessResult: Sendable {
    public let status: Int32
    public let output: String // combined stdout + stderr
}

public enum SubprocessError: Error, LocalizedError {
    case timedOut(command: String, seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let command, let seconds):
            return "'\(command)' did not finish within \(Int(seconds)) seconds"
        }
    }
}

/// Thin wrapper over Process: combined-output capture, optional timeout,
/// optional log-file tee. Wine is only ever invoked through this — as an
/// unmodified external subprocess (spec hard constraint).
public enum Subprocess {

    @discardableResult
    public static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil,
        logHandle: FileHandle? = nil,
        captureOutput: Bool = true
    ) throws -> SubprocessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        // Daemonizing children (wineserver -p, Wine services) inherit the
        // pipe's write end and keep it open long after the direct child exits,
        // so we must never block until pipe EOF. Callers that don't need output
        // skip the pipe entirely; capturing callers get an EOF-flag drain with
        // a bounded grace period below.
        var pipe: Pipe?
        var buffer: OutputBuffer?
        if captureOutput {
            let p = Pipe()
            process.standardOutput = p
            process.standardError = p
            let b = OutputBuffer(logHandle: logHandle)
            p.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { // EOF: all writers closed
                    b.markEOF()
                    handle.readabilityHandler = nil
                } else {
                    b.append(chunk)
                }
            }
            pipe = p
            buffer = b
        } else {
            let sink = logHandle ?? FileHandle.nullDevice
            process.standardOutput = sink
            process.standardError = sink
        }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        try process.run()

        let deadline: DispatchTime = timeout.map { .now() + $0 } ?? .distantFuture
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 5)
            pipe?.fileHandleForReading.readabilityHandler = nil
            throw SubprocessError.timedOut(
                command: ([executable.lastPathComponent] + arguments).joined(separator: " "),
                seconds: timeout ?? 0)
        }

        // Give the handler a bounded grace period to reach EOF, then take what
        // we have — never wait indefinitely on writers that may outlive the child.
        if let buffer, let pipe {
            _ = buffer.waitForEOF(timeout: 0.5)
            pipe.fileHandleForReading.readabilityHandler = nil
        }

        return SubprocessResult(status: process.terminationStatus, output: buffer?.string ?? "")
    }
}

/// Lock-guarded accumulator shared between the readability handler and the caller.
private final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private let logHandle: FileHandle?
    private let eof = DispatchSemaphore(value: 0)

    init(logHandle: FileHandle?) { self.logHandle = logHandle }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
        try? logHandle?.write(contentsOf: chunk)
    }

    func markEOF() { eof.signal() }

    /// True when EOF arrived within the window.
    func waitForEOF(timeout: TimeInterval) -> Bool {
        eof.wait(timeout: .now() + timeout) == .success
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

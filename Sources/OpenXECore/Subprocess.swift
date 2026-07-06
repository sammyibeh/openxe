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
        logHandle: FileHandle? = nil
    ) throws -> SubprocessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let buffer = OutputBuffer(logHandle: logHandle)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { buffer.append(chunk) }
        }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        try process.run()

        let deadline: DispatchTime = timeout.map { .now() + $0 } ?? .distantFuture
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 5)
            pipe.fileHandleForReading.readabilityHandler = nil
            throw SubprocessError.timedOut(
                command: ([executable.lastPathComponent] + arguments).joined(separator: " "),
                seconds: timeout ?? 0)
        }

        // Drain any remaining bytes, then detach the handler.
        if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            buffer.append(rest)
        }
        pipe.fileHandleForReading.readabilityHandler = nil

        return SubprocessResult(status: process.terminationStatus, output: buffer.string)
    }
}

/// Lock-guarded accumulator shared between the readability handler and the caller.
private final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private let logHandle: FileHandle?

    init(logHandle: FileHandle?) { self.logHandle = logHandle }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
        try? logHandle?.write(contentsOf: chunk)
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

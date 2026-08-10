import Foundation

/// A minimal in-process HTTP server, so download tests exercise a real socket
/// and a real `URLSession` instead of a hand-called delegate method.
///
/// This exists because the previous progress tests invoked
/// `delegate.urlSession(_:downloadTask:didWriteData:...)` directly. That
/// assertion passes identically whether or not URLSession ever calls the
/// method — which is exactly how a dead progress bar shipped twice. Anything
/// claiming to cover download progress has to put bytes through a socket.
///
/// Deliberately dependency-free (BSD sockets, one background thread): the
/// project's zero-dependency rule applies to tests too.
final class TestHTTPServer: @unchecked Sendable {

    let port: UInt16
    private let listenFD: Int32
    private let body: [UInt8]?
    private let totalBytes: Int
    private let chunkSize: Int
    private let microsecondsPerChunk: UInt32
    private let announceLength: Bool
    private let stopped = NSLock()
    private var isStopped = false

    /// - Parameters:
    ///   - body: the exact bytes to serve. Nil serves `totalBytes` of filler —
    ///     enough for a progress test, but the engine/NWS chain tests need a
    ///     real archive on the wire so the checksum and size gates run for
    ///     real rather than being stubbed out.
    ///   - totalBytes: body size when `body` is nil.
    ///   - chunkSize: bytes per `write`, so progress arrives in steps.
    ///   - microsecondsPerChunk: pacing, so a transfer is not over before the
    ///     first callback can land.
    ///   - announceLength: false omits Content-Length, which is how a real
    ///     server produces the "no honest denominator" case.
    init(body: Data? = nil,
         totalBytes: Int = 512 * 1024,
         chunkSize: Int = 16 * 1024,
         microsecondsPerChunk: UInt32 = 4_000,
         announceLength: Bool = true) throws {
        self.body = body.map { [UInt8]($0) }
        self.totalBytes = body?.count ?? totalBytes
        self.chunkSize = chunkSize
        self.microsecondsPerChunk = microsecondsPerChunk
        self.announceLength = announceLength

        // All socket setup happens on locals: closures may not capture `self`
        // before every stored property is initialised.
        let (fd, boundPort) = try Self.listenOnLoopback()
        listenFD = fd
        port = boundPort

        let thread = Thread { [weak self] in self?.serve() }
        thread.name = "TestHTTPServer"
        thread.start()
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/blob.bin")! }

    /// Binds a listening socket to 127.0.0.1 on a kernel-chosen port and
    /// reports which one, so concurrent tests never collide.
    private static func listenOnLoopback() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketFailed(errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                       // let the kernel pick
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw ServerError.bindFailed(errno)
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { close(fd); throw ServerError.bindFailed(errno) }
        return (fd, UInt16(bigEndian: actual.sin_port))
    }

    func stop() {
        stopped.lock()
        defer { stopped.unlock() }
        guard !isStopped else { return }
        isStopped = true
        close(listenFD)
    }

    private var shouldStop: Bool {
        stopped.lock(); defer { stopped.unlock() }; return isStopped
    }

    private func serve() {
        while !shouldStop {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }   // listener closed by stop()
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                       socklen_t(MemoryLayout<Int32>.size))
            respond(on: client)
            close(client)
        }
    }

    private func respond(on client: Int32) {
        // Drain the request headers; the body is irrelevant to these tests.
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = recv(client, &buffer, buffer.count, 0)

        var header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
        if announceLength {
            header += "Content-Length: \(totalBytes)\r\nConnection: close\r\n\r\n"
        } else {
            // No length: URLSession reports totalBytesExpectedToWrite as
            // NSURLSessionTransferSizeUnknown, the indeterminate case.
            header += "Connection: close\r\n\r\n"
        }
        guard writeAll(client, Array(header.utf8)) else { return }

        let filler = [UInt8](repeating: 0x78, count: chunkSize)
        var sent = 0
        while sent < totalBytes, !shouldStop {
            let n = min(chunkSize, totalBytes - sent)
            let slice = body.map { Array($0[sent..<(sent + n)]) } ?? Array(filler[0..<n])
            guard writeAll(client, slice) else { return }
            sent += n
            usleep(microsecondsPerChunk)
        }
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer {
                send(fd, $0.baseAddress! + offset, bytes.count - offset, 0)
            }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    enum ServerError: Error {
        case socketFailed(Int32)
        case bindFailed(Int32)
    }
}

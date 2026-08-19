import Foundation

/// Thin, blocking wrapper over an AF_UNIX SOCK_STREAM fd.
///
/// Sendability contract, enforced by the callers rather than by the type:
///   * `readLine()` owns `readBuffer`, so it must be driven from one serial context
///     at a time (each Connection gives it a dedicated serial queue).
///   * `write()` touches no shared state and is safe from any thread; callers that
///     care about frame interleaving take their own lock.
///   * `close()` is idempotent and guarded.
///
/// `fd` is immutable for a reason: clearing it on close would open a window where
/// another thread reads a recycled descriptor belonging to a different file.
public final class UnixSocket: @unchecked Sendable {
    public let fd: Int32
    private var readBuffer = Data()
    private let stateLock = NSLock()
    private var isClosed = false

    public init(fd: Int32) {
        self.fd = fd
        Self.suppressSIGPIPE(fd)
    }

    deinit { close() }

    /// Without SO_NOSIGPIPE, writing to a peer that has gone away raises SIGPIPE and
    /// kills the process. The daemon must survive a client disappearing mid-write.
    static func suppressSIGPIPE(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func makeAddress(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= Paths.maxSocketPathLength else {
            throw DenshaError.socketPathTooLong(path: path, length: bytes.count)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var addr = try makeAddress(path)
        return try withUnsafePointer(to: &addr) { p in
            try p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                try body(sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    // MARK: - Connecting

    public static func connect(to path: String) throws -> UnixSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DenshaError.daemonUnreachable("socket(): \(errnoText())")
        }
        do {
            let rc = try withAddress(path) { sa, len in Darwin.connect(fd, sa, len) }
            guard rc == 0 else {
                let err = errno
                Darwin.close(fd)
                // ENOENT: no socket file at all. ECONNREFUSED: file left behind by a
                // daemon that died. Both mean "not running", and both are recoverable
                // by spawning one, so they share an error case.
                if err == ENOENT || err == ECONNREFUSED {
                    throw DenshaError.daemonNotRunning
                }
                throw DenshaError.daemonUnreachable("connect(\(path)): \(errnoText(err))")
            }
        } catch {
            throw error
        }
        return UnixSocket(fd: fd)
    }

    // MARK: - Listening

    /// Binds a fresh listening socket, replacing a stale socket file if one is there.
    /// Caller must already hold the single-instance lock — otherwise this races.
    public static func listen(at path: String, backlog: Int32 = 32) throws -> UnixSocket {
        try Paths.validateSocketPath(URL(fileURLWithPath: path))
        // bind() fails with EADDRINUSE on an existing path even when nothing is
        // listening, so a crashed daemon's leftover socket must be cleared first.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DenshaError.daemonUnreachable("socket(): \(errnoText())")
        }
        // Ensure the socket is created 0600 regardless of the ambient umask: it is a
        // control channel that can start arbitrary processes.
        let previousMask = umask(0o077)
        defer { umask(previousMask) }

        let bindResult = try withAddress(path) { sa, len in Darwin.bind(fd, sa, len) }
        guard bindResult == 0 else {
            let err = errnoText()
            Darwin.close(fd)
            throw DenshaError.daemonUnreachable("bind(\(path)): \(err)")
        }
        guard Darwin.listen(fd, backlog) == 0 else {
            let err = errnoText()
            Darwin.close(fd)
            throw DenshaError.daemonUnreachable("listen(): \(err)")
        }
        chmod(path, 0o600)
        return UnixSocket(fd: fd)
    }

    public func accept() throws -> UnixSocket {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client >= 0 { return UnixSocket(fd: client) }
            if errno == EINTR { continue }
            throw DenshaError.daemonUnreachable("accept(): \(Self.errnoText())")
        }
    }

    // MARK: - I/O

    public func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                if n < 0, errno == EINTR { continue }
                if n < 0, errno == EPIPE { throw DenshaError.connectionClosed }
                throw DenshaError.daemonUnreachable("write(): \(Self.errnoText())")
            }
        }
    }

    /// Reads one newline-terminated frame, or nil at clean end of stream.
    public func readLine() throws -> Data? {
        while true {
            if let idx = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer[readBuffer.startIndex..<idx]
                readBuffer.removeSubrange(readBuffer.startIndex...idx)
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n > 0 {
                readBuffer.append(contentsOf: chunk[0..<n])
                continue
            }
            if n == 0 {
                // Tolerate a final frame that arrived without its newline.
                if !readBuffer.isEmpty {
                    let rest = readBuffer
                    readBuffer.removeAll()
                    return rest
                }
                return nil
            }
            if errno == EINTR { continue }
            if errno == ECONNRESET { return nil }
            throw DenshaError.daemonUnreachable("read(): \(Self.errnoText())")
        }
    }

    public func close() {
        stateLock.lock()
        let shouldClose = !isClosed
        isClosed = true
        stateLock.unlock()
        guard shouldClose, fd >= 0 else { return }
        // shutdown() first so a thread parked in read()/accept() wakes up and unwinds
        // instead of blocking forever on a descriptor nobody will write to again.
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    static func errnoText(_ code: Int32 = errno) -> String {
        String(cString: strerror(code)) + " (errno \(code))"
    }
}

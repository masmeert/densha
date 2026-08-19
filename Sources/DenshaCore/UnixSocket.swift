import Foundation

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

    static func withAddress<T>(
        _ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        var addr = try makeAddress(path)
        return try withUnsafePointer(to: &addr) { p in
            try p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                try body(sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

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

    public static func listen(at path: String, backlog: Int32 = 32) throws -> UnixSocket {
        try Paths.validateSocketPath(URL(fileURLWithPath: path))
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DenshaError.daemonUnreachable("socket(): \(errnoText())")
        }
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
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    static func errnoText(_ code: Int32 = errno) -> String {
        String(cString: strerror(code)) + " (errno \(code))"
    }
}

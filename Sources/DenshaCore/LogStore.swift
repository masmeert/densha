import Foundation

/// Fixed-capacity circular buffer. Array.removeFirst() would be O(n) per line, and
/// a busy Metro bundler emits thousands of lines a second.
public struct RingBuffer {
    private var storage: [LogLine?]
    private var head = 0
    public private(set) var count = 0

    public init(capacity: Int) {
        storage = Array(repeating: nil, count: max(1, capacity))
    }

    public var capacity: Int { storage.count }

    public mutating func append(_ line: LogLine) {
        storage[head] = line
        head = (head + 1) % storage.count
        if count < storage.count { count += 1 }
    }

    /// Oldest-to-newest.
    public var all: [LogLine] {
        guard count > 0 else { return [] }
        let start = (head - count + storage.count) % storage.count
        return (0..<count).compactMap { storage[(start + $0) % storage.count] }
    }

    public func tail(_ n: Int) -> [LogLine] {
        guard n > 0, count > 0 else { return [] }
        let take = min(n, count)
        let start = (head - take + storage.count) % storage.count
        return (0..<take).compactMap { storage[(start + $0) % storage.count] }
    }

    public mutating func removeAll() {
        storage = Array(repeating: nil, count: storage.count)
        head = 0
        count = 0
    }
}

/// Per-service log storage: an in-memory tail for instant UI fill, plus a rotating
/// file on disk. Both are bounded; neither ever grows without limit.
public final class LogStore {
    public let name: String
    private let fileURL: URL
    private let maxFileBytes: Int
    private let maxPendingBytes: Int

    private var ring: RingBuffer
    private var nextSeq: UInt64 = 1

    /// Bytes received since the last newline. A dev server can print a prompt with no
    /// trailing newline, so this is also flushed on idle (see flushPending).
    private var pending = Data()

    private var handle: FileHandle?
    private var bytesWritten = 0

    public init(
        name: String,
        fileURL: URL,
        ringCapacity: Int = 5000,
        maxFileBytes: Int = 8 * 1024 * 1024,
        maxPendingBytes: Int = 64 * 1024
    ) {
        self.name = name
        self.fileURL = fileURL
        self.ring = RingBuffer(capacity: ringCapacity)
        self.maxFileBytes = maxFileBytes
        self.maxPendingBytes = maxPendingBytes
    }

    deinit { try? handle?.close() }

    // MARK: - Ingest

    /// Feeds raw PTY bytes in and returns whatever complete lines that produced.
    public func ingest(_ data: Data) -> [LogLine] {
        writeToFile(data)

        var produced: [LogLine] = []
        for byte in data {
            if byte == 0x0A {
                produced.append(makeLine(from: pending))
                pending.removeAll(keepingCapacity: true)
            } else {
                pending.append(byte)
            }
        }
        // Never let a newline-free stream grow unbounded.
        if pending.count >= maxPendingBytes {
            produced.append(makeLine(from: pending))
            pending.removeAll(keepingCapacity: true)
        }
        return produced
    }

    /// Emits a trailing partial line (a prompt, a spinner frame) that has been sitting
    /// unterminated. Called on an idle timer and at process exit.
    public func flushPending() -> LogLine? {
        guard !pending.isEmpty else { return nil }
        let line = makeLine(from: pending)
        pending.removeAll(keepingCapacity: true)
        return line
    }

    private func makeLine(from raw: Data) -> LogLine {
        let line = LogLine(
            seq: nextSeq,
            ts: Date().timeIntervalSince1970,
            text: Self.collapseCarriageReturns(raw)
        )
        nextSeq += 1
        ring.append(line)
        return line
    }

    /// A PTY delivers CRLF endings, and progress indicators rewrite one line by
    /// returning to column 0 with a bare CR. Keeping every frame would turn a single
    /// progress bar into thousands of log lines, so only the final state survives.
    public static func collapseCarriageReturns(_ raw: Data) -> String {
        var bytes = Array(raw)
        if bytes.last == 0x0D { bytes.removeLast() }
        guard let lastCR = bytes.lastIndex(of: 0x0D) else {
            return String(decoding: bytes, as: UTF8.self)
        }
        let visible = bytes[(lastCR + 1)...]
        return String(decoding: visible, as: UTF8.self)
    }

    // MARK: - Read

    public func tail(_ n: Int?) -> [LogLine] {
        guard let n else { return ring.all }
        return ring.tail(n)
    }

    public func clear() {
        ring.removeAll()
        pending.removeAll(keepingCapacity: false)
    }

    // MARK: - File

    /// Raw bytes go to disk, ANSI escapes and all, so `densha logs` can replay the
    /// output in colour. The CLI strips them when the destination is not a terminal.
    private func writeToFile(_ data: Data) {
        guard let handle = ensureHandle() else { return }
        do {
            try handle.write(contentsOf: data)
            bytesWritten += data.count
            if bytesWritten >= maxFileBytes { rotate() }
        } catch {
            // Losing the disk copy must never take down the service or the daemon;
            // the in-memory tail still works.
            self.handle = nil
        }
    }

    private func ensureHandle() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        try? fm.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            // 0600: dev-server output routinely contains tokens, connection strings
            // and signing secrets, so it should not be world-readable.
            fm.createFile(
                atPath: fileURL.path, contents: nil,
                attributes: [.posixPermissions: 0o600])
        }
        guard let h = try? FileHandle(forWritingTo: fileURL) else { return nil }
        let end = (try? h.seekToEnd()) ?? 0
        bytesWritten = Int(end)
        handle = h
        return h
    }

    /// Keeps exactly one previous generation: <name>.log.1.
    private func rotate() {
        try? handle?.close()
        handle = nil
        let previous = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: fileURL, to: previous)
        bytesWritten = 0
    }
}

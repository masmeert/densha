import Foundation

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

public final class LogStore {
    public let name: String
    private let fileURL: URL
    private let maxFileBytes: Int
    private let maxPendingBytes: Int

    private var ring: RingBuffer
    private var nextSeq: UInt64 = 1

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
        if pending.count >= maxPendingBytes {
            produced.append(makeLine(from: pending))
            pending.removeAll(keepingCapacity: true)
        }
        return produced
    }

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

    public static func collapseCarriageReturns(_ raw: Data) -> String {
        var bytes = Array(raw)
        if bytes.last == 0x0D { bytes.removeLast() }
        guard let lastCR = bytes.lastIndex(of: 0x0D) else {
            return String(decoding: bytes, as: UTF8.self)
        }
        let visible = bytes[(lastCR + 1)...]
        return String(decoding: visible, as: UTF8.self)
    }

    public static func plainText(_ raw: Data) -> String {
        var pieces = raw.split(separator: 0x0A, omittingEmptySubsequences: false)
        if pieces.last?.isEmpty == true { pieces.removeLast() }
        return pieces.map { Ansi.strip(collapseCarriageReturns(Data($0))) + "\n" }.joined()
    }

    public func tail(_ n: Int?) -> [LogLine] {
        guard let n else { return ring.all }
        return ring.tail(n)
    }

    public func clear() {
        ring.removeAll()
        pending.removeAll(keepingCapacity: false)
    }

    private func writeToFile(_ data: Data) {
        guard let handle = ensureHandle() else { return }
        do {
            try handle.write(contentsOf: data)
            bytesWritten += data.count
            if bytesWritten >= maxFileBytes { rotate() }
        } catch {
            self.handle = nil
        }
    }

    private func ensureHandle() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        try? fm.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
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

    private func rotate() {
        try? handle?.close()
        handle = nil
        let previous = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: fileURL, to: previous)
        bytesWritten = 0
    }
}

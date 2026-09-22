import Foundation

public struct RingBuffer {
    private var storage: [LogLine] = []
    private let capacity: Int
    private var head = 0

    public var count: Int { storage.count }

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(min(self.capacity, 64))
    }

    public mutating func append(_ line: LogLine) {
        if storage.count < capacity {
            storage.append(line)
            head = storage.count % capacity
        } else {
            storage[head] = line
            head = (head + 1) % capacity
        }
    }

    public var all: [LogLine] { tail(storage.count) }

    public func tail(_ n: Int) -> [LogLine] {
        guard n > 0, !storage.isEmpty else { return [] }
        let take = min(n, storage.count)
        let start = (head - take + storage.count) % storage.count
        return (0..<take).map { storage[(start + $0) % storage.count] }
    }

}

public final class LogStore {
    private let fileURL: URL
    private let maxFileBytes: Int
    private let maxPendingBytes: Int

    private var ring: RingBuffer
    private var nextSeq: UInt64 = 1

    private var pending = Data()

    private var handle: FileHandle?
    private var bytesWritten = 0

    public init(
        fileURL: URL,
        ringCapacity: Int = 5000,
        maxFileBytes: Int = 8 * 1024 * 1024,
        maxPendingBytes: Int = 64 * 1024
    ) {
        self.fileURL = fileURL
        self.ring = RingBuffer(capacity: ringCapacity)
        self.maxFileBytes = maxFileBytes
        self.maxPendingBytes = maxPendingBytes
    }

    deinit { try? handle?.close() }

    public func ingest(_ data: Data) -> [LogLine] {
        writeToFile(data)

        var produced: [LogLine] = []
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            let chunk = data[start..<newline]
            if pending.isEmpty {
                produced.append(makeLine(from: chunk))
            } else {
                pending.append(chunk)
                produced.append(makeLine(from: pending))
                pending.removeAll(keepingCapacity: true)
            }
            start = data.index(after: newline)
        }
        if start < data.endIndex {
            pending.append(data[start...])
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
        var frame = raw
        if frame.last == 0x0D { frame = frame.dropLast() }
        guard let lastCR = frame.lastIndex(of: 0x0D) else {
            return String(decoding: frame, as: UTF8.self)
        }
        return String(decoding: frame[frame.index(after: lastCR)...], as: UTF8.self)
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

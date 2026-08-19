import Foundation
import Testing

@testable import DenshaCore

@Suite("RingBuffer")
struct RingBufferTests {
    private func line(_ n: Int) -> LogLine { LogLine(seq: UInt64(n), ts: 0, text: "line\(n)") }

    @Test("stays empty until written")
    func empty() {
        let buffer = RingBuffer(capacity: 4)
        #expect(buffer.count == 0)
        #expect(buffer.all.isEmpty)
        #expect(buffer.tail(3).isEmpty)
    }

    @Test("keeps insertion order below capacity")
    func underCapacity() {
        var buffer = RingBuffer(capacity: 10)
        for i in 1...3 { buffer.append(line(i)) }
        #expect(buffer.all.map(\.text) == ["line1", "line2", "line3"])
    }

    @Test("drops the oldest entries once full")
    func wrapAround() {
        var buffer = RingBuffer(capacity: 3)
        for i in 1...5 { buffer.append(line(i)) }
        #expect(buffer.count == 3)
        #expect(buffer.all.map(\.text) == ["line3", "line4", "line5"])
    }

    @Test("tail returns the newest n, oldest-first")
    func tail() {
        var buffer = RingBuffer(capacity: 100)
        for i in 1...10 { buffer.append(line(i)) }
        #expect(buffer.tail(3).map(\.text) == ["line8", "line9", "line10"])
        #expect(buffer.tail(0).isEmpty)
        #expect(buffer.tail(999).count == 10)
    }

    @Test("survives many wraps without corrupting order")
    func manyWraps() {
        var buffer = RingBuffer(capacity: 8)
        for i in 1...1000 { buffer.append(line(i)) }
        #expect(buffer.count == 8)
        #expect(buffer.all.map(\.text) == (993...1000).map { "line\($0)" })
    }
}

@Suite("Carriage returns")
struct CarriageReturnTests {
    private func collapse(_ s: String) -> String {
        LogStore.collapseCarriageReturns(Data(s.utf8))
    }

    @Test("a plain line is untouched")
    func plain() {
        #expect(collapse("hello world") == "hello world")
    }

    @Test("the trailing CR of a PTY's CRLF is removed")
    func trailingCR() {
        #expect(collapse("ready\r") == "ready")
    }

    @Test("only the final frame of a progress indicator survives")
    func progress() {
        #expect(collapse("\rProgress 10%\rProgress 50%\rProgress 100%") == "Progress 100%")
    }

    @Test("a progress sequence ending in CRLF still yields the last frame")
    func progressThenNewline() {
        #expect(collapse("\rstep 1\rstep 2\r") == "step 2")
    }

    @Test("ANSI colour inside the surviving frame is preserved")
    func keepsColorInFinalFrame() {
        #expect(collapse("\rold\r\u{1B}[32mdone\u{1B}[0m") == "\u{1B}[32mdone\u{1B}[0m")
    }

    @Test("empty input is empty output")
    func empty() {
        #expect(collapse("") == "")
        #expect(collapse("\r") == "")
    }
}

@Suite("LogStore")
struct LogStoreTests {
    private func makeStore(_ name: String = "t", capacity: Int = 100) -> (LogStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("densha-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).log")
        return (LogStore(name: name, fileURL: url, ringCapacity: capacity), url)
    }

    @Test("splits a stream into lines on newlines only")
    func splitting() {
        let (store, _) = makeStore()
        let lines = store.ingest(Data("one\r\ntwo\r\n".utf8))
        #expect(lines.map(\.text) == ["one", "two"])
    }

    @Test("a line split across two reads is reassembled, not truncated")
    func partialAcrossChunks() {
        let (store, _) = makeStore()
        #expect(store.ingest(Data("hel".utf8)).isEmpty)
        let lines = store.ingest(Data("lo\r\n".utf8))
        #expect(lines.map(\.text) == ["hello"])
    }

    @Test("an unterminated line is held back until flushed")
    func pendingFlush() {
        let (store, _) = makeStore()
        #expect(store.ingest(Data("? Overwrite".utf8)).isEmpty)
        let flushed = store.flushPending()
        #expect(flushed?.text == "? Overwrite")
        #expect(store.flushPending() == nil)
    }

    @Test("sequence numbers are monotonic across flushes")
    func sequenceNumbers() {
        let (store, _) = makeStore()
        let first = store.ingest(Data("a\n b\n".utf8))
        _ = store.ingest(Data("partial".utf8))
        let flushed = store.flushPending()
        #expect(first.map(\.seq) == [1, 2])
        #expect(flushed?.seq == 3)
    }

    @Test("the ring is bounded but the newest lines are always kept")
    func bounded() {
        let (store, _) = makeStore(capacity: 5)
        for i in 1...50 { _ = store.ingest(Data("line\(i)\n".utf8)) }
        let tail = store.tail(nil)
        #expect(tail.count == 5)
        #expect(tail.map(\.text) == (46...50).map { "line\($0)" })
    }

    @Test("raw bytes reach disk with escapes intact, and the file is not world-readable")
    func fileWrite() throws {
        let (store, url) = makeStore()
        _ = store.ingest(Data("\u{1B}[32mgreen\u{1B}[0m\r\n".utf8))
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk == Data("\u{1B}[32mgreen\u{1B}[0m\r\n".utf8))

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        #expect((mode as? NSNumber)?.intValue == 0o600)
    }

    @Test("a newline-free flood is cut into chunks instead of growing without bound")
    func runawayLine() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("densha-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = LogStore(
            name: "t", fileURL: dir.appendingPathComponent("t.log"),
            ringCapacity: 100, maxPendingBytes: 32)
        var produced: [LogLine] = []
        for _ in 0..<10 {
            produced += store.ingest(Data(String(repeating: "x", count: 10).utf8))
        }
        #expect(!produced.isEmpty)
        #expect(produced.allSatisfy { $0.text.count <= 40 })
    }
}

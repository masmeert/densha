import DenshaCore
import Testing

@testable import DenshaUI

@MainActor
@Suite("LogTranscriptText")
struct LogTranscriptTextTests {
    private let lines = [
        LogLine(seq: 1, ts: 1, text: "> vite"),
        LogLine(seq: 2, ts: 2, text: "  \u{1B}[32mVITE ready\u{1B}[0m"),
        LogLine(seq: 3, ts: 3, text: "\u{1B}[1;31merror\u{1B}[0m TS2304"),
    ]

    @Test("blank query keeps every line")
    func blankQueryKeepsEveryLine() {
        #expect(LogTranscriptText.visible(lines, query: "   ").map(\.seq) == [1, 2, 3])
    }

    @Test("filter ignores case and ansi codes")
    func filterIgnoresCaseAndAnsiCodes() {
        #expect(LogTranscriptText.visible(lines, query: "ERROR").map(\.seq) == [3])
        #expect(LogTranscriptText.visible(lines, query: "vite ready").map(\.seq) == [2])
    }

    @Test("plain text strips ansi codes and joins lines")
    func plainTextStripsAnsiCodesAndJoinsLines() {
        let text = LogTranscriptText.plainText(lines, showTimestamps: false)
        #expect(text == "> vite\n  VITE ready\nerror TS2304")
    }

    @Test("attributed text joins every line into one transcript")
    func attributedTextJoinsEveryLineIntoOneTranscript() {
        let text = LogTranscriptText.attributed(lines, showTimestamps: false)
        #expect(text.string == "> vite\n  VITE ready\nerror TS2304")
    }

    @Test("plain text prefixes timestamps when shown")
    func plainTextPrefixesTimestampsWhenShown() {
        let text = LogTranscriptText.plainText([lines[0]], showTimestamps: true)
        #expect(text == "\(LogTranscriptText.time(1)) > vite")
    }

    @Test("copy text keeps only the newest lines up to the limit")
    func copyTextKeepsOnlyTheNewestLinesUpToTheLimit() {
        let many = (1...LogTranscriptText.copyLineLimit + 5).map {
            LogLine(seq: UInt64($0), ts: Double($0), text: "line \($0)")
        }
        let text = LogTranscriptText.copyText(many, query: "", showTimestamps: false)
        let copied = text.split(separator: "\n")
        #expect(copied.count == LogTranscriptText.copyLineLimit)
        #expect(copied.first == "line 6")
        #expect(copied.last == "line \(LogTranscriptText.copyLineLimit + 5)")
    }

    @Test("copy text applies the filter before the limit")
    func copyTextAppliesTheFilterBeforeTheLimit() {
        let text = LogTranscriptText.copyText(lines, query: "error", showTimestamps: false)
        #expect(text == "error TS2304")
    }
}

@MainActor
@Suite("LogFollower filtering")
struct LogFollowerFilterTests {
    private func line(_ seq: UInt64, _ text: String) -> LogLine {
        LogLine(seq: seq, ts: Double(seq), text: text)
    }

    @Test("a blank query keeps every line")
    func blankQueryKeepsEveryLine() {
        let follower = LogFollower(service: "web")
        follower.lines = [line(1, "boot"), line(2, "error")]
        #expect(follower.visibleLines(matching: " ").map(\.seq) == [1, 2])
    }

    @Test("lines arriving after a filtered pass are matched and appended")
    func newLinesExtendTheFilteredResult() {
        let follower = LogFollower(service: "web")
        follower.lines = [line(1, "boot"), line(2, "error one")]
        #expect(follower.visibleLines(matching: "error").map(\.seq) == [2])

        follower.lines += [line(3, "ready"), line(4, "\u{1B}[31mERROR two\u{1B}[0m")]
        #expect(follower.visibleLines(matching: "error").map(\.seq) == [2, 4])
    }

    @Test("lines dropped off the top leave the filtered result")
    func droppedLinesLeaveTheFilteredResult() {
        let follower = LogFollower(service: "web")
        follower.lines = [line(1, "error one"), line(2, "error two")]
        #expect(follower.visibleLines(matching: "error").map(\.seq) == [1, 2])

        follower.lines = [line(2, "error two"), line(3, "error three")]
        #expect(follower.visibleLines(matching: "error").map(\.seq) == [2, 3])
    }

    @Test("changing the query refilters from scratch")
    func changingTheQueryRefilters() {
        let follower = LogFollower(service: "web")
        follower.lines = [line(1, "boot"), line(2, "error")]
        #expect(follower.visibleLines(matching: "error").map(\.seq) == [2])
        #expect(follower.visibleLines(matching: "boot").map(\.seq) == [1])
    }

    @Test("clearing drops the remembered matches")
    func clearingDropsRememberedMatches() {
        let follower = LogFollower(service: "web")
        follower.lines = [line(1, "error one")]
        #expect(follower.visibleLines(matching: "error").map(\.seq) == [1])

        follower.clear()
        follower.lines = [line(2, "error two")]
        #expect(follower.visibleLines(matching: "error").map(\.seq) == [2])
    }
}

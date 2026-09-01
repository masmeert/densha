import DenshaCore
import Testing

@testable import DenshaUI

@Suite("TranscriptEdit")
struct TranscriptEditTests {
    private func lines(_ seqs: [UInt64]) -> [LogLine] {
        seqs.map { LogLine(seq: $0, ts: Double($0), text: "line \($0)") }
    }

    @Test("new lines are appended to what is already shown")
    func newLinesAreAppended() {
        #expect(
            TranscriptEdit.plan(shown: [1, 2, 3], incoming: lines([1, 2, 3, 4, 5]))
                == .extend(dropLeading: 0, appendFrom: 3))
    }

    @Test("a trimmed head drops that many lines off the top")
    func aTrimmedHeadDropsLinesOffTheTop() {
        #expect(
            TranscriptEdit.plan(shown: [1, 2, 3], incoming: lines([3, 4]))
                == .extend(dropLeading: 2, appendFrom: 1))
    }

    @Test("an unchanged buffer is a no-op append")
    func anUnchangedBufferIsANoOpAppend() {
        #expect(
            TranscriptEdit.plan(shown: [1, 2], incoming: lines([1, 2]))
                == .extend(dropLeading: 0, appendFrom: 2))
    }

    @Test("the first lines of an empty view are an append")
    func theFirstLinesOfAnEmptyViewAreAnAppend() {
        #expect(
            TranscriptEdit.plan(shown: [], incoming: lines([7, 8]))
                == .extend(dropLeading: 0, appendFrom: 0))
    }

    @Test("a filter that hides lines in the middle forces a rebuild")
    func aFilterThatHidesLinesInTheMiddleForcesARebuild() {
        #expect(TranscriptEdit.plan(shown: [1, 2, 3], incoming: lines([1, 3])) == .rebuild)
    }

    @Test("clearing the view forces a rebuild")
    func clearingTheViewForcesARebuild() {
        #expect(TranscriptEdit.plan(shown: [1, 2], incoming: []) == .rebuild)
        #expect(
            TranscriptEdit.plan(shown: [], incoming: []) == .extend(dropLeading: 0, appendFrom: 0))
    }
}

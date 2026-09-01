import AppKit
import DenshaCore
import SwiftUI

/// What has to happen to the text storage to show `incoming` when `shown`
/// (the sequence numbers already on screen, in order) is what it holds.
enum TranscriptEdit: Equatable {
    /// Drop `dropLeading` lines off the top, then append `incoming[appendFrom...]`.
    case extend(dropLeading: Int, appendFrom: Int)
    case rebuild

    static func plan(shown: [UInt64], incoming: [LogLine]) -> TranscriptEdit {
        guard let first = incoming.first else {
            return shown.isEmpty ? .extend(dropLeading: 0, appendFrom: 0) : .rebuild
        }
        let keep = shown.drop { $0 < first.seq }
        guard keep.elementsEqual(incoming.prefix(keep.count).lazy.map(\.seq)) else {
            return .rebuild
        }
        return .extend(dropLeading: shown.count - keep.count, appendFrom: keep.count)
    }
}

/// The transcript is an NSTextView so selection, copy and find span the whole
/// buffer and TextKit only lays out the visible rows. Updates append to the
/// storage instead of rebuilding it, which is what makes a chatty service cheap.
struct LogTextView: NSViewRepresentable {
    let lines: [LogLine]
    let showTimestamps: Bool
    let following: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = AnsiRenderer.plainFont
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.apply(
            lines: lines, showTimestamps: showTimestamps, following: following)
    }

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        private var shown: [UInt64] = []
        private var showTimestamps = false

        func apply(lines: [LogLine], showTimestamps: Bool, following: Bool) {
            guard let storage = textView?.textStorage else { return }
            let edit =
                showTimestamps == self.showTimestamps
                ? TranscriptEdit.plan(shown: shown, incoming: lines)
                : .rebuild
            self.showTimestamps = showTimestamps

            switch edit {
            case .rebuild:
                storage.setAttributedString(render(lines, from: 0))
                shown = lines.map(\.seq)
            case .extend(let dropLeading, let appendFrom):
                guard dropLeading > 0 || appendFrom < lines.count else { return }
                storage.beginEditing()
                if dropLeading > 0 {
                    storage.deleteCharacters(in: leadingRange(dropLeading, in: storage.string))
                    shown.removeFirst(dropLeading)
                }
                if appendFrom < lines.count {
                    storage.append(render(lines, from: appendFrom))
                    shown.append(contentsOf: lines[appendFrom...].map(\.seq))
                }
                storage.endEditing()
            }

            if following, let textView {
                textView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
            }
        }

        /// Every line is stored with its trailing newline, so dropping the first
        /// `count` lines is dropping everything up to the `count`th one.
        private func leadingRange(_ count: Int, in string: String) -> NSRange {
            let text = string as NSString
            var location = 0
            for _ in 0..<count where location < text.length {
                location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
            }
            return NSRange(location: 0, length: location)
        }

        private func render(_ lines: [LogLine], from index: Int) -> NSAttributedString {
            let output = NSMutableAttributedString()
            for line in lines[index...] {
                output.append(LogTranscriptText.line(line, showTimestamps: showTimestamps))
                output.append(NSAttributedString(string: "\n"))
            }
            return output
        }
    }
}

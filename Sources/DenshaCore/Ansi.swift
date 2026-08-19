import Foundation

/// ANSI escape-sequence handling shared between the CLI and the log window.
public enum Ansi {
    /// Removes every escape sequence, leaving plain text. Used when output is piped,
    /// or when the user asks for --no-color.
    public static func strip(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var output = String()
        output.reserveCapacity(text.count)
        var iterator = text.makeIterator()
        var pending: Character?

        while let ch = pending ?? iterator.next() {
            pending = nil
            guard ch == "\u{1B}" else {
                output.append(ch)
                continue
            }
            guard let next = iterator.next() else { break }
            switch next {
            case "[":
                // CSI: parameter and intermediate bytes, then one final byte 0x40–0x7E.
                while let c = iterator.next() {
                    if let ascii = c.asciiValue, ascii >= 0x40, ascii <= 0x7E { break }
                }
            case "]":
                // OSC: runs until BEL or ST (ESC \).
                while let c = iterator.next() {
                    if c == "\u{07}" { break }
                    if c == "\u{1B}" {
                        if let after = iterator.next(), after != "\\" { pending = after }
                        break
                    }
                }
            case "P", "X", "^", "_":
                // DCS/SOS/PM/APC: also terminated by ST.
                while let c = iterator.next() {
                    if c == "\u{1B}" {
                        if let after = iterator.next(), after != "\\" { pending = after }
                        break
                    }
                }
            default:
                // Two-character escape; nothing to emit.
                break
            }
        }
        return output
    }

    /// Turns the backslash escapes a shell user would type into real control bytes, so
    /// `densha send web '\n'` sends a newline rather than two characters.
    public static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var output = String()
        var iterator = text.makeIterator()
        while let ch = iterator.next() {
            guard ch == "\\", let next = iterator.next() else {
                output.append(ch)
                continue
            }
            switch next {
            case "n": output.append("\n")
            case "r": output.append("\r")
            case "t": output.append("\t")
            case "e": output.append("\u{1B}")
            case "0": output.append("\u{00}")
            case "\\": output.append("\\")
            default:
                output.append(ch)
                output.append(next)
            }
        }
        return output
    }
}

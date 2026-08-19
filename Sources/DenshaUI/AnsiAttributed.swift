import DenshaCore
import SwiftUI

enum AnsiRenderer {
    struct Style: Equatable {
        var foreground: Color?
        var background: Color?
        var bold = false
        var dim = false
        var italic = false
        var underline = false

        mutating func reset() { self = Style() }
    }

    static func attributed(_ text: String, base: Color = .primary) -> AttributedString {
        guard text.contains("\u{1B}") else {
            var plain = AttributedString(text)
            plain.foregroundColor = base
            return plain
        }

        var output = AttributedString()
        var style = Style()
        var buffer = String()
        let scalars = Array(text)
        var index = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            var run = AttributedString(buffer)
            run.foregroundColor = style.foreground ?? base
            if let background = style.background { run.backgroundColor = background }
            if style.underline { run.underlineStyle = .single }
            if style.dim, style.foreground == nil { run.foregroundColor = base.opacity(0.6) }
            var font = Font.system(.body, design: .monospaced)
            if style.bold { font = font.bold() }
            if style.italic { font = font.italic() }
            run.font = font
            output.append(run)
            buffer.removeAll(keepingCapacity: true)
        }

        while index < scalars.count {
            let ch = scalars[index]
            guard ch == "\u{1B}", index + 1 < scalars.count else {
                buffer.append(ch)
                index += 1
                continue
            }

            let next = scalars[index + 1]
            if next == "[" {
                var cursor = index + 2
                var parameters = String()
                var final: Character?
                while cursor < scalars.count {
                    let c = scalars[cursor]
                    if let ascii = c.asciiValue, ascii >= 0x40, ascii <= 0x7E {
                        final = c
                        cursor += 1
                        break
                    }
                    parameters.append(c)
                    cursor += 1
                }
                if final == "m" {
                    flush()
                    apply(parameters, to: &style)
                }
                index = cursor
                continue
            }

            if next == "]" || next == "P" || next == "X" || next == "^" || next == "_" {
                var cursor = index + 2
                while cursor < scalars.count {
                    if scalars[cursor] == "\u{07}" {
                        cursor += 1
                        break
                    }
                    if scalars[cursor] == "\u{1B}" {
                        cursor +=
                            (cursor + 1 < scalars.count && scalars[cursor + 1] == "\\") ? 2 : 1
                        break
                    }
                    cursor += 1
                }
                index = cursor
                continue
            }

            index += 2
        }

        flush()
        return output
    }

    private static func apply(_ parameters: String, to style: inout Style) {
        let codes =
            parameters.isEmpty
            ? [0]
            : parameters.split(separator: ";", omittingEmptySubsequences: false).map {
                Int($0) ?? 0
            }

        var i = 0
        while i < codes.count {
            let code = codes[i]
            switch code {
            case 0: style.reset()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 22:
                style.bold = false
                style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 30...37: style.foreground = palette(code - 30)
            case 39: style.foreground = nil
            case 40...47: style.background = palette(code - 40)
            case 49: style.background = nil
            case 90...97: style.foreground = palette(code - 90 + 8)
            case 100...107: style.background = palette(code - 100 + 8)
            case 38, 48:
                guard i + 1 < codes.count else {
                    i = codes.count
                    break
                }
                let mode = codes[i + 1]
                if mode == 5, i + 2 < codes.count {
                    let color = xterm256(codes[i + 2])
                    if code == 38 { style.foreground = color } else { style.background = color }
                    i += 2
                } else if mode == 2, i + 4 < codes.count {
                    let color = Color(
                        .sRGB, red: Double(codes[i + 2]) / 255, green: Double(codes[i + 3]) / 255,
                        blue: Double(codes[i + 4]) / 255, opacity: 1)
                    if code == 38 { style.foreground = color } else { style.background = color }
                    i += 4
                } else {
                    i = codes.count
                }
            default:
                break
            }
            i += 1
        }
    }

    private static func palette(_ index: Int) -> Color {
        switch index {
        case 0: return Color(.sRGB, red: 0.20, green: 0.20, blue: 0.22, opacity: 1)
        case 1: return Color(.sRGB, red: 0.80, green: 0.21, blue: 0.24, opacity: 1)
        case 2: return Color(.sRGB, red: 0.11, green: 0.60, blue: 0.28, opacity: 1)
        case 3: return Color(.sRGB, red: 0.70, green: 0.52, blue: 0.00, opacity: 1)
        case 4: return Color(.sRGB, red: 0.15, green: 0.45, blue: 0.88, opacity: 1)
        case 5: return Color(.sRGB, red: 0.66, green: 0.28, blue: 0.76, opacity: 1)
        case 6: return Color(.sRGB, red: 0.10, green: 0.58, blue: 0.62, opacity: 1)
        case 7: return Color(.sRGB, red: 0.60, green: 0.60, blue: 0.62, opacity: 1)
        case 8: return Color(.sRGB, red: 0.42, green: 0.42, blue: 0.45, opacity: 1)
        case 9: return Color(.sRGB, red: 0.92, green: 0.34, blue: 0.34, opacity: 1)
        case 10: return Color(.sRGB, red: 0.22, green: 0.74, blue: 0.36, opacity: 1)
        case 11: return Color(.sRGB, red: 0.85, green: 0.66, blue: 0.13, opacity: 1)
        case 12: return Color(.sRGB, red: 0.34, green: 0.60, blue: 0.98, opacity: 1)
        case 13: return Color(.sRGB, red: 0.80, green: 0.44, blue: 0.90, opacity: 1)
        case 14: return Color(.sRGB, red: 0.24, green: 0.74, blue: 0.78, opacity: 1)
        default: return Color(.sRGB, red: 0.85, green: 0.85, blue: 0.87, opacity: 1)
        }
    }

    private static func xterm256(_ value: Int) -> Color {
        switch value {
        case 0..<16:
            return palette(value)
        case 16..<232:
            let offset = value - 16
            let steps = [0.0, 95.0, 135.0, 175.0, 215.0, 255.0]
            let r = steps[(offset / 36) % 6]
            let g = steps[(offset / 6) % 6]
            let b = steps[offset % 6]
            return Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: 1)
        case 232..<256:
            let level = Double(8 + (value - 232) * 10) / 255
            return Color(.sRGB, red: level, green: level, blue: level, opacity: 1)
        default:
            return .primary
        }
    }
}

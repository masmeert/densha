import SwiftUI

struct PlatformSign: View {
    let port: Int
    let tint: Color
    let animate: Bool

    var body: some View {
        Text(verbatim: "\(port)")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(tint.opacity(0.4), lineWidth: 1)
            )
            .animation(animate ? .easeOut(duration: 0.22) : nil, value: port)
            .accessibilityLabel("Port \(port)")
    }
}

#if DEBUG
    #Preview("Platform signs") {
        HStack(spacing: 8) {
            PlatformSign(port: 3000, tint: .secondary, animate: true)
            PlatformSign(port: 8081, tint: .secondary, animate: true)
            PlatformSign(port: 5432, tint: .orange, animate: true)
        }
        .padding()
    }
#endif

import DenshaCore
import SwiftUI

struct ScannedPortRow: View {
    let scanned: ScannedPort
    let onOpen: () -> Void
    let onCopyURL: () -> Void

    @State private var hovering = false

    private var conflicting: Bool { scanned.conflictsWith != nil }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Circle()
                    .strokeBorder(
                        conflicting ? Color.orange.opacity(0.9) : Color.secondary.opacity(0.5),
                        lineWidth: 1
                    )
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)

                Text(scanned.processName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                if let conflictsWith = scanned.conflictsWith {
                    Text(conflictsWith)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)

                Text(verbatim: ":\(scanned.port)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(
                        conflicting ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary)
                    )
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(accessibilityText)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .contextMenu {
            Button("Open in Browser") { onOpen() }
            Button("Copy Address") { onCopyURL() }
        }
    }

    private var helpText: String {
        var text = "\(scanned.processName) (pid \(scanned.pid))"
        if let conflictsWith = scanned.conflictsWith {
            text += " — holds the port \(conflictsWith) needs"
        }
        return text + " — open http://localhost:\(scanned.port)"
    }

    private var accessibilityText: String {
        if let conflictsWith = scanned.conflictsWith {
            return
                "Open port \(scanned.port), used by \(scanned.processName), needed by \(conflictsWith)"
        }
        return "Open port \(scanned.port), used by \(scanned.processName)"
    }
}

#if DEBUG
    #Preview("Scanned ports") {
        VStack(spacing: 2) {
            ForEach(Sample.scannedPorts) { scanned in
                ScannedPortRow(scanned: scanned, onOpen: {}, onCopyURL: {})
            }
        }
        .frame(width: 316)
        .padding(.vertical, 7)
    }
#endif

import DenshaCore
import SwiftUI

struct ScannedPortRow: View {
    let scanned: ScannedPort
    let killing: Bool
    let onOpen: () -> Void
    let onCopyURL: () -> Void
    let onKill: () -> Void

    @State private var hovering = false
    @State private var armed = false

    private var conflicting: Bool { scanned.conflictsWith != nil }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    UnsignalledMarker(
                        tint: conflicting ? Color.orange.opacity(0.9) : Color.secondary.opacity(0.5)
                    )

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

                    PlatformSign(
                        port: scanned.port,
                        tint: conflicting ? .orange : .secondary.opacity(0.6),
                        animate: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpText)
            .accessibilityLabel(accessibilityText)

            actions
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if !inside { armed = false }
        }
        .contextMenu {
            Button("Open in Browser") { onOpen() }
            Button("Copy Address") { onCopyURL() }
            Divider()
            Button("Kill \(scanned.processName)", role: .destructive) { onKill() }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 2) {
            Button(action: onCopyURL) {
                Image(systemName: "document.on.document")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle())
            .help("Copy http://localhost:\(scanned.port)")
            .accessibilityLabel("Copy the address of port \(scanned.port)")

            Button(action: onOpen) {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle())
            .help("Open http://localhost:\(scanned.port)")
            .accessibilityLabel("Open port \(scanned.port) in the browser")

            if killing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 21, height: 21)
            } else {
                Button(role: armed ? .destructive : nil) {
                    if armed {
                        armed = false
                        onKill()
                    } else {
                        armed = true
                    }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(armed ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                }
                .buttonStyle(IconButtonStyle(filled: armed ? .red : nil))
                .help(armed ? "Click again to kill" : killHelpText)
                .accessibilityLabel(
                    armed
                        ? "Confirm killing \(scanned.processName) on port \(scanned.port)"
                        : "Kill \(scanned.processName) on port \(scanned.port)")
            }
        }
        .opacity(hovering || killing ? 1 : 0)
        .animation(.easeOut(duration: 0.14), value: hovering)
    }

    private var helpText: String {
        var text = "\(scanned.processName) (pid \(scanned.pid))"
        if let conflictsWith = scanned.conflictsWith {
            text += " — holds the port \(conflictsWith) needs"
        }
        return text + " — open http://localhost:\(scanned.port)"
    }

    private var killHelpText: String {
        var text = "Kill \(scanned.processName) (pid \(scanned.pid))"
        if let conflictsWith = scanned.conflictsWith {
            text += " to free port \(scanned.port) for \(conflictsWith)"
        }
        return text
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
                ScannedPortRow(
                    scanned: scanned, killing: scanned.port == 6379,
                    onOpen: {}, onCopyURL: {}, onKill: {})
            }
        }
        .frame(width: 316)
        .padding(.vertical, 7)
    }
#endif

import DenshaCore
import SwiftUI

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 21, height: 21)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0))
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

struct ServiceRow: View {
    let service: ServiceStatus
    let busy: Bool
    let onToggle: () -> Void
    let onRestart: () -> Void
    let onShowLogs: () -> Void

    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var actionsVisible: Bool { hovering || focused || busy }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onShowLogs) {
                HStack(spacing: 10) {
                    SignalHead(
                        state: service.state, health: service.health, animate: !reduceMotion)

                    Text(service.shortName)
                        .font(.system(size: 13))
                        .foregroundStyle(service.isLive ? .primary : .secondary)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    if let port = service.port {
                        PlatformSign(
                            port: port, tint: .secondary.opacity(service.isLive ? 0.9 : 0.6),
                            animate: !reduceMotion)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpText)
            .accessibilityLabel("Open logs for \(service.name)")
            .accessibilityValue(stateDescription)

            HStack(spacing: 2) {
                Button(action: onRestart) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle())
                .help("Restart \(service.name)")
                .accessibilityLabel("Restart \(service.name)")
                .disabled(!service.isLive)
                .opacity(service.isLive ? 1 : 0.3)

                Button(action: onToggle) {
                    Image(systemName: service.isLive ? "stop.fill" : "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle())
                .focused($focused)
                .help(service.isLive ? "Stop \(service.name)" : "Start \(service.name)")
                .accessibilityLabel(
                    service.isLive ? "Stop \(service.name)" : "Start \(service.name)")
            }
            .opacity(actionsVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.14), value: actionsVisible)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var stateDescription: String {
        let aspect = SignalAspect(state: service.state, health: service.health)
        return "\(service.state.rawValue), signal \(aspect.description)"
    }

    private var helpText: String {
        var parts = [service.command]
        if let code = service.exitCode, service.state == .failed {
            parts.append("exited \(code)")
        }
        if let signal = service.signal {
            parts.append("signal \(signal)")
        }
        parts.append("in \(service.cwd)")
        return parts.joined(separator: " — ")
    }
}

#if DEBUG
    #Preview("Rows — every state") {
        VStack(spacing: 1) {
            ForEach(Sample.all) { service in
                ServiceRow(
                    service: service, busy: false,
                    onToggle: {}, onRestart: {}, onShowLogs: {})
            }
        }
        .frame(width: 316)
        .padding(.vertical, 7)
    }
#endif

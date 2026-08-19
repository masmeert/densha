import DenshaCore
import SwiftUI

/// Small square icon button with press feedback. A click must feel acknowledged
/// immediately, before any daemon round-trip has completed.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 21, height: 21)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0))
            )
            // Subtle, not springy: this fires many times a day.
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

struct StatusDot: View {
    let state: ServiceState
    let health: HealthState
    let animate: Bool

    @State private var pulsing = false

    private var color: Color {
        switch state {
        case .running: return health == .failing ? .orange : .green
        case .unhealthy: return .orange
        case .starting, .stopping: return .orange
        case .failed: return .red
        case .stopped, .exited: return .secondary.opacity(0.55)
        }
    }

    /// Only in-between states pulse; a steady service must look steady.
    private var isTransitional: Bool { state == .starting || state == .stopping }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulsing ? 0.35 : 1)
            .animation(.easeOut(duration: 0.2), value: color)
            .onChange(of: isTransitional, initial: true) { _, transitional in
                guard animate else {
                    pulsing = false
                    return
                }
                if transitional {
                    withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                        pulsing = true
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { pulsing = false }
                }
            }
            .accessibilityHidden(true)
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

    /// Actions are revealed on hover, but must also appear on keyboard focus —
    /// otherwise they would be unreachable without a mouse.
    private var actionsVisible: Bool { hovering || focused || busy }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: service.state, health: service.health, animate: !reduceMotion)

            Text(service.name)
                .font(.system(size: 13))
                .foregroundStyle(service.isLive ? .primary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 6)

            if let port = service.port {
                Text(":\(port)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

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
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        // The row itself opens logs; the buttons above handle lifecycle. One target,
        // one meaning.
        .onTapGesture(perform: onShowLogs)
        .onHover { hovering = $0 }
        .help(helpText)
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

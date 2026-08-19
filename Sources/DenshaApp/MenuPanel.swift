import DenshaCore
import SwiftUI

struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 4)
            content
            Divider().padding(.vertical, 4)
            footer
        }
        .padding(.vertical, 6)
        .frame(width: 296)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Densha")
                .font(.system(size: 13, weight: .semibold))
            if model.liveCount > 0 {
                Text("\(model.liveCount) running")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                Button("Edit services.toml…") { model.openConfigInEditor() }
                Button("Reload config") { model.reload() }
                Divider()
                Button("Open Logs…") { showLogs(nil) }
                Divider()
                Button("Quit Densha") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help("More")
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch model.link {
        case .connecting where model.services.isEmpty:
            notice("Connecting to denshad…", systemImage: "ellipsis.circle")
        case let .failed(reason):
            notice(reason, systemImage: "exclamationmark.triangle", tint: .orange)
        default:
            if model.services.isEmpty {
                emptyState
            } else {
                serviceList
            }
        }

        if let error = model.lastError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(3)
                .padding(.horizontal, 12)
                .padding(.top, 4)
        }

        ForEach(model.warnings, id: \.self) { warning in
            Text(warning)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .lineLimit(3)
                .padding(.horizontal, 12)
                .padding(.top, 2)
        }
    }

    private var serviceList: some View {
        VStack(spacing: 1) {
            ForEach(model.services) { service in
                ServiceRow(
                    service: service,
                    busy: model.busy.contains(service.name),
                    onToggle: { model.toggle(service) },
                    onRestart: { model.restart(service.name) },
                    onShowLogs: { showLogs(service.name) }
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No services yet")
                .font(.system(size: 12, weight: .medium))
            Text("Add a [[service]] block to services.toml to see it here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Edit services.toml…") { model.openConfigInEditor() }
                .controlSize(.small)
                .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func notice(_ text: String, systemImage: String, tint: Color = .secondary) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                FooterButton(
                    title: "Start all", systemImage: "play.fill",
                    disabled: model.services.allSatisfy(\.isLive) || model.services.isEmpty
                ) { model.startAll() }

                FooterButton(
                    title: "Stop all", systemImage: "stop.fill",
                    disabled: !model.anyLive
                ) { model.stopAll() }
            }
            .padding(.horizontal, 8)

            FooterRow(title: "Logs…", systemImage: "list.bullet.rectangle") { showLogs(nil) }
        }
    }

    private func showLogs(_ service: String?) {
        if let service {
            model.selectedLogService = service
        } else if model.selectedLogService == nil {
            model.selectedLogService = model.services.first(where: \.isLive)?.name
                ?? model.services.first?.name
        }
        openWindow(id: LogWindowID.value)
        // An accessory app does not come forward on its own.
        NSApp.activate(ignoringOtherApps: true)
        MenuBarPanel.dismiss()
    }
}

/// Prominent paired action at the bottom of the panel.
private struct FooterButton: View {
    let title: String
    let systemImage: String
    let disabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 12))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering && !disabled ? 0.09 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// Full-width menu-like row.
private struct FooterRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                    .frame(width: 12)
                Text(title).font(.system(size: 12))
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

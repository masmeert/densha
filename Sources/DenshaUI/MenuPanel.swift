import DenshaCore
import SwiftUI

public struct MenuPanel: View {
    public init() {}

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    private let updater = Updater.shared

    @AppStorage("scannedPortsExpanded") private var scannedPortsExpanded = false
    @AppStorage("collapsedGroups") private var collapsedGroupsData = Data()

    private static let visiblePortRows = 6

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
            Divider()
            footer
        }
        .frame(width: 316)
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Densha")
                    .font(.system(size: 13, weight: .semibold))
                if model.liveCount > 0 {
                    Text("\(model.liveCount) in service")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                showNewService()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle())
            .help("Add a service")
            .accessibilityLabel("Add a service")
            Menu {
                Button("Edit services.toml…") { model.openConfigInEditor() }
                Button("Reload config") { model.reload() }
                Divider()
                Button("Open Logs…") { showLogs(nil) }
                Divider()
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Button("Densha on GitHub") { model.openProjectPage() }
                Divider()
                Button("Quit Densha") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24, height: 24)
            .help("More")
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    @ViewBuilder
    private var content: some View {
        switch model.link {
        case .connecting where model.services.isEmpty:
            notice("Connecting to denshad…", systemImage: "ellipsis.circle")
        case .failed(let reason):
            notice(reason, systemImage: "exclamationmark.triangle", tint: .orange)
        default:
            if model.services.isEmpty {
                emptyState
            } else {
                ForEach(model.groups) { group in
                    serviceList(group)
                }
            }
            if !model.scannedPorts.isEmpty {
                scannedPortSection
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

    private func serviceList(_ group: AppModel.ServiceGroup) -> some View {
        let expanded = !collapsedGroups.contains(group.id)

        return VStack(alignment: .leading, spacing: 2) {
            GroupHeader(
                project: group.project,
                count: group.services.count,
                aspect: SignalAspect(worstOf: group.services),
                expanded: expanded,
                canStart: !group.allLive,
                canStop: group.anyLive,
                onToggle: { toggleCollapsed(group) },
                onStart: { model.start(group) },
                onStop: { model.stop(group) },
                onAddService: { showNewService(project: group.project) }
            )
            if expanded {
                ForEach(group.services) { service in
                    ServiceRow(
                        service: service,
                        busy: model.busy.contains(service.name),
                        onToggle: { model.toggle(service) },
                        onRestart: { model.restart(service.name) },
                        onShowLogs: { showLogs(service.name) },
                        onEdit: { showEditService(service) },
                        onReveal: { model.revealInFinder(service) }
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.bottom, 8)
        .clipped()
    }

    private var collapsedGroups: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: collapsedGroupsData)) ?? []
    }

    private func toggleCollapsed(_ group: AppModel.ServiceGroup) {
        var collapsed = collapsedGroups
        collapsed.formSymmetricDifference([group.id])
        guard let encoded = try? JSONEncoder().encode(collapsed) else { return }
        withAnimation(.easeOut(duration: 0.18)) { collapsedGroupsData = encoded }
    }

    private var scannedPortSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(
                title: "Other ports",
                count: model.scannedPorts.count,
                expanded: scannedPortsExpanded,
                help: "Listening ports that no service in services.toml claims",
                accessibilityValue: scannedPortsExpanded ? "Expanded" : "Collapsed",
                onToggle: {
                    withAnimation(.easeOut(duration: 0.18)) { scannedPortsExpanded.toggle() }
                }
            ) {}

            if scannedPortsExpanded {
                ScrollView(.vertical) {
                    VStack(spacing: 2) {
                        ForEach(model.scannedPorts) { scanned in
                            ScannedPortRow(
                                scanned: scanned,
                                onOpen: { model.openInBrowser(scanned) },
                                onCopyURL: {
                                    model.copyToClipboard("http://localhost:\(scanned.port)")
                                }
                            )
                        }
                    }
                }
                .frame(
                    height: CGFloat(min(model.scannedPorts.count, Self.visiblePortRows)) * 30 - 2
                )
                .scrollBounceBehavior(.basedOnSize)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.bottom, 8)
        .clipped()
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No services yet")
                .font(.system(size: 12, weight: .medium))
            Text("Point Densha at a folder and it picks up the project name from there.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Add a service…") { showNewService() }
                Button("Edit services.toml…") { model.openConfigInEditor() }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func notice(_ text: String, systemImage: String, tint: Color = .secondary) -> some View
    {
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

    private var footer: some View {
        HStack(spacing: 8) {
            FooterButton(
                title: "Stop all", systemImage: "stop.fill",
                disabled: !model.anyLive
            ) { model.stopAll() }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func showNewService(project: String? = nil) {
        model.requestNewService(project: project)
        showServiceEditor()
    }

    private func showEditService(_ service: ServiceStatus) {
        model.requestEdit(service)
        showServiceEditor()
    }

    private func showServiceEditor() {
        openWindow(id: ServiceEditorWindowID.value)
        NSApp.activate(ignoringOtherApps: true)
        MenuBarPanel.dismiss()
    }

    private func showLogs(_ service: String?) {
        if let service {
            model.selectedLogService = service
        } else if model.selectedLogService == nil {
            model.selectedLogService =
                model.services.first(where: \.isLive)?.name
                ?? model.services.first?.name
        }
        openWindow(id: LogWindowID.value)
        NSApp.activate(ignoringOtherApps: true)
        MenuBarPanel.dismiss()
    }
}

private struct SectionHeader<Actions: View>: View {
    let title: String
    let count: Int
    let expanded: Bool
    var aspect: SignalAspect?
    let help: String
    let accessibilityValue: String
    let onToggle: () -> Void
    @ViewBuilder let actions: () -> Actions

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: SignalMetrics.width)

                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text("\(count)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.quaternary)
                            .monospacedDigit()

                        if !expanded, let aspect {
                            SignalHead(
                                aspect: aspect, orientation: .horizontal, animate: !reduceMotion)
                        }
                    }

                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(title)
            .accessibilityValue(accessibilityValue)

            HStack(spacing: 2) {
                actions()
            }
        }
        .frame(minHeight: 21)
        .opacity(hovering ? 1 : 0.85)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .onHover { hovering = $0 }
    }
}

private struct GroupHeader: View {
    let project: String?
    let count: Int
    let aspect: SignalAspect
    let expanded: Bool
    let canStart: Bool
    let canStop: Bool
    let onToggle: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onAddService: () -> Void

    private var title: String { project ?? "Services" }
    private var subject: String { project ?? "every ungrouped service" }

    var body: some View {
        SectionHeader(
            title: title,
            count: count,
            expanded: expanded,
            aspect: aspect,
            help: expanded ? "Hide \(subject)" : "Show \(subject)",
            accessibilityValue: expanded
                ? "Expanded, \(count) services"
                : "Collapsed, \(count) services, signal \(aspect.description)",
            onToggle: onToggle
        ) {
            Button(action: onStart) {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle())
            .disabled(!canStart)
            .opacity(canStart ? 1 : 0.3)
            .help("Start \(subject)")
            .accessibilityLabel("Start \(subject)")

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle())
            .disabled(!canStop)
            .opacity(canStop ? 1 : 0.3)
            .help("Stop \(subject)")
            .accessibilityLabel("Stop \(subject)")
        }
        .contextMenu {
            Button(project.map { "New Service in \($0)…" } ?? "New Service…", action: onAddService)
        }
    }
}

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
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
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

#if DEBUG
    #Preview("Panel — mixed states") {
        MenuPanel().environment(AppModel.preview())
    }

    #Preview("Panel — all stopped") {
        MenuPanel().environment(
            AppModel.preview(services: [Sample.worker, Sample.otherWeb]))
    }

    #Preview("Panel — scanned ports") {
        MenuPanel().environment(
            AppModel.preview(scannedPorts: Sample.scannedPorts))
    }

    #Preview("Panel — no services") {
        MenuPanel().environment(AppModel.preview(services: []))
    }

    #Preview("Panel — daemon down") {
        MenuPanel().environment(
            AppModel.preview(services: [], link: .failed("denshad closed the connection")))
    }

    #Preview("Panel — config warning") {
        MenuPanel().environment(
            AppModel.preview(
                warnings: ["service \"warehouse\": cwd does not exist: /Users/you/work/gone"],
                lastError: "api: cannot use cwd /nope: no such directory"))
    }
#endif

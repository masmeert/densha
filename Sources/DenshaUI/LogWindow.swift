import DenshaCore
import Foundation
import SwiftUI

public enum LogWindowID {
    public static let value = "densha.logs"
}

public struct LogWindow: View {
    @Environment(AppModel.self) private var model

    @State private var session = LogSession()
    @State private var query = ""
    @State private var following = true
    @State private var showTimestamps = false
    @State private var keysToSend = ""

    public init() {}

    private var selectedService: String? {
        if let selectedLogService = model.selectedLogService,
            model.services.contains(where: { $0.name == selectedLogService })
        {
            return selectedLogService
        }
        return model.services.first?.name
    }

    public var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            if let name = selectedService, let follower = session.follower {
                LogTranscript(
                    follower: follower,
                    query: query,
                    following: following,
                    showTimestamps: showTimestamps
                )
                Divider()
                LogInputBar(
                    name: name,
                    running: model.services.first { $0.name == name }?.isLive ?? false,
                    keys: $keysToSend,
                    send: model.send
                )
            } else {
                ContentUnavailableView(
                    "No service selected", systemImage: "list.bullet.rectangle",
                    description: Text("Pick a service to see its output."))
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .toolbar {
            LogToolbar(
                services: model.services,
                selection: $model.selectedLogService,
                following: $following,
                showTimestamps: $showTimestamps,
                copy: {
                    model.copyToClipboard(
                        LogTranscriptText.copyText(
                            session.follower?.lines ?? [], query: query,
                            showTimestamps: showTimestamps))
                },
                download: {
                    if let name = selectedService { model.saveLogFile(for: name) }
                },
                clear: { session.follower?.clear() }
            )
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Filter logs")
        .onAppear {
            selectService(selectedService)
        }
        .onChange(of: selectedService) { _, name in
            selectService(name)
        }
        .onDisappear {
            session.stop()
        }
    }

    private func selectService(_ service: String?) {
        if model.selectedLogService != service {
            model.selectedLogService = service
        }
        session.select(service)
    }
}

private struct LogToolbar: ToolbarContent {
    let services: [ServiceStatus]
    @Binding var selection: String?
    @Binding var following: Bool
    @Binding var showTimestamps: Bool
    let copy: () -> Void
    let download: () -> Void
    let clear: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("", selection: $selection) {
                ForEach(services) { service in
                    Text(service.name).tag(Optional(service.name))
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .help("Select service")
            .accessibilityLabel("Service")
        }

        ToolbarSpacer(.flexible)

        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $following) {
                Image(systemName: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help("Follow new output")
            .accessibilityLabel("Follow new output")

            Toggle(isOn: $showTimestamps) {
                Image(systemName: "clock")
            }
            .toggleStyle(.button)
            .help("Show timestamps")
            .accessibilityLabel("Show timestamps")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: copy) {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy visible log lines (last \(LogTranscriptText.copyLineLimit))")
            .accessibilityLabel("Copy visible log lines")

            Menu {
                Button("Save Full Log…", systemImage: "square.and.arrow.down", action: download)
                Divider()
                Button(role: .destructive, action: clear) {
                    Label("Clear View", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .help("More log actions")
            .accessibilityLabel("More log actions")
        }
    }
}

private struct LogTranscript: View {
    let follower: LogFollower
    let query: String
    let following: Bool
    let showTimestamps: Bool

    private static let bottomAnchor = UInt64.max

    private var lines: [LogLine] {
        LogTranscriptText.visible(follower.lines, query: query)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let failure = follower.failure {
                        Text(failure)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .padding(8)
                    }
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 8) {
                            if showTimestamps {
                                Text(LogTranscriptText.time(line.ts))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                            }
                            Text(AnsiRenderer.attributed(line.text))
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                        .id(line.seq)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.vertical, 4)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: lines.last?.seq) { _, _ in
                guard following else { return }
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .onChange(of: following) { _, isFollowing in
                if isFollowing { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
        }
    }
}

@MainActor
enum LogTranscriptText {
    static let copyLineLimit = 2000

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func visible(_ lines: [LogLine], query: String) -> [LogLine] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        guard !trimmedQuery.isEmpty else { return lines }
        return lines.filter {
            Ansi.strip($0.text).localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    static func copyText(_ lines: [LogLine], query: String, showTimestamps: Bool) -> String {
        let capped = visible(lines, query: query).suffix(copyLineLimit)
        return plainText(Array(capped), showTimestamps: showTimestamps)
    }

    static func plainText(_ lines: [LogLine], showTimestamps: Bool) -> String {
        lines.map { line in
            let text = Ansi.strip(line.text)
            return showTimestamps ? "\(time(line.ts)) \(text)" : text
        }
        .joined(separator: "\n")
    }

    static func time(_ timestamp: Double) -> String {
        formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

private struct LogInputBar: View {
    let name: String
    let running: Bool
    @Binding var keys: String
    let send: (String, String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            TextField(
                running
                    ? "Send keys to \(name) — e.g. i, a, r for Expo"
                    : "\(name) is not running",
                text: $keys
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .disabled(!running)
            .onSubmit(sendKeys)
            Button("Send", action: sendKeys)
                .controlSize(.small)
                .disabled(!running || keys.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func sendKeys() {
        guard !keys.isEmpty else { return }
        send(keys, name)
        keys = ""
    }
}

#if DEBUG
    #Preview("Log window") {
        LogWindow().environment(AppModel.preview())
    }
#endif

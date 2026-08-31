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
            LogToolbar(
                services: model.services,
                selection: $model.selectedLogService,
                query: $query,
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
            Divider()
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

private struct LogToolbar: View {
    let services: [ServiceStatus]
    @Binding var selection: String?
    @Binding var query: String
    @Binding var following: Bool
    @Binding var showTimestamps: Bool
    let copy: () -> Void
    let download: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $selection) {
                ForEach(services) { service in
                    Text(service.name).tag(Optional(service.name))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 180)

            Spacer()

            TextField("Filter", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)

            Toggle(isOn: $following) {
                Image(systemName: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help("Follow new output")

            Toggle(isOn: $showTimestamps) {
                Image(systemName: "clock")
            }
            .toggleStyle(.button)
            .help("Show timestamps")

            Button(action: copy) {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy visible log lines (last \(LogTranscriptText.copyLineLimit))")

            Button(action: download) {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Save the full log file…")

            Button(action: clear) {
                Image(systemName: "trash")
            }
            .help("Clear this view (does not touch the log file)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private struct LogTranscript: View {
    let follower: LogFollower
    let query: String
    let following: Bool
    let showTimestamps: Bool

    private var lines: [LogLine] {
        LogTranscriptText.visible(follower.lines, query: query)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let failure = follower.failure {
                        Text(failure)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .padding(8)
                    }
                    Text(LogTranscriptText.attributed(lines, showTimestamps: showTimestamps))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                    Color.clear.frame(height: 0).id("bottom")
                }
                .padding(.vertical, 4)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(following ? .bottom : nil, for: .sizeChanges)
            // defaultScrollAnchor only applies on size changes, so the jump when
            // follow turns back on still needs a proxy.
            .onChange(of: following) { _, isFollowing in
                guard isFollowing else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
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

    static func attributed(_ lines: [LogLine], showTimestamps: Bool) -> AttributedString {
        var output = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { output.append(AttributedString("\n")) }
            if showTimestamps {
                var timestamp = AttributedString("\(time(line.ts)) ")
                timestamp.font = .system(size: 11, design: .monospaced)
                timestamp.foregroundColor = .secondary
                output.append(timestamp)
            }
            output.append(AnsiRenderer.attributed(line.text))
        }
        return output
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

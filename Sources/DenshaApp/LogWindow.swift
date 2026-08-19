import DenshaCore
import SwiftUI

enum LogWindowID {
    static let value = "densha.logs"
}

struct LogWindow: View {
    @Environment(AppModel.self) private var model

    @State private var followers: [String: LogFollower] = [:]
    @State private var query = ""
    @State private var following = true
    @State private var showTimestamps = false
    @State private var keysToSend = ""

    private var selected: String? {
        model.selectedLogService ?? model.services.first?.name
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let name = selected, let follower = followers[name] {
                transcript(follower)
                Divider()
                inputBar(name: name, running: model.services.first { $0.name == name }?.isLive ?? false)
            } else {
                ContentUnavailableView(
                    "No service selected", systemImage: "list.bullet.rectangle",
                    description: Text("Pick a service to see its output."))
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .onChange(of: selected, initial: true) { _, name in
            guard let name else { return }
            ensureFollower(name)
        }
        .onDisappear {
            for follower in followers.values { follower.stop() }
            followers.removeAll()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { selected ?? "" },
                set: { model.selectedLogService = $0 }
            )) {
                ForEach(model.services) { service in
                    Text(service.name).tag(service.name)
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

            Button {
                if let name = selected { followers[name]?.clear() }
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear this view (does not touch the log file)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: - Transcript

    private func transcript(_ follower: LogFollower) -> some View {
        let lines = filtered(follower.lines)
        return ScrollViewReader { proxy in
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
                                Text(Self.time(line.ts))
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
                    // Anchor for scroll-to-bottom that exists even when empty.
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.vertical, 4)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: lines.last?.seq) { _, _ in
                guard following else { return }
                // No animation: output can arrive many times a second, and animating
                // each arrival would make the view feel busy and lag behind.
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
            .onChange(of: following) { _, isFollowing in
                if isFollowing { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
        }
    }

    private var bottomAnchor: UInt64 { UInt64.max }

    private func filtered(_ lines: [LogLine]) -> [LogLine] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return lines }
        // Match against stripped text so a search never has to account for escapes.
        return lines.filter {
            Ansi.strip($0.text).localizedCaseInsensitiveContains(trimmed)
        }
    }

    // MARK: - Input

    private func inputBar(name: String, running: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            TextField(
                running
                    ? "Send keys to \(name) — e.g. i, a, r for Expo"
                    : "\(name) is not running",
                text: $keysToSend
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .disabled(!running)
            .onSubmit {
                guard !keysToSend.isEmpty else { return }
                model.send(keysToSend + "\n", to: name)
                keysToSend = ""
            }
            Button("Send") {
                model.send(keysToSend + "\n", to: name)
                keysToSend = ""
            }
            .controlSize(.small)
            .disabled(!running || keysToSend.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func ensureFollower(_ name: String) {
        if followers[name] == nil {
            let follower = LogFollower(service: name)
            followers[name] = follower
            follower.start()
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func time(_ ts: Double) -> String {
        formatter.string(from: Date(timeIntervalSince1970: ts))
    }
}

import AppKit
import DenshaCore
import Foundation
import UniformTypeIdentifiers

@MainActor
protocol ApplicationActions: AnyObject {
    func revealInFinder(path: String)
    func openConfig() throws
    func open(_ url: URL)
    func copyToClipboard(_ text: String)
    func saveLogFile(for service: String) throws
}

@MainActor
final class MacApplicationActions: ApplicationActions {
    func revealInFinder(path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func openConfig() throws {
        let url = Paths.configFile
        if !FileManager.default.fileExists(atPath: url.path) {
            try Paths.createDirectories()
            try Template.starter.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func saveLogFile(for service: String) throws {
        let fileManager = FileManager.default
        let sources = Paths.logFiles(for: service).filter {
            fileManager.fileExists(atPath: $0.path)
        }
        guard !sources.isEmpty else { throw DenshaError.noLogFile(service) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"

        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            "\(ServiceName.short(of: service))-\(formatter.string(from: Date())).log"
        panel.allowedContentTypes = [.log]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        var text = ""
        for source in sources {
            text += LogStore.plainText(try Data(contentsOf: source))
        }
        try text.write(to: destination, atomically: true, encoding: .utf8)
    }
}

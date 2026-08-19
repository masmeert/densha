import AppKit
import DenshaCore
import Foundation

@MainActor
protocol ApplicationActions: AnyObject {
    func revealInFinder(path: String)
    func openConfig() throws
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
}

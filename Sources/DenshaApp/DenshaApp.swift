import AppKit
import DenshaCore
import DenshaUI
import Observation
import SwiftUI

@main
struct DenshaApp: App {
    @State private var model = AppModel()
    // Never read, but initializing Updater.shared starts Sparkle's scheduled update checks.
    private let updater = Updater.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environment(model)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: model.menuBarSymbol)
                if model.powerOverrideActive {
                    Image(systemName: "cup.and.saucer.fill")
                }
            }
            .onAppear { model.connect() }
            .accessibilityLabel(
                model.anyFailed
                    ? "Densha, a service failed"
                    : "Densha, \(model.liveCount) running")
        }
        .menuBarExtraStyle(.window)

        Window("Logs", id: LogWindowID.value) {
            LogWindow()
                .environment(model)
        }
        .defaultSize(width: 760, height: 460)
        .commandsRemoved()

        Window("New Service", id: ServiceEditorWindowID.value) {
            ServiceEditorWindow()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()
    }
}

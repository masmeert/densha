import AppKit
import DenshaCore
import DenshaUI
import Observation
import SwiftUI

@main
struct DenshaApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environment(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
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
    }
}

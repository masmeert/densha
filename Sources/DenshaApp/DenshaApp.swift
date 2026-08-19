import AppKit
import DenshaCore
import SwiftUI

/// Best-effort dismissal of the MenuBarExtra panel.
///
/// SwiftUI exposes no API for this in `.window` style, so the panel is located by
/// class name. If Apple renames it the panel simply stays open behind the log
/// window, which is untidy but harmless — never a crash, and never a lost action.
enum MenuBarPanel {
    @MainActor
    static func dismiss() {
        for window in NSApp.windows where window.isVisible {
            let type = String(describing: Swift.type(of: window))
            if type.contains("MenuBarExtra") || type.contains("NSStatusBarWindow") {
                window.orderOut(nil)
            }
        }
    }
}

@main
struct DenshaApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environment(model)
        } label: {
            // Filled while anything runs, hollow when the stack is idle: readable at a
            // glance without needing colour, which the menu bar may not honour.
            // Connect from the label, not the content: MenuBarExtra builds its content
            // lazily on first open, so connecting there would leave the icon unable to
            // show state — and the daemon unstarted — until the user clicked.
            Image(systemName: model.menuBarSymbol)
                .onAppear { model.connect() }
                .accessibilityLabel(
                    model.anyFailed
                        ? "Densha, a service failed"
                        : "Densha, \(model.liveCount) running")
        }
        // .window rather than .menu: the rows carry per-service action buttons, which a
        // real NSMenu cannot express (one menu item is one click target).
        .menuBarExtraStyle(.window)

        Window("Logs", id: LogWindowID.value) {
            LogWindow()
                .environment(model)
        }
        .defaultSize(width: 760, height: 460)
        .commandsRemoved()
    }
}

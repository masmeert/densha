import AppKit
import SwiftUI

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

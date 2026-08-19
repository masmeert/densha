import Foundation
import Observation
import Sparkle

@MainActor
@Observable
public final class Updater {
    public static let shared = Updater()

    public private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        canCheckForUpdates = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            updater, _ in
            let allowed = updater.canCheckForUpdates
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = allowed
            }
        }
    }

    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

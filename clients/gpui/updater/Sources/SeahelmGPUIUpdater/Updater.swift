import AppKit
import Sparkle

@MainActor
private final class UpdaterLifetime {
    static let shared = UpdaterLifetime()
    private var controller: SPUStandardUpdaterController?

    func start(enabled: Bool, intervalHours: Int) {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.updateCheckInterval = TimeInterval(max(1, intervalHours) * 3600)
        controller.updater.automaticallyChecksForUpdates = enabled
        controller.startUpdater()
        self.controller = controller
    }
}

@_cdecl("seahelm_gpui_start_updater")
public func seahelmGPUIStartUpdater(_ enabled: Int32, _ intervalHours: Int32) {
    Task { @MainActor in
        UpdaterLifetime.shared.start(enabled: enabled != 0, intervalHours: Int(intervalHours))
    }
}

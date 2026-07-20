import AppKit
import Sparkle

/// Owns the Sparkle updater and wires it to seahelm's inline update banner.
///
/// Replaces the hand-rolled checker/downloader/installer trio. Sparkle brings
/// EdDSA signature verification of the feed (the old path only ran `codesign`,
/// which proves *some* valid developer signed the bundle, not that we shipped
/// that build), delta updates, and an installer that survives the cases the old
/// detached bash swap script did not.
final class UpdateCoordinator: NSObject {
    static let repositoryOwner = "BetaYao"
    static let repositoryName = "seahelm"

    /// One appcast per CPU arch: we publish arch-specific zips and Sparkle has no
    /// built-in arch filtering, so the feed is selected at runtime instead of
    /// being baked into Info.plist. `releases/latest/download/` is GitHub's
    /// stable redirect to the newest non-prerelease — which also means tags
    /// containing `-` (published as prereleases) stay out of the stable feed.
    static var feedURLString: String {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return "https://github.com/\(repositoryOwner)/\(repositoryName)"
            + "/releases/latest/download/appcast-\(arch).xml"
    }

    var config: Config

    let banner = UpdateBanner()
    private var updater: SPUUpdater?
    private var driver: UpdateDriver?

    init(config: Config) {
        self.config = config
        super.init()
    }

    func setup(config: Config) {
        self.config = config
        guard updater == nil else { return }

        let driver = UpdateDriver(banner: banner) { [weak self] state in
            self?.banner.update(state: state)
        }
        self.driver = driver

        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: self
        )
        self.updater = updater

        migrateSkippedVersionIfNeeded()

        updater.automaticallyChecksForUpdates = config.autoUpdate.enabled
        updater.automaticallyDownloadsUpdates = false
        // Sparkle floors this at one hour; config values below that would be
        // silently clamped, so clamp explicitly rather than pretend otherwise.
        updater.updateCheckInterval = TimeInterval(max(1, config.autoUpdate.checkIntervalHours) * 3600)

        do {
            try updater.start()
        } catch {
            // Most commonly a missing/blank SUPublicEDKey. Log rather than alert:
            // this runs at launch and a modal here would block the window.
            NSLog("Sparkle failed to start: \(error)")
            self.updater = nil
            self.driver = nil
        }
    }

    /// Hand the old JSON-config skip over to Sparkle's own store, once. Without
    /// this, anyone who had skipped a version would be re-prompted for it.
    private func migrateSkippedVersionIfNeeded() {
        guard let skipped = config.autoUpdate.skippedVersion, !skipped.isEmpty else { return }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "SUSkippedVersion") == nil {
            defaults.set(skipped, forKey: "SUSkippedVersion")
        }
        config.autoUpdate.skippedVersion = nil
        config.save()
    }

    @objc func checkForUpdates() {
        guard let updater, let driver else {
            let alert = NSAlert()
            alert.messageText = "Updates unavailable"
            alert.informativeText = "The updater failed to start. See Console for details."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        driver.isUserInitiated = true
        updater.checkForUpdates()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(checkForUpdates) else { return true }
        return updater?.canCheckForUpdates ?? false
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateCoordinator: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.feedURLString
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        driver?.isUserInitiated = false
    }
}

// MARK: - UpdateBannerDelegate

extension UpdateCoordinator: UpdateBannerDelegate {
    func updateBannerDidClickInstall(_ banner: UpdateBanner) {
        driver?.confirmInstall()
    }

    func updateBannerDidClickSkip(_ banner: UpdateBanner) {
        driver?.skipCurrentUpdate()
    }

    func updateBannerDidClickRestart(_ banner: UpdateBanner) {
        driver?.installAndRelaunch()
    }

    func updateBannerDidClickRetry(_ banner: UpdateBanner) {
        checkForUpdates()
    }
}

import AppKit

protocol UpdateCoordinatorDelegate: AnyObject {
    func updateCoordinator(_ coordinator: UpdateCoordinator, showBanner banner: UpdateBanner)
}

class UpdateCoordinator {
    weak var delegate: UpdateCoordinatorDelegate?
    var config: Config

    let updateChecker: UpdateChecker
    let updateManager: UpdateManaging
    let banner = UpdateBanner()
    var pendingRelease: ReleaseInfo?
    private var downloadingVersion: String?

    init(
        config: Config,
        updateChecker: UpdateChecker = UpdateChecker(),
        updateManager: UpdateManaging = UpdateManager()
    ) {
        self.config = config
        self.updateChecker = updateChecker
        self.updateManager = updateManager
    }

    func setup(config: Config) {
        self.config = config
        guard config.autoUpdate.enabled else { return }
        updateChecker.delegate = self
        updateChecker.skippedVersion = config.autoUpdate.skippedVersion
        updateManager.delegate = self
        updateChecker.startPolling(intervalHours: config.autoUpdate.checkIntervalHours)
    }

    func checkForUpdates() {
        Task {
            do {
                if let release = try await updateChecker.checkNow() {
                    await MainActor.run { self.beginUpdateFlow(release: release) }
                } else {
                    await MainActor.run {
                        let alert = NSAlert()
                        alert.messageText = "Already up to date"
                        alert.informativeText = "Current version v\(updateChecker.currentVersion) is the latest."
                        alert.alertStyle = .informational
                        alert.runModal()
                    }
                }
            } catch {
                // A manual check must always answer. Swallowing this is why the
                // menu item looked dead while the checker was 404ing.
                NSLog("Update check failed: \(error)")
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't check for updates"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    func handleSkip(version: String) {
        config.autoUpdate.skippedVersion = version
        config.save()
        updateChecker.skippedVersion = version
        banner.dismiss()
        pendingRelease = nil
        if downloadingVersion == version {
            downloadingVersion = nil
        }
    }

    private func beginUpdateFlow(release: ReleaseInfo) {
        pendingRelease = release
        banner.showNewVersion(release.version)

        guard downloadingVersion != release.version else { return }
        downloadingVersion = release.version
        updateManager.download(release: release)
    }
}

// MARK: - UpdateCheckerDelegate

extension UpdateCoordinator: UpdateCheckerDelegate {
    func updateChecker(_ checker: UpdateChecker, didFindRelease release: ReleaseInfo) {
        beginUpdateFlow(release: release)
    }
}

// MARK: - UpdateManagerDelegate

extension UpdateCoordinator: UpdateManagerDelegate {
    func updateManager(_ manager: UpdateManaging, didChangeState state: UpdateManager.State) {
        switch state {
        case .idle, .readyToInstall, .failed:
            downloadingVersion = nil
        case .downloading, .extracting, .verifying:
            break
        }
        banner.update(state: state)
    }
}

// MARK: - UpdateBannerDelegate

extension UpdateCoordinator: UpdateBannerDelegate {
    func updateBannerDidClickInstall(_ banner: UpdateBanner) {
        guard let release = pendingRelease else { return }
        updateManager.download(release: release)
    }

    func updateBannerDidClickSkip(_ banner: UpdateBanner) {
        handleSkip(version: banner.version)
    }

    func updateBannerDidClickRestart(_ banner: UpdateBanner) {
        updateManager.installAndRestart()
    }

    func updateBannerDidClickRetry(_ banner: UpdateBanner) {
        guard let release = pendingRelease else { return }
        updateManager.download(release: release)
    }
}

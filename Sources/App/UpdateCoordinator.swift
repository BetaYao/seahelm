import AppKit

protocol UpdateCoordinatorDelegate: AnyObject {
    func updateCoordinator(_ coordinator: UpdateCoordinator, showBanner banner: UpdateBanner)
}

class UpdateCoordinator {
    weak var delegate: UpdateCoordinatorDelegate?
    var config: Config

    let updateChecker = UpdateChecker()
    let updateManager = UpdateManager()
    let banner = UpdateBanner()
    var pendingRelease: ReleaseInfo?

    init(config: Config) {
        self.config = config
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
                    pendingRelease = release
                    banner.showNewVersion(release.version)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Already up to date"
                    alert.informativeText = "Current version v\(updateChecker.currentVersion) is the latest."
                    alert.alertStyle = .informational
                    alert.runModal()
                }
            } catch {
                NSLog("Update check failed: \(error)")
            }
        }
    }

    func handleSkip(version: String) {
        config.autoUpdate.skippedVersion = version
        config.save()
        updateChecker.skippedVersion = version
        banner.dismiss()
        pendingRelease = nil
    }
}

// MARK: - UpdateCheckerDelegate

extension UpdateCoordinator: UpdateCheckerDelegate {
    func updateChecker(_ checker: UpdateChecker, didFindRelease release: ReleaseInfo) {
        pendingRelease = release
        banner.showNewVersion(release.version)
    }
}

// MARK: - UpdateManagerDelegate

extension UpdateCoordinator: UpdateManagerDelegate {
    func updateManager(_ manager: UpdateManager, didChangeState state: UpdateManager.State) {
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

import AppKit
import Sparkle

/// What the banner is currently showing. Replaces the old `UpdateManager.State`
/// — Sparkle owns the download/extract/install machinery now, so this exists
/// purely to drive the UI.
enum UpdateState {
    case idle
    case checking
    case available(version: String)
    case downloading(progress: Double)
    case extracting(progress: Double)
    case readyToInstall
    case installing
    case failed(Error)
}

/// Bridges Sparkle's `SPUUserDriver` callbacks onto seahelm's inline
/// `UpdateBanner` instead of Sparkle's stock modal windows.
///
/// Two things make this more than a straight passthrough:
///
/// 1. Sparkle hands us a *reply block* for each decision point and will block
///    the update until it's called. The banner's buttons are what eventually
///    call them, so every pending reply is stashed here.
/// 2. A user-initiated check must always produce visible feedback, but a
///    scheduled background check that finds nothing must stay silent. Hence
///    `isUserInitiated` gating in `showUpdateNotFoundWithError` / `showUpdaterError`.
final class UpdateDriver: NSObject, SPUUserDriver {
    private let banner: UpdateBanner
    private let onStateChange: (UpdateState) -> Void

    /// Set while a check the user explicitly asked for is in flight.
    var isUserInitiated = false

    // Pending Sparkle replies, cleared as soon as they're invoked.
    private var updateChoiceReply: ((SPUUserUpdateChoice) -> Void)?
    private var installReply: ((SPUUserUpdateChoice) -> Void)?
    private var acknowledgement: (() -> Void)?
    private var cancellation: (() -> Void)?

    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    init(banner: UpdateBanner, onStateChange: @escaping (UpdateState) -> Void) {
        self.banner = banner
        self.onStateChange = onStateChange
        super.init()
    }

    private func emit(_ state: UpdateState) {
        // Sparkle calls these on arbitrary queues; the banner is AppKit.
        if Thread.isMainThread {
            onStateChange(state)
        } else {
            DispatchQueue.main.async { self.onStateChange(state) }
        }
    }

    // MARK: - Banner-driven actions

    /// User clicked "Update" — tell Sparkle to download.
    func confirmInstall() {
        guard let reply = updateChoiceReply else { return }
        updateChoiceReply = nil
        reply(.install)
    }

    /// User clicked "Skip". Sparkle persists this in `SUSkippedVersion` itself.
    func skipCurrentUpdate() {
        guard let reply = updateChoiceReply else { return }
        updateChoiceReply = nil
        reply(.skip)
        emit(.idle)
    }

    /// User clicked "Restart Now".
    func installAndRelaunch() {
        guard let reply = installReply else { return }
        installReply = nil
        reply(.install)
    }

    /// User dismissed an error / "up to date" notice.
    func acknowledge() {
        guard let ack = acknowledgement else { return }
        acknowledgement = nil
        ack()
        emit(.idle)
    }

    /// User cancelled an in-flight check or download.
    func cancel() {
        cancellation?()
        cancellation = nil
        updateChoiceReply = nil
        installReply = nil
        emit(.idle)
    }

    // MARK: - SPUUserDriver

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void
    ) {
        // seahelm decides this from its own config (autoUpdate.enabled) rather
        // than prompting, so answer immediately and never show Sparkle's dialog.
        reply(.init(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        emit(.checking)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void
    ) {
        updateChoiceReply = reply
        emit(.available(version: appcastItem.displayVersionString))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // The banner has no room for release notes; the GitHub release page is
        // the canonical place for them.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // See showUpdateReleaseNotes — nothing to fail at.
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        guard isUserInitiated else {
            // Background check found nothing. Stay quiet.
            acknowledgement()
            emit(.idle)
            return
        }
        // A manual check must always answer — a silent no-op here is exactly why
        // the menu item used to look dead.
        self.acknowledgement = acknowledgement
        let alert = NSAlert()
        alert.messageText = "Already up to date"
        alert.informativeText = "Version \(Bundle.main.shortVersionString) is the latest."
        alert.alertStyle = .informational
        DispatchQueue.main.async {
            alert.runModal()
            self.acknowledge()
        }
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        self.acknowledgement = acknowledgement
        NSLog("Sparkle update error: \(error)")
        emit(.failed(error))
        guard isUserInitiated else {
            acknowledgement()
            self.acknowledgement = nil
            return
        }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            self.acknowledge()
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        expectedLength = 0
        receivedLength = 0
        emit(.downloading(progress: 0))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        guard expectedLength > 0 else { return }
        emit(.downloading(progress: Double(receivedLength) / Double(expectedLength)))
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        emit(.extracting(progress: 0))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        emit(.extracting(progress: progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        installReply = reply
        emit(.readyToInstall)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        emit(.installing)
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        acknowledgement()
        emit(.idle)
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        updateChoiceReply = nil
        installReply = nil
        acknowledgement = nil
        cancellation = nil
        emit(.idle)
    }
}

extension Bundle {
    var shortVersionString: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }
}

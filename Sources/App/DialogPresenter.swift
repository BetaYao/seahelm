import AppKit

/// Encapsulates all sheet/dialog presentation logic for the main window.
final class DialogPresenter {
    private weak var tabCoordinator: TabCoordinator?
    private weak var terminalCoordinator: TerminalCoordinator?
    private weak var statusPublisher: StatusPublisher?

    init(tabCoordinator: TabCoordinator, terminalCoordinator: TerminalCoordinator, statusPublisher: StatusPublisher) {
        self.tabCoordinator = tabCoordinator
        self.terminalCoordinator = terminalCoordinator
        self.statusPublisher = statusPublisher
    }

    func presentSheetOnActiveVC(_ vc: NSViewController, tabCoordinator: TabCoordinator, dashboardVC: DashboardViewController?) {
        dashboardVC?.presentAsSheet(vc)
    }

    func makeQuickSwitcher(quickSwitcherDelegate: QuickSwitcherDelegate) -> QuickSwitcherViewController {
        let worktreeInfos = tabCoordinator?.allWorktrees.map { $0.info } ?? []
        var statuses: [String: AgentStatus] = [:]
        if let surfaceManager = terminalCoordinator?.surfaceManager {
            for (path, _) in surfaceManager.all {
                statuses[path] = statusPublisher?.status(for: path)
            }
        }
        let switcher = QuickSwitcherViewController(worktrees: worktreeInfos, statuses: statuses)
        switcher.quickSwitcherDelegate = quickSwitcherDelegate
        return switcher
    }

    func makeSettings(config: Config, settingsDelegate: SettingsDelegate) -> SettingsViewController {
        let settingsVC = SettingsViewController(config: config)
        settingsVC.settingsDelegate = settingsDelegate
        return settingsVC
    }

    func makeNewBranchDialog(repoPaths: [String], dialogDelegate: NewBranchDialogDelegate) -> NewBranchDialog {
        let dialog = NewBranchDialog(repoPaths: repoPaths)
        dialog.dialogDelegate = dialogDelegate
        return dialog
    }

    static func showKeyboardShortcuts() {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = """
        ⌘N  New Branch
        ⌘P  Quick Switch
        ⌘W  Close Tab
        ⌘0  Dashboard
        ⌘,  Settings
        ⌘}  Next Tab
        ⌘{  Previous Tab
        ⌘-  Zoom In (Smaller Cards)
        ⌘=  Zoom Out (Larger Cards)
        Esc  Close Dialog / Exit Spotlight
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

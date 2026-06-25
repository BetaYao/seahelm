import AppKit

protocol PanelCoordinatorDelegate: AnyObject {
    func panelCoordinator(_ coordinator: PanelCoordinator, navigateToWorktreePath path: String, paneIndex: Int?)
}

class PanelCoordinator: NSObject {
    weak var delegate: PanelCoordinatorDelegate?
    weak var titleBar: TitleBarView?

    func notificationPanelDidSelectItem(_ entry: NotificationEntry) {
        delegate?.panelCoordinator(self, navigateToWorktreePath: entry.worktreePath, paneIndex: entry.paneIndex)
    }
}

// MARK: - NotificationHistoryDelegate

extension PanelCoordinator: NotificationHistoryDelegate {
    func notificationHistory(_ vc: NotificationHistoryViewController, didSelectWorktreePath path: String) {
        NotificationCenter.default.post(
            name: .navigateToWorktree,
            object: nil,
            userInfo: ["worktreePath": path]
        )
    }
}

import AppKit

protocol PanelCoordinatorDelegate: AnyObject {
    func panelCoordinator(_ coordinator: PanelCoordinator, navigateToWorktreePath path: String, paneIndex: Int?)
}

class PanelCoordinator: NSObject {
    weak var delegate: PanelCoordinatorDelegate?
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

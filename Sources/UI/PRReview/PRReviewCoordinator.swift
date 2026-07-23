import AppKit

/// PR Review 的协调器，管理从 PR 列表 → diff 查看 → 行内评论的完整流程。
///
/// 调用方只需创建 coordinator 并调用 `show()` 即可：
/// ```
/// let coordinator = PRReviewCoordinator(
///     service: GitHubPRService(token: token, owner: owner, repo: repo),
///     dashboard: dashboardViewController
/// )
/// coordinator.show()
/// ```
final class PRReviewCoordinator {
    private let service: GitHubPRService
    private weak var dashboard: DashboardViewController?

    init(service: GitHubPRService, dashboard: DashboardViewController) {
        self.service = service
        self.dashboard = dashboard
    }

    // MARK: - 入口

    /// 从 PR 列表开始展示。
    func show() {
        let list = PRListView(service: service)
        list.onSelectPR = { [weak self] pr in
            self?.showPRDiff(pr)
        }
        dashboard?.showCenterOverlay(list, title: "Pull Requests")
    }

    // MARK: - PR Diff 查看

    /// 选中某个 PR 后，拉取文件列表并用 DiffReviewView 展示。
    private func showPRDiff(_ pr: GitHubPR) {
        guard let dashboard else { return }

        let title = "#\(pr.number) \(pr.title)"
        let loading = NSProgressIndicator()
        loading.style = .spinning
        loading.controlSize = .large
        loading.translatesAutoresizingMaskIntoConstraints = false
        loading.startAnimation(nil)

        let container = NSView()
        container.addSubview(loading)
        NSLayoutConstraint.activate([
            loading.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            loading.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        let overlay = dashboard.showCenterOverlay(container, title: title)

        Task { [weak self] in
            guard let self else { return }
            do {
                let files = try await self.service.listPRFiles(number: pr.number)
                try Task.checkCancellation()

                let snapshot = GitHubDiffAdapter.snapshot(from: files)

                await MainActor.run {
                    guard let dashboard = self.dashboard, overlay.window != nil else { return }
                    let diffView = DiffReviewView(worktreePath: "") {
                        snapshot
                    }
                    // 立即加载（DiffReviewView 在 viewDidMoveToWindow 时触发，但此时
                    // overlay 已经在 window 上，所以直接调用 loadDiff 即可）。
                    diffView.loadDiff()

                    // 替换 loading → diff view
                    dashboard.showCenterOverlay(diffView, title: title)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard let dashboard = self.dashboard, overlay.window != nil else { return }
                    let errorLabel = NSTextField(labelWithString: "Failed to load PR: \(error.localizedDescription)")
                    errorLabel.textColor = Theme.textSecondary
                    errorLabel.alignment = .center
                    dashboard.showCenterOverlay(errorLabel, title: title)
                }
            }
        }
    }
}

import XCTest

/// Top-level page object for the seahelm app.
/// Provides access to all sub-page objects.
class AppPage {
    let app: XCUIApplication

    init() {
        app = XCUIApplication()
    }

    @discardableResult
    func launch(testConfigPath: String? = nil) -> Self {
        app.launchArguments += [
            "-SeahelmUITesting",
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        if let path = testConfigPath {
            app.launchArguments += ["-UITestConfig", path]
        }
        app.launch()
        return self
    }

    func terminate() {
        app.terminate()
    }

    lazy var titleBar = TitleBarPage(app)
    lazy var layoutPopover = LayoutPopoverPage(app)
    lazy var dashboard = DashboardPage(app)
    lazy var sidebar = SidebarPage(app)
    lazy var settings = SettingsPage(app)
    lazy var modal = ModalPage(app)
    lazy var notifPanel = NotificationPanelPage(app)
    lazy var aiPanel = AIPanelPage(app)
    lazy var statusBar = StatusBarPage(app)
    lazy var repo = RepoPage(app)
    lazy var dialog = DialogPage(app)
    lazy var splitPane = SplitPanePage(app)
}

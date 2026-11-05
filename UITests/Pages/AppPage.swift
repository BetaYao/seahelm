import XCTest

/// Top-level page object for the seahelm app.
/// Provides access to all sub-page objects.
class AppPage {
    let app: XCUIApplication
    /// The isolated home this launch runs in (`ScratchHome`).
    private(set) var scratch: ScratchHome?

    init() {
        app = XCUIApplication()
    }

    @discardableResult
    func launch(testConfigPath: String? = nil, environment: [String: String] = [:]) -> Self {
        app.launchArguments += [
            "-SeahelmUITesting",
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        if let path = testConfigPath {
            app.launchArguments += ["-UITestConfig", path]
        }
        let scratch = ScratchHome()
        self.scratch = scratch
        app.launchEnvironment.merge(scratch.environment) { _, new in new }
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launch()
        return self
    }

    func terminate() {
        app.terminate()
    }

    lazy var chrome = ChromeHeaderPage(app)
    /// Backward-compatible alias for older tests still naming the chrome header strip.
    lazy var titleBar = chrome
    lazy var layoutPopover = LayoutPopoverPage(app)
    lazy var dashboard = DashboardPage(app)
    lazy var sidebar = SidebarPage(app)
    lazy var settings = SettingsPage(app)
    lazy var modal = ModalPage(app)
    lazy var notifPanel = NotificationPanelPage(app)
    lazy var aiPanel = AIPanelPage(app)
    lazy var repo = RepoPage(app)
    lazy var dialog = DialogPage(app)
    lazy var splitPane = SplitPanePage(app)
}

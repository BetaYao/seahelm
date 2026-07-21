import Foundation

protocol ChromeHeaderDelegate: AnyObject {
    func chromeDidToggleTheme()
    func chromeDidSelectPane(_ pane: ChromeLeftPane)
    func chromeDidToggleSidebar()
    /// Toggle the terminal column between focus mode and split file-edit mode.
    func chromeDidToggleEditMode()
}

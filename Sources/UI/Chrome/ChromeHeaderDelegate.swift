import Foundation

protocol ChromeHeaderDelegate: AnyObject {
    func chromeDidToggleTheme()
    func chromeDidSelectPane(_ pane: ChromeLeftPane)
    func chromeDidToggleSidebar()
}

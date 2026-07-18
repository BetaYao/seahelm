import Foundation
import CoreGraphics

enum ChromeLeftPane: Equatable {
    case firstMate, files, changes
}

struct ChromeLayoutState: Equatable {
    var width: CGFloat
    private(set) var isCollapsed: Bool
    private(set) var activePane: ChromeLeftPane?

    init(width: CGFloat, collapsed: Bool, activePane: ChromeLeftPane?) {
        self.width = width
        self.isCollapsed = collapsed
        self.activePane = activePane
    }

    /// Icon click: same pane while expanded → collapse; otherwise select + expand.
    mutating func selectPane(_ pane: ChromeLeftPane) {
        if !isCollapsed, activePane == pane {
            isCollapsed = true
            return
        }
        activePane = pane
        isCollapsed = false
    }

    mutating func setActivePane(_ pane: ChromeLeftPane) {
        activePane = pane
        isCollapsed = false
    }

    mutating func toggleCollapsed() {
        if isCollapsed {
            isCollapsed = false
            if activePane == nil { activePane = .firstMate }
        } else {
            isCollapsed = true
        }
    }
}

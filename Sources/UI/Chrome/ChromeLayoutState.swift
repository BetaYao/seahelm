import Foundation
import CoreGraphics

enum ChromeLeftPane: String, Equatable, Codable {
    case firstMate, files, changes
}

/// Legacy left-column pane tags used by dashboard keymap shortcuts (files / changes).
enum LeftPane: Int, CaseIterable {
    case bridge = 0
    case file = 1
    case change = 2
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
        setCollapsed(!isCollapsed)
    }

    mutating func setCollapsed(_ collapsed: Bool) {
        if collapsed {
            isCollapsed = true
        } else {
            isCollapsed = false
            if activePane == nil { activePane = .firstMate }
        }
    }
}

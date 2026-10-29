import Foundation
import CoreGraphics

/// A config written before Issues replaced Changes says `"changes"`; that no
/// longer decodes and the launch falls back to First Mate.
enum ChromeLeftPane: String, Equatable, Codable {
    case firstMate, files, issues
}

/// Legacy left-column pane tags used by dashboard keymap shortcuts (files / issues).
enum LeftPane: Int, CaseIterable {
    case file = 1
    case issues = 2
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

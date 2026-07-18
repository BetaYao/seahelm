import Foundation

enum ChromeLayoutMetrics {
    static let defaultSidebarWidth: CGFloat = 300
    static let minSidebarWidth: CGFloat = 200
    static let headerHeight: CGFloat = 40
    static let dividerVisualWidth: CGFloat = 1
    static let dividerHitWidth: CGFloat = 8

    static func clampWidth(_ width: CGFloat, windowWidth: CGFloat) -> CGFloat {
        let maxW = max(minSidebarWidth, windowWidth * 0.5)
        return min(max(width, minSidebarWidth), maxW)
    }
}

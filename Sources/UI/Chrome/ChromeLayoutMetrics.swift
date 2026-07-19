import Foundation

enum ChromeLayoutMetrics {
    static let defaultSidebarWidth: CGFloat = 300
    static let minSidebarWidth: CGFloat = 200
    static let headerHeight: CGFloat = 40
    /// Idle hairline.
    static let dividerVisualWidth: CGFloat = 1
    /// Hover / drag accent stroke (still centered in the hit strip).
    static let dividerActiveVisualWidth: CGFloat = 2
    /// Invisible drag tolerance centered on the seam (overlays both columns).
    static let dividerHitWidth: CGFloat = 16

    static func clampWidth(_ width: CGFloat, windowWidth: CGFloat) -> CGFloat {
        let maxW = max(minSidebarWidth, windowWidth * 0.5)
        return min(max(width, minSidebarWidth), maxW)
    }
}

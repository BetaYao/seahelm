import QuartzCore

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

    /// ⌘B collapse. Shared by the width slide and by every fade riding along
    /// with it — the sidebar header, the terminal header's collapsed icons —
    /// so nothing arrives early and re-introduces the pop this replaced.
    static let collapseAnimationDuration: TimeInterval = 0.24

    /// Decelerating: leaves promptly, settles slow. Measured against a sampled
    /// width trace — a steeper curve (0.2, 0.9, …) covered 70% of the distance
    /// in the first 40ms, which reads as a snap no matter what the duration says.
    static let collapseTimingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)

    static func clampWidth(_ width: CGFloat, windowWidth: CGFloat) -> CGFloat {
        let maxW = max(minSidebarWidth, windowWidth * 0.5)
        return min(max(width, minSidebarWidth), maxW)
    }
}

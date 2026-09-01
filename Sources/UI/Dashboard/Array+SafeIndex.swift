import Foundation

/// Bounds-checked subscript, so a stale index reads as nil instead of trapping.
///
/// Lived at the bottom of DashboardViewController.swift, under a doc comment
/// describing a different type entirely. It is a general utility and the
/// dashboard is simply where it was first needed.
extension Array {
    subscript(safeIndex index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

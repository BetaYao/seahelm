import Foundation

/// A keyboard-navigable UI region. In NORMAL mode, `Tab`/`Shift+Tab` cycle the
/// *available* regions and `h j k l` / `1-9` act on the current one.
///
/// `panes` and `dashboard` are mutually exclusive for a given layout (a repo tab
/// shows split panes; the dashboard tab shows the card ring) — availability is
/// decided by the host and fed to `RegionFocusController`.
///
/// `titlebar` is the chrome header icon strip — `SidebarHeaderView` when the
/// sidebar is expanded, `TerminalHeaderView` when collapsed. It must never target
/// the removed spanning title-bar accessory.
enum Region: String, CaseIterable, Equatable {
    case panes
    case dashboard
    case sidebar
    /// Chrome header icon strip (sidebar header expanded / terminal header collapsed).
    case titlebar
    case helm
}

/// Encapsulates the "which region has keyboard focus" state and `Tab` cycling.
///
/// Pure value logic — no AppKit references (mirrors `DashboardFocusController`'s
/// design). The host translates `current` into first-responder + visual updates.
///
/// The canonical cycle order is the declaration order of `Region.allCases`; the
/// controller only ever cycles through the subset the host marks *available*.
final class RegionFocusController {

    /// Ordered subset of regions the host currently exposes, in canonical order.
    private(set) var available: [Region] = []

    /// The region that currently owns keyboard focus (nil when none available).
    private(set) var current: Region?

    // MARK: - Availability

    /// Replace the set of available regions. Order is normalized to the canonical
    /// `Region.allCases` order regardless of the caller's ordering. Focus is
    /// preserved when the current region is still available; otherwise it lands on
    /// the first available region (or nil when empty).
    func setAvailable(_ regions: [Region]) {
        let set = Set(regions)
        available = Region.allCases.filter { set.contains($0) }
        if let cur = current, available.contains(cur) {
            return  // preserved
        }
        current = available.first
    }

    /// Explicitly focus a region. No-op if it is not currently available.
    @discardableResult
    func focus(_ region: Region) -> Bool {
        guard available.contains(region) else { return false }
        current = region
        return true
    }

    // MARK: - Cycling

    /// Advance to the next available region, wrapping around. No-op when fewer than
    /// two regions are available.
    func next() { step(+1) }

    /// Move to the previous available region, wrapping around.
    func prev() { step(-1) }

    private func step(_ delta: Int) {
        guard available.count > 1 else { return }
        guard let cur = current, let idx = available.firstIndex(of: cur) else {
            current = available.first
            return
        }
        let n = available.count
        let nextIdx = ((idx + delta) % n + n) % n
        current = available[nextIdx]
    }
}

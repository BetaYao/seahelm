import AppKit

protocol SplitContainerDelegate: AnyObject {
    func splitContainer(_ view: SplitContainerView, didChangeFocus leafId: String)
    func splitContainer(_ view: SplitContainerView, didRequestSplit axis: SplitAxis)
    func splitContainer(_ view: SplitContainerView, didRequestClosePane leafId: String)
    func splitContainerDidChangeLayout(_ view: SplitContainerView)
}

// MARK: - Dim overlay

/// Transparent overlay that dims unfocused panes. Passes all mouse events through
/// so clicks reach the terminal view underneath.
private class DimOverlayView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func refreshAppearance() {
        // Light: barely-there wash (0.35 black turns Catppuccin Latte muddy grey).
        // Dark: keep a readable focus cue without crushing the surface.
        let alpha: CGFloat = effectiveAppearance.isDark ? 0.28 : 0.055
        layer?.backgroundColor = resolvedCGColor(NSColor.black.withAlphaComponent(alpha))
    }
}

// MARK: - SplitContainerView

class SplitContainerView: NSView, DividerDelegate {
    var tree: SplitTree? { didSet { layoutTree() } }
    var surfaceViews: [String: NSView] = [:]
    /// When set (and the leaf exists), only this leaf is shown, filling the
    /// container — tmux-style zoom. Others are hidden; dividers/overlays cleared.
    var zoomedLeafId: String?
    weak var delegate: SplitContainerDelegate?

    /// While true, Auto Layout from a mid-create `addSubview` must not run
    /// `layoutTree` — that would shrink the existing pane (SIGWINCH / starship
    /// blank line) before the new leaf is registered and final frames exist.
    var suppressStructuralLayout = false

    private var dividers: [String: DividerView] = [:]
    private var leafFrames: [String: CGRect] = [:]
    private var dimOverlays: [String: DimOverlayView] = [:]

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = true
        setAccessibilityIdentifier("splitPane.container")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dimOverlays.values.forEach { $0.refreshAppearance() }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        guard !suppressStructuralLayout else { return }
        // Live-resize fires this continuously; the full layoutTree (constraint
        // teardown, re-embedding, delegate rewiring, forced size sync) is only
        // needed on structural changes. If every visible leaf is already embedded
        // here, just move frames.
        if allVisibleLeavesEmbedded {
            applyFramesOnly()
        } else {
            layoutTree()
        }
    }

    private var allVisibleLeavesEmbedded: Bool {
        guard let tree = tree else { return false }
        let leaves = zoomedLeafId.flatMap { z in tree.allLeaves.first { $0.id == z } }.map { [$0] }
            ?? tree.allLeaves
        return !leaves.isEmpty && leaves.allSatisfy { leaf in
            guard let view = surfaceViews[leaf.stationId] else { return false }
            return view.superview == self && view.translatesAutoresizingMaskIntoConstraints
        }
    }

    func layoutTree() {
        guard let tree = tree else { return }
        let zoomLeaf = zoomedLeafId.flatMap { z in tree.allLeaves.first { $0.id == z } }
        if let zoomLeaf {
            leafFrames = [zoomLeaf.id: bounds]
        } else {
            leafFrames = Self.computeFrames(node: tree.root, in: bounds)
        }
        // Hide zoomed-out leaves; only leaves with a computed frame are visible.
        for leaf in tree.allLeaves {
            surfaceViews[leaf.stationId]?.isHidden = (leafFrames[leaf.id] == nil)
        }
        for leaf in tree.allLeaves {
            guard let frame = leafFrames[leaf.id],
                  let view = surfaceViews[leaf.stationId] else { continue }
            // Deactivate any Auto Layout constraints and switch to frame-based positioning.
            // Station.create() sets up Auto Layout, but SplitContainerView uses frames.
            if !view.translatesAutoresizingMaskIntoConstraints {
                NSLayoutConstraint.deactivate(view.constraints)
                // Also remove constraints from superview that reference this view
                if let sv = view.superview {
                    let related = sv.constraints.filter {
                        $0.firstItem as? NSView === view || $0.secondItem as? NSView === view
                    }
                    NSLayoutConstraint.deactivate(related)
                }
                view.translatesAutoresizingMaskIntoConstraints = true
            }
            if view.superview != self {
                view.removeFromSuperview()
                addSubview(view)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.frame = frame
            CATransaction.commit()
            view.setAccessibilityIdentifier("splitPane.leaf.\(leaf.id)")

            // Keep tree.focusedId in sync when user clicks a pane directly
            if let ghosttyView = view as? GhosttyNSView {
                let leafId = leaf.id
                ghosttyView.onFocusAcquired = { [weak self] in
                    guard let self else { return }
                    self.tree?.focusedId = leafId
                    self.delegate?.splitContainer(self, didChangeFocus: leafId)
                    self.updateDimOverlays()
                }
            }

            // Wire recovery + content scale. Do NOT call `syncSize()` here —
            // `setFrame` already synced the surface, and `syncSize()` resets
            // `lastSyncedSize` which can force a second `set_size` / SIGWINCH
            // (starship reprints a blank prompt line on the existing pane).
            if let station = StationRegistry.shared.station(forId: leaf.stationId) {
                // Wire recovery re-embed to this container: layoutTree runs on every
                // embed/relayout, so the station's delegate always points at whichever
                // container currently displays it. Without this the delegate stayed nil
                // and a recovered (recreated) surface was orphaned — a dead pane.
                station.delegate = self
                station.syncContentScale()
            }
        }
        if zoomLeaf != nil {
            // A single full-container pane has no dividers and nothing to dim.
            dividers.values.forEach { $0.removeFromSuperview() }
            dividers.removeAll()
            dimOverlays.values.forEach { $0.removeFromSuperview() }
            dimOverlays.removeAll()
        } else {
            layoutDividers(node: tree.root, in: bounds)
            let activeSplitIds = collectSplitIds(tree.root)
            for (id, divider) in dividers where !activeSplitIds.contains(id) {
                divider.removeFromSuperview()
                dividers.removeValue(forKey: id)
            }
            updateDimOverlays()
        }
    }

    /// Toggle/set tmux-style zoom for a leaf. `on == nil` toggles. Returns whether
    /// the container is zoomed afterward.
    @discardableResult
    func setZoom(leafId: String, on: Bool?) -> Bool {
        let shouldZoom = on ?? (zoomedLeafId != leafId)
        zoomedLeafId = shouldZoom ? leafId : nil
        layoutTree()
        return zoomedLeafId != nil
    }

    /// Lightweight relayout for divider drags: recompute frames and move the
    /// already-embedded views. Skips everything layoutTree does beyond that
    /// (constraint teardown, focus-closure wiring, forced surface size sync) —
    /// GhosttyNSView.setFrameSize already syncs the surface size with a debounce.
    private func applyFramesOnly() {
        guard let tree = tree else { return }
        if let zoomLeaf = zoomedLeafId.flatMap({ z in tree.allLeaves.first { $0.id == z } }) {
            leafFrames = [zoomLeaf.id: bounds]
        } else {
            leafFrames = Self.computeFrames(node: tree.root, in: bounds)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for leaf in tree.allLeaves {
            guard let frame = leafFrames[leaf.id],
                  let view = surfaceViews[leaf.stationId],
                  view.superview == self else { continue }
            view.frame = frame
        }
        if zoomedLeafId == nil {
            layoutDividers(node: tree.root, in: bounds)
        }
        for (id, overlay) in dimOverlays {
            if let frame = leafFrames[id] { overlay.frame = frame }
        }
        CATransaction.commit()
    }

    // MARK: - Dim overlays

    /// Update semi-transparent overlays that dim unfocused panes.
    /// Overlays are sibling views above terminals but below dividers, and pass mouse events through.
    func updateDimOverlays() {
        guard let tree = tree else {
            dimOverlays.values.forEach { $0.removeFromSuperview() }
            dimOverlays.removeAll()
            return
        }

        // Single pane: no dimming needed
        guard tree.leafCount > 1 else {
            dimOverlays.values.forEach { $0.removeFromSuperview() }
            dimOverlays.removeAll()
            return
        }

        let focusedId = tree.focusedId
        let activeLeafIds = Set(tree.allLeaves.map(\.id))

        // Remove overlays for leaves that no longer exist
        for id in dimOverlays.keys where !activeLeafIds.contains(id) {
            dimOverlays[id]?.removeFromSuperview()
            dimOverlays.removeValue(forKey: id)
        }

        for leaf in tree.allLeaves {
            if leaf.id == focusedId {
                dimOverlays[leaf.id]?.removeFromSuperview()
                dimOverlays.removeValue(forKey: leaf.id)
            } else {
                let frame = leafFrames[leaf.id] ?? .zero
                if let overlay = dimOverlays[leaf.id] {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    overlay.frame = frame
                    CATransaction.commit()
                    overlay.refreshAppearance()
                } else {
                    let overlay = DimOverlayView(frame: frame)
                    // Insert above terminal views but below dividers
                    if let firstDivider = dividers.values.first {
                        addSubview(overlay, positioned: .below, relativeTo: firstDivider)
                    } else {
                        addSubview(overlay)
                    }
                    dimOverlays[leaf.id] = overlay
                }
            }
        }
    }

    // MARK: - Frame computation

    static func computeFrames(node: SplitNode, in rect: CGRect) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        computeFramesRecursive(node: node, in: rect, result: &result)
        return result
    }

    private static func computeFramesRecursive(node: SplitNode, in rect: CGRect, result: inout [String: CGRect]) {
        switch node {
        case .leaf(let id, _, _):
            result[id] = rect
        case .split(_, let axis, let ratio, let first, let second):
            let dividerSize = DividerView.thickness
            switch axis {
            case .horizontal:
                let firstWidth = floor((rect.width - dividerSize) * ratio)
                let secondX = rect.origin.x + firstWidth + dividerSize
                let secondWidth = rect.width - firstWidth - dividerSize
                let firstRect = CGRect(x: rect.origin.x, y: rect.origin.y, width: firstWidth, height: rect.height)
                let secondRect = CGRect(x: secondX, y: rect.origin.y, width: secondWidth, height: rect.height)
                computeFramesRecursive(node: first, in: firstRect, result: &result)
                computeFramesRecursive(node: second, in: secondRect, result: &result)
            case .vertical:
                let firstHeight = floor((rect.height - dividerSize) * ratio)
                let secondY = rect.origin.y + firstHeight + dividerSize
                let secondHeight = rect.height - firstHeight - dividerSize
                let firstRect = CGRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: firstHeight)
                let secondRect = CGRect(x: rect.origin.x, y: secondY, width: rect.width, height: secondHeight)
                computeFramesRecursive(node: first, in: firstRect, result: &result)
                computeFramesRecursive(node: second, in: secondRect, result: &result)
            }
        }
    }

    private func layoutDividers(node: SplitNode, in rect: CGRect) {
        guard case .split(let id, let axis, let ratio, let first, let second) = node else { return }
        let dividerSize = DividerView.thickness

        let divider: DividerView
        if let existing = dividers[id] {
            divider = existing
        } else {
            divider = DividerView(splitNodeId: id, axis: axis)
            divider.delegate = self
            divider.setAccessibilityIdentifier("splitPane.divider.\(id)")
            addSubview(divider)
            dividers[id] = divider
        }

        let hit = DividerView.hitThickness
        switch axis {
        case .horizontal:
            let firstWidth = floor((rect.width - dividerSize) * ratio)
            // Wide hit strip centered on the 1pt seam (overlaps both panes).
            let seamCenterX = rect.origin.x + firstWidth + dividerSize / 2
            divider.frame = CGRect(
                x: seamCenterX - hit / 2,
                y: rect.origin.y,
                width: hit,
                height: rect.height
            )
            divider.parentSplitSize = rect.width
            divider.currentRatio = ratio
            let firstRect = CGRect(x: rect.origin.x, y: rect.origin.y, width: firstWidth, height: rect.height)
            let secondRect = CGRect(x: rect.origin.x + firstWidth + dividerSize, y: rect.origin.y, width: rect.width - firstWidth - dividerSize, height: rect.height)
            layoutDividers(node: first, in: firstRect)
            layoutDividers(node: second, in: secondRect)
        case .vertical:
            let firstHeight = floor((rect.height - dividerSize) * ratio)
            let seamCenterY = rect.origin.y + firstHeight + dividerSize / 2
            divider.frame = CGRect(
                x: rect.origin.x,
                y: seamCenterY - hit / 2,
                width: rect.width,
                height: hit
            )
            divider.parentSplitSize = rect.height
            divider.currentRatio = ratio
            let firstRect = CGRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: firstHeight)
            let secondRect = CGRect(x: rect.origin.x, y: rect.origin.y + firstHeight + dividerSize, width: rect.width, height: rect.height - firstHeight - dividerSize)
            layoutDividers(node: first, in: firstRect)
            layoutDividers(node: second, in: secondRect)
        }
    }

    private func collectSplitIds(_ node: SplitNode) -> Set<String> {
        switch node {
        case .leaf: return []
        case .split(let id, _, _, let first, let second):
            return Set([id]).union(collectSplitIds(first)).union(collectSplitIds(second))
        }
    }

    // MARK: - Mouse → focus restore

    /// Clicking anywhere on the split container (background, divider gap, etc.)
    /// should restore keyboard focus to the currently-focused terminal leaf.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        restoreFocusToActiveLeaf()
    }

    func restoreFocusToActiveLeaf() {
        guard let tree else { return }
        let targetId = tree.focusedId
        if let leaf = tree.allLeaves.first(where: { $0.id == targetId }),
           let view = surfaceViews[leaf.stationId],
           window?.firstResponder !== view {
            window?.makeFirstResponder(view)
        }
    }

    // MARK: - Focus navigation

    func focusLeaf(direction: SplitAxis, positive: Bool) -> String? {
        guard let tree = tree else { return nil }
        guard let currentFrame = leafFrames[tree.focusedId] else { return nil }
        let center = CGPoint(x: currentFrame.midX, y: currentFrame.midY)

        var bestLeaf: String?
        var bestDistance: CGFloat = .greatestFiniteMagnitude

        for leaf in tree.allLeaves where leaf.id != tree.focusedId {
            guard let frame = leafFrames[leaf.id] else { continue }
            let leafCenter = CGPoint(x: frame.midX, y: frame.midY)

            let inDirection: Bool
            switch (direction, positive) {
            case (.horizontal, true):  inDirection = leafCenter.x > center.x
            case (.horizontal, false): inDirection = leafCenter.x < center.x
            case (.vertical, true):    inDirection = leafCenter.y > center.y
            case (.vertical, false):   inDirection = leafCenter.y < center.y
            }
            guard inDirection else { continue }

            let overlaps: Bool
            if direction == .horizontal {
                overlaps = frame.minY < currentFrame.maxY && frame.maxY > currentFrame.minY
            } else {
                overlaps = frame.minX < currentFrame.maxX && frame.maxX > currentFrame.minX
            }
            guard overlaps else { continue }

            let dist = hypot(leafCenter.x - center.x, leafCenter.y - center.y)
            if dist < bestDistance {
                bestDistance = dist
                bestLeaf = leaf.id
            }
        }

        if let best = bestLeaf {
            tree.focusedId = best
            delegate?.splitContainer(self, didChangeFocus: best)
            updateDimOverlays()
        }
        return bestLeaf
    }

    func dividerDidBeginDrag(_ splitNodeId: String) {
        // Defer Ghostty PTY set_size for the whole drag — same SIGWINCH
        // tolerance as chrome sidebar / window live-resize.
        GhosttyBridge.shared.beginLiveResize(pinHeight: false)
    }

    func dividerDidMove(_ splitNodeId: String, newRatio: CGFloat) {
        // Fires on every mouse-move during a drag — frames only; PTY sync waits
        // for dividerDidEndDrag → endLiveResize.
        tree?.updateRatio(splitId: splitNodeId, newRatio: newRatio)
        applyFramesOnly()
    }

    func dividerDidEndDrag(_ splitNodeId: String) {
        // One set_size / SIGWINCH per pane after the grip is released.
        GhosttyBridge.shared.endLiveResize()
        delegate?.splitContainerDidChangeLayout(self)
    }

    func dividerDidDoubleClick(_ splitNodeId: String) {
        tree?.updateRatio(splitId: splitNodeId, newRatio: 0.5)
        GhosttyBridge.shared.beginLiveResize(pinHeight: false)
        applyFramesOnly()
        GhosttyBridge.shared.endLiveResize()
        delegate?.splitContainerDidChangeLayout(self)
    }
}

// MARK: - StationDelegate (session recovery re-embed)

extension SplitContainerView: StationDelegate {
    /// A station recreated its surface (e.g. zmx recovery). Re-register the new
    /// view for its leaf and relayout so input reaches the live surface.
    func stationDidRecover(_ station: Station) {
        guard let view = station.view else { return }
        reembedRecoveredView(stationId: station.id, view: view)
    }

    /// Swap in a recovered view for `stationId`, relayout (which reparents it into
    /// this container), and restore keyboard focus if that leaf was focused.
    /// Factored out from `stationDidRecover` so the re-embed can be unit-tested
    /// without a live Ghostty surface.
    func reembedRecoveredView(stationId: String, view: NSView) {
        surfaceViews[stationId] = view
        layoutTree()
        if let tree, let leaf = tree.allLeaves.first(where: { $0.stationId == stationId }),
           tree.focusedId == leaf.id {
            window?.makeFirstResponder(view)
        }
    }
}

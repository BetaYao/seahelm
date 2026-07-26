import AppKit

/// Edit-mode's two-column shell: LEFT terminal column (tab strip + terminal host)
/// and RIGHT preview column (tab strip + preview host), separated by a draggable
/// divider. It owns only geometry — the hosts are filled by
/// `DashboardViewController` (the terminal `SplitContainerView` on the left, the
/// active preview content on the right). Columns/divider are frame-laid so a drag
/// is a cheap frame move; column internals use Auto Layout.
final class EditLayoutContainerView: NSView, DividerDelegate {
    /// Host for the terminal `SplitContainerView` (shown one pane at a time).
    let terminalHost = NSView()
    /// Host for the active preview file's content view.
    let previewHost = NSView()
    let terminalTabStrip = EditTabStripView()
    let previewTabStrip = EditTabStripView()

    /// Fraction of width given to the LEFT (terminal) column.
    private var ratio: CGFloat
    /// Fired continuously while dragging (frames already moved) and once on end.
    var onRatioChange: ((CGFloat) -> Void)?

    private let leftColumn = NSView()
    private let rightColumn = NSView()
    private let divider = DividerView(splitNodeId: "editmode.column", axis: .horizontal)

    /// Each column's strip sits in a host whose height collapses to zero when the
    /// strips are hoisted into the window chrome — the hosts stay so the content
    /// below keeps one stable set of constraints either way.
    private let leftStripHost = NSView()
    private let rightStripHost = NSView()
    private var stripHostHeights: [NSLayoutConstraint] = []
    private(set) var stripsAreHoisted = false

    init(ratio: CGFloat) {
        self.ratio = ratio
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        for column in [leftColumn, rightColumn] {
            column.translatesAutoresizingMaskIntoConstraints = true
            column.autoresizingMask = []
            addSubview(column)
        }
        divider.delegate = self
        addSubview(divider)

        configureColumn(leftColumn, stripHost: leftStripHost, strip: terminalTabStrip, host: terminalHost)
        configureColumn(rightColumn, stripHost: rightStripHost, strip: previewTabStrip, host: previewHost)
    }

    private func configureColumn(_ column: NSView, stripHost: NSView, strip: EditTabStripView, host: NSView) {
        stripHost.translatesAutoresizingMaskIntoConstraints = false
        // The host clips so the strip's own 30pt height can't spill out of a
        // collapsed (zero-height) host during the hoist transition.
        stripHost.wantsLayer = true
        stripHost.layer?.masksToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        column.addSubview(stripHost)
        column.addSubview(host)

        let stripHostHeight = stripHost.heightAnchor.constraint(
            equalToConstant: EditTabStripView.stripHeight)
        stripHostHeights.append(stripHostHeight)

        NSLayoutConstraint.activate([
            stripHost.topAnchor.constraint(equalTo: column.topAnchor),
            stripHost.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            stripHost.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            stripHostHeight,

            host.topAnchor.constraint(equalTo: stripHost.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
        embedStrip(strip, in: stripHost)
    }

    private func embedStrip(_ strip: EditTabStripView, in stripHost: NSView) {
        strip.translatesAutoresizingMaskIntoConstraints = false
        stripHost.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: stripHost.topAnchor),
            strip.leadingAnchor.constraint(equalTo: stripHost.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: stripHost.trailingAnchor),
        ])
    }

    // MARK: - Hoisting the strips into the window chrome

    /// Give up both strips so the chrome header can show them on its own row,
    /// collapsing the in-column strip rows to reclaim their height.
    func hoistStrips() -> (terminal: EditTabStripView, preview: EditTabStripView) {
        stripsAreHoisted = true
        terminalTabStrip.removeFromSuperview()
        previewTabStrip.removeFromSuperview()
        stripHostHeights.forEach { $0.constant = 0 }
        needsLayout = true
        return (terminalTabStrip, previewTabStrip)
    }

    /// Take the strips back into the columns (chrome can't host them right now).
    func restoreStrips() {
        guard stripsAreHoisted else { return }
        stripsAreHoisted = false
        terminalTabStrip.removeFromSuperview()
        previewTabStrip.removeFromSuperview()
        embedStrip(terminalTabStrip, in: leftStripHost)
        embedStrip(previewTabStrip, in: rightStripHost)
        stripHostHeights.forEach { $0.constant = EditTabStripView.stripHeight }
        needsLayout = true
    }

    /// The divider fraction, so a hoisted strip row can split at the same seam.
    var currentRatio: CGFloat { ratio }

    /// Apply a stored per-worktree ratio (e.g. when switching worktrees while the
    /// container is reused). No-op if unchanged.
    func updateRatio(_ newRatio: CGFloat) {
        guard abs(newRatio - ratio) > 0.001 else { return }
        ratio = newRatio
        needsLayout = true
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }
        let seam = DividerView.thickness
        let leftW = floor((w - seam) * ratio)
        leftColumn.frame = CGRect(x: 0, y: 0, width: leftW, height: h)
        rightColumn.frame = CGRect(x: leftW + seam, y: 0, width: w - leftW - seam, height: h)

        let hit = DividerView.hitThickness
        divider.frame = CGRect(x: leftW + seam / 2 - hit / 2, y: 0, width: hit, height: h)
        divider.parentSplitSize = w
        divider.currentRatio = ratio
    }

    // MARK: - DividerDelegate

    func dividerDidBeginDrag(_ splitNodeId: String) {
        // Defer Ghostty PTY set_size for the whole drag (SIGWINCH tolerance).
        GhosttyBridge.shared.beginLiveResize(pinHeight: false)
    }

    func dividerDidMove(_ splitNodeId: String, newRatio: CGFloat) {
        ratio = newRatio
        needsLayout = true
        layoutSubtreeIfNeeded()
        onRatioChange?(newRatio)
    }

    func dividerDidEndDrag(_ splitNodeId: String) {
        GhosttyBridge.shared.endLiveResize()
        onRatioChange?(ratio)
    }

    func dividerDidDoubleClick(_ splitNodeId: String) {
        ratio = 0.5
        GhosttyBridge.shared.beginLiveResize(pinHeight: false)
        needsLayout = true
        layoutSubtreeIfNeeded()
        GhosttyBridge.shared.endLiveResize()
        onRatioChange?(ratio)
    }
}

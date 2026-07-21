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

        configureColumn(leftColumn, strip: terminalTabStrip, host: terminalHost)
        configureColumn(rightColumn, strip: previewTabStrip, host: previewHost)
    }

    private func configureColumn(_ column: NSView, strip: EditTabStripView, host: NSView) {
        strip.translatesAutoresizingMaskIntoConstraints = false
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        column.addSubview(strip)
        column.addSubview(host)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: column.topAnchor),
            strip.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: column.trailingAnchor),

            host.topAnchor.constraint(equalTo: strip.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
    }

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

import AppKit

/// Right-column chrome header. Expanded: centered title. Collapsed: lights + icons + title + expand.
final class TerminalHeaderView: NSView {
    weak var delegate: ChromeHeaderDelegate? {
        didSet { iconCluster.delegate = delegate }
    }

    /// Empty host for repositioned `standardWindowButton`s (used when collapsed).
    let trafficLightSlot = NSView()

    private let titleLabel = NSTextField(labelWithString: "")
    private let iconCluster = ChromeIconClusterView()
    private let expandButton = ChromeIconButton()
    private let editModeButton = ChromeIconButton()
    private let collapsedLeadingStack = NSStackView()

    /// Whether edit mode is currently on (drives the icon's active tint).
    private var editModeOn = false
    /// Latest pane title and cabin context; which one the label shows depends on
    /// edit mode, so both are kept rather than read back off the label.
    private var paneTitle = ""
    private var cabinContext = ""

    /// Edit mode's two column tab strips live here permanently rather than being
    /// moved up from the columns: reparenting a strip left its clip view seated at a
    /// non-zero vertical origin, which slid every tab out of the visible rect while
    /// all the frames still looked correct. Owning them removes that failure mode.
    let editTerminalStrip = EditTabStripView()
    let editPreviewStrip = EditTabStripView()
    private var editStripsActive = false
    private var stripConstraints: [NSLayoutConstraint] = []
    /// The two constants that track the column divider (terminal trailing, preview leading).
    private var stripSeamConstraints: [NSLayoutConstraint] = []
    private var stripRatio: CGFloat = 0.5
    private var stripLeadingCollapsed: NSLayoutConstraint?
    private var stripLeadingExpanded: NSLayoutConstraint?

    private var isCollapsed = false
    private var collapsedConstraints: [NSLayoutConstraint] = []
    private var expandedConstraints: [NSLayoutConstraint] = []
    private var colorSchemeObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        if let colorSchemeObserver {
            NotificationCenter.default.removeObserver(colorSchemeObserver)
        }
    }

    // MARK: - Title formatting

    /// Chrome title is the current pane title only (repo lives in the fleet row).
    static func formatTitle(repo: String, pane: String) -> String {
        let p = pane.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty { return p }
        return repo.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Public API

    func setTitle(repo: String, pane: String) {
        paneTitle = Self.formatTitle(repo: repo, pane: pane)
        applyTitleText()
    }

    func setPaneTitle(_ pane: String) {
        paneTitle = pane.trimmingCharacters(in: .whitespacesAndNewlines)
        applyTitleText()
    }

    func setCollapsed(_ collapsed: Bool) {
        guard isCollapsed != collapsed else { return }
        isCollapsed = collapsed
        applyCollapsedState()
    }

    func setActivePane(_ pane: ChromeLeftPane?) {
        iconCluster.setActivePane(pane)
    }

    func setWorktreeContextEnabled(_ enabled: Bool) {
        iconCluster.setWorktreeContextEnabled(enabled)
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        // Identifier for UITests; children (icon buttons / title) remain interactive a11y elements.
        setAccessibilityIdentifier("chrome.terminalHeader")
        refreshImmersion()

        trafficLightSlot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trafficLightSlot)

        iconCluster.delegate = delegate
        iconCluster.translatesAutoresizingMaskIntoConstraints = false

        collapsedLeadingStack.orientation = .horizontal
        collapsedLeadingStack.spacing = 8
        collapsedLeadingStack.alignment = .centerY
        collapsedLeadingStack.translatesAutoresizingMaskIntoConstraints = false
        collapsedLeadingStack.addArrangedSubview(iconCluster)
        addSubview(collapsedLeadingStack)

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setAccessibilityIdentifier("chrome.terminalTitle")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        configureExpandButton()
        addSubview(expandButton)

        configureEditModeButton()
        addSubview(editModeButton)

        for strip in [editTerminalStrip, editPreviewStrip] {
            strip.translatesAutoresizingMaskIntoConstraints = false
            strip.isHidden = true
            addSubview(strip)
        }

        colorSchemeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyColorSchemeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshImmersion()
        }

        // Edit-mode toggle is always visible (both collapse states); center it
        // vertically once and swap only its trailing anchor per state.
        NSLayoutConstraint.activate([
            editModeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Expanded: true horizontal center in the terminal column.
        expandedConstraints = [
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: editModeButton.leadingAnchor, constant: -8),
            editModeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ]

        collapsedConstraints = [
            trafficLightSlot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            trafficLightSlot.centerYAnchor.constraint(equalTo: centerYAnchor),
            trafficLightSlot.widthAnchor.constraint(equalToConstant: 70),
            trafficLightSlot.heightAnchor.constraint(equalToConstant: 14),

            collapsedLeadingStack.leadingAnchor.constraint(
                equalTo: trafficLightSlot.trailingAnchor, constant: 8),
            collapsedLeadingStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(
                equalTo: collapsedLeadingStack.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: editModeButton.leadingAnchor, constant: -8),

            editModeButton.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor, constant: -4),

            expandButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            expandButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ChromeLayoutMetrics.headerHeight),
        ])

        setupEditStripConstraints()
        applyCollapsedState()
    }

    /// The strips span the row between the leading controls and the trailing
    /// buttons. Both leading anchors are installed at once and swapped by collapse
    /// state, mirroring how the title label is anchored.
    private func setupEditStripConstraints() {
        let terminalTrailing = editTerminalStrip.trailingAnchor.constraint(equalTo: leadingAnchor)
        let previewLeading = editPreviewStrip.leadingAnchor.constraint(equalTo: leadingAnchor)
        stripSeamConstraints = [terminalTrailing, previewLeading]

        stripLeadingCollapsed = editTerminalStrip.leadingAnchor.constraint(
            equalTo: collapsedLeadingStack.trailingAnchor, constant: 10)
        stripLeadingExpanded = editTerminalStrip.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: 12)

        stripConstraints = [
            editTerminalStrip.centerYAnchor.constraint(equalTo: centerYAnchor),
            terminalTrailing,
            previewLeading,
            editPreviewStrip.centerYAnchor.constraint(equalTo: centerYAnchor),
            editPreviewStrip.trailingAnchor.constraint(
                equalTo: editModeButton.leadingAnchor, constant: -8),
        ]
        NSLayoutConstraint.activate(stripConstraints)
    }

    private func configureExpandButton() {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let image = NSImage(systemSymbolName: "sidebar.left",
                               accessibilityDescription: "Expand Sidebar") {
            expandButton.image = image.withSymbolConfiguration(config)
        }
        expandButton.bezelStyle = .recessed
        expandButton.isBordered = false
        expandButton.imagePosition = .imageOnly
        expandButton.contentTintColor = NSColor(hex: 0x888888)
        expandButton.target = self
        expandButton.action = #selector(expandClicked)
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.setAccessibilityIdentifier("chrome.icon.sidebar")
        expandButton.setAccessibilityLabel("Expand Sidebar")
        expandButton.wantsLayer = true
        expandButton.layer?.cornerRadius = 7
        NSLayoutConstraint.activate([
            expandButton.widthAnchor.constraint(equalToConstant: 26),
            expandButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    override func layout() {
        super.layout()
        applyStripSeam()
    }

    private func applyCollapsedState() {
        stripLeadingCollapsed?.isActive = isCollapsed
        stripLeadingExpanded?.isActive = !isCollapsed
        if isCollapsed {
            NSLayoutConstraint.deactivate(expandedConstraints)
            NSLayoutConstraint.activate(collapsedConstraints)
            trafficLightSlot.isHidden = false
            collapsedLeadingStack.isHidden = false
            expandButton.isHidden = false
            titleLabel.alignment = .left
        } else {
            NSLayoutConstraint.deactivate(collapsedConstraints)
            NSLayoutConstraint.activate(expandedConstraints)
            trafficLightSlot.isHidden = true
            collapsedLeadingStack.isHidden = true
            expandButton.isHidden = true
            titleLabel.alignment = .center
        }
        needsLayout = true
    }

    private func configureEditModeButton() {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let image = NSImage(systemSymbolName: "square.split.2x1",
                               accessibilityDescription: "Toggle File Edit Layout") {
            editModeButton.image = image.withSymbolConfiguration(config)
        }
        editModeButton.bezelStyle = .recessed
        editModeButton.isBordered = false
        editModeButton.imagePosition = .imageOnly
        editModeButton.target = self
        editModeButton.action = #selector(editModeClicked)
        editModeButton.translatesAutoresizingMaskIntoConstraints = false
        editModeButton.setAccessibilityIdentifier("chrome.icon.editMode")
        editModeButton.setAccessibilityLabel("Toggle File Edit Layout")
        editModeButton.wantsLayer = true
        editModeButton.layer?.cornerRadius = 7
        editModeButton.isEnabled = false
        NSLayoutConstraint.activate([
            editModeButton.widthAnchor.constraint(equalToConstant: 26),
            editModeButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    /// Enable + light the edit-mode toggle. `available` gates it on there being
    /// at least one open preview (empty set → focus mode only).
    func setEditMode(available: Bool, isOn: Bool) {
        editModeOn = isOn
        editModeButton.isEnabled = available
        applyTitleText()
        refreshImmersion()
    }

    /// Which cabin the columns belong to (`repo · branch`). Shown only in edit mode.
    func setCabinContext(_ context: String) {
        cabinContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        applyTitleText()
    }

    // MARK: - Hoisted edit-mode tab strips

    /// Adopt edit mode's two column tab strips onto this row, so the columns don't
    /// need a second strip row below an otherwise near-empty header.
    ///
    /// The header and the edit container both fill the terminal column, so they
    /// share a width — the seam is computed with the same formula rather than
    /// converting coordinates. The left strip still starts after the traffic
    /// lights and icons (that space is not ours to take), but the seam between
    /// the two strips lands exactly on the column divider.
    func setEditStripsActive(_ active: Bool, ratio: CGFloat) {
        stripRatio = ratio
        guard active != editStripsActive else { applyStripSeam(); return }
        editStripsActive = active
        editTerminalStrip.isHidden = !active
        editPreviewStrip.isHidden = !active
        if active { applyStripSeam() }
        applyTitleText()
    }

    /// Follow the column divider while it is dragged.
    func setEditStripRatio(_ ratio: CGFloat) {
        guard editStripsActive else { return }
        stripRatio = ratio
        applyStripSeam()
    }

    private var hasHoistedStrips: Bool { editStripsActive }

    /// Minimum width a hoisted strip keeps before the seam stops tracking the
    /// divider — enough for a truncated tab, never a negative width.
    private static let minHoistedStripWidth: CGFloat = 40

    /// Same seam math as `EditLayoutContainerView.layout()`, against the same width
    /// — the header and the edit container both fill the terminal column, so the
    /// seam lands on the divider without converting coordinates.
    ///
    /// The header's usable span is narrower than the column's (traffic lights and
    /// icons on one end, buttons on the other), so a divider dragged near either
    /// edge is clamped: the seam stops following rather than driving a strip to a
    /// negative width and breaking the whole row's layout.
    private func applyStripSeam() {
        guard stripSeamConstraints.count == 2 else { return }
        let seam = DividerView.thickness
        let raw = floor((bounds.width - seam) * stripRatio)

        let leadingEdge = isCollapsed ? collapsedLeadingStack.frame.maxX + 10 : 12
        let trailingEdge = editModeButton.frame.minX - 8
        let minLeft = leadingEdge + Self.minHoistedStripWidth
        let maxLeft = trailingEdge - seam - Self.minHoistedStripWidth

        let leftWidth = maxLeft > minLeft ? min(max(raw, minLeft), maxLeft) : raw
        stripSeamConstraints[0].constant = leftWidth           // terminal strip trailing
        stripSeamConstraints[1].constant = leftWidth + seam     // preview strip leading
    }

    /// Edit mode puts a tab strip above each column and every strip labels its own
    /// panes, so a single centered pane title is redundant at best and names the
    /// wrong column at worst. The band itself has to stay — it carries the traffic
    /// lights — so rather than leaving it blank, it shows the one thing no strip
    /// says: which cabin you are in.
    private func applyTitleText() {
        // The strips occupy the whole row when hoisted; nothing else fits.
        titleLabel.isHidden = hasHoistedStrips
        let text = editModeOn ? cabinContext : paneTitle
        titleLabel.stringValue = text
        // A file path loses the part that identifies it — the filename — to tail
        // truncation, so paths give up their middle instead.
        titleLabel.lineBreakMode = Self.isPathLike(text) ? .byTruncatingMiddle : .byTruncatingTail
        titleLabel.toolTip = text.isEmpty ? nil : text
        applyTitleEmphasis()
    }

    /// A single path-shaped token, as opposed to a prose title or a command line
    /// that merely mentions a directory.
    static func isPathLike(_ text: String) -> Bool {
        text.contains("/") && !text.contains(where: { $0 == " " || $0 == "\t" })
    }

    /// Context reads as a quieter label than a title, so it doesn't compete with
    /// the tab strips directly below it.
    private func applyTitleEmphasis() {
        titleLabel.font = editModeOn
            ? NSFont.systemFont(ofSize: 11, weight: .regular)
            : NSFont.systemFont(ofSize: 12, weight: .semibold)
    }

    var titleTextForTesting: String { titleLabel.stringValue }
    var titleLineBreakModeForTesting: NSLineBreakMode { titleLabel.lineBreakMode }
    var titleToolTipForTesting: String? { titleLabel.toolTip }
    var isTitleHiddenForTesting: Bool { titleLabel.isHidden }

    @objc private func expandClicked() {
        delegate?.chromeDidToggleSidebar()
    }

    @objc private func editModeClicked() {
        delegate?.chromeDidToggleEditMode()
    }

    // MARK: - Window drag / zoom

    override var mouseDownCanMoveWindow: Bool { false }

    /// Claim non-button points so `mouseDown` can handle drag/zoom.
    /// Buttons (icon cluster, expand, edit-mode) still get their own hits.
    ///
    /// Edit mode's tab strips also have to be let through: their tabs are plain
    /// views rather than `NSButton`s, so the drag claim below would turn every tab
    /// click into a window drag. The strips only report hits that land on a tab,
    /// so the empty part of the row still drags the window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point) {
            if hit is NSButton { return hit }
            if hit.isDescendant(of: editTerminalStrip) || hit.isDescendant(of: editPreviewStrip) {
                return hit
            }
        }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshImmersion()
    }

    /// Match Ghostty surface colors so the title strip disappears into the terminal.
    func refreshImmersion() {
        let bridge = GhosttyBridge.shared
        layer?.backgroundColor = bridge.terminalChromeBackground.cgColor
        titleLabel.textColor = editModeOn
            ? bridge.terminalChromeForeground.withAlphaComponent(0.55)
            : bridge.terminalChromeForeground
        expandButton.contentTintColor = bridge.terminalChromeForeground.withAlphaComponent(0.55)
        let editTint = editModeButton.isEnabled
            ? (editModeOn
                ? SemanticColors.accent
                : bridge.terminalChromeForeground.withAlphaComponent(0.55))
            : bridge.terminalChromeForeground.withAlphaComponent(0.2)
        editModeButton.contentTintColor = editTint
        editModeButton.layer?.backgroundColor = editModeOn && editModeButton.isEnabled
            ? SemanticColors.accent.withAlphaComponent(0.15).cgColor
            : NSColor.clear.cgColor
    }
}

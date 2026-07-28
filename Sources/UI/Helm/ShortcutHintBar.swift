import AppKit

/// Permanent shortcut cheat-strip pinned to the bottom of the fleet column,
/// where the First Mate composer used to live.
///
/// The composer and the ORDERS carousel both moved into the island — it is now
/// the single command/suggestion surface — so this strip is what the freed space
/// buys back: the handful of chords that actually drive the app, always visible
/// instead of hidden behind `?`.
///
/// Laid out three pairs per line, dropping to two when the sidebar is dragged
/// too narrow for that. Edit `Self.items` to change what shows.
final class ShortcutHintBar: NSView {

    /// Clicking anywhere on the strip opens the full `?` cheat-sheet — the strip
    /// is a teaser for it, so the whole thing is the affordance.
    var onShowAllShortcuts: (() -> Void)?

    /// Most-used first, read left-to-right then wrapped. Keep the key glyphs in
    /// sync with `GlobalKeymap` and the labels with `KeyboardHelpOverlay`.
    ///
    /// The cabin cycle leads: with the bare-key nav ring gone it is the only way
    /// to move between cabins from the keyboard, so it has to be the first thing
    /// the strip says.
    ///
    /// Six is the ceiling — the strip is budgeted at two lines of three (see
    /// `ShortcutHintBarTests`), so making room for the cycle cost `⇧⌘D`, the one
    /// chord a reader can guess from the `⌘D` sitting next to it.
    private static let items: [(key: String, label: String)] = [
        ("\u{2303}\u{21E5}", "Cabin+"),
        ("\u{2303}\u{21E7}\u{21E5}", "Cabin-"),
        ("\u{2318}P", "Command"),
        ("\u{2318}W", "Close"),
        ("\u{2318}D", "Split"),
        ("?", "Keys"),
    ]

    private static let chipBg = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 120/255, green: 210/255, blue: 225/255, alpha: 0.07)
            : NSColor(srgbRed: 0x1f/255, green: 0x23/255, blue: 0x2b/255, alpha: 0.06)
    }
    private static let topLine = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 150/255, green: 215/255, blue: 225/255, alpha: 0.10)
            : NSColor(srgbRed: 0x1f/255, green: 0x23/255, blue: 0x2b/255, alpha: 0.10)
    }

    /// Horizontal room the grid needs beyond its own content (the two 15pt insets).
    private static let horizontalInsets: CGFloat = 30

    private let rule = NSView()
    private let grid = NSGridView()
    /// Chip backgrounds are layer fills, so they need re-resolving on a
    /// light/dark flip like every other `wantsLayer` view in this column.
    private var chips: [NSView] = []

    /// Pairs per line: 3 normally, 2 once the sidebar is too narrow for 3.
    private var pairsPerRow = 3
    /// Width the 3-per-line layout needs, measured once so `layout()` knows when
    /// it can go back to it after the sidebar widens again.
    private var wideFittingWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("overview.shortcutHints")
        setAccessibilityLabel("Keyboard shortcuts")
        toolTip = "Keyboard shortcuts — click for the full list (?)"

        rule.wantsLayer = true
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)

        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 5
        grid.columnSpacing = 6
        addSubview(grid)

        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),

            grid.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -15),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])

        buildGrid()
        wideFittingWidth = grid.fittingSize.width

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(barClicked)))
        refreshColors()
    }

    /// Rebuild the rows for the current `pairsPerRow`. Cheap enough (12 labels)
    /// to redo on the rare width flip, and it keeps one grid rather than two
    /// with duelling constraints.
    private func buildGrid() {
        clearGrid()
        chips = []
        for line in stride(from: 0, to: Self.items.count, by: pairsPerRow) {
            let pairs = Self.items[line ..< min(line + pairsPerRow, Self.items.count)]
            grid.addRow(with: pairs.flatMap { [chip($0.key), caption($0.label)] })
        }
        // Key columns hug their chip; the caption columns take the slack, so a
        // short chip like `?` doesn't leave a hole before its label.
        for column in 0 ..< grid.numberOfColumns {
            grid.column(at: column).xPlacement = .leading
        }
    }

    /// `NSGridView.removeRow(at:)` drops the row but leaves each cell's content
    /// view parented to the grid, where it keeps drawing at its old position —
    /// re-laying out on a sidebar drag would stack every past layout on top of
    /// the current one. Detach the views first.
    private func clearGrid() {
        while grid.numberOfRows > 0 {
            let row = grid.row(at: 0)
            for index in 0 ..< row.numberOfCells {
                row.cell(at: index).contentView?.removeFromSuperview()
            }
            grid.removeRow(at: 0)
        }
    }

    override func layout() {
        super.layout()
        let available = bounds.width - Self.horizontalInsets
        guard available > 0, wideFittingWidth > 0 else { return }
        // Asymmetric threshold: widening back to 3 per line needs a few points of
        // headroom, so a drag that parks right on the boundary doesn't flap the
        // layout back and forth on every pass.
        let wanted: Int
        if pairsPerRow == 3 {
            wanted = wideFittingWidth <= available ? 3 : 2
        } else {
            wanted = wideFittingWidth + 8 <= available ? 3 : 2
        }
        guard wanted != pairsPerRow else { return }
        pairsPerRow = wanted
        buildGrid()
        refreshColors()
    }

    /// A key glyph in a rounded chip, mirroring the `?` overlay's key styling.
    private func chip(_ key: String) -> NSView {
        let label = NSTextField(labelWithString: key)
        label.font = AppFont.mono(size: 10.5)
        label.textColor = SemanticColors.text
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.layer?.cornerRadius = 3
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -5),
        ])
        chips.append(wrap)
        return wrap
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = AppFont.mono(size: 10.5)
        label.textColor = SemanticColors.muted
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        // Truncate the caption rather than shove the next chip column off-screen
        // when the sidebar is dragged narrow.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    @objc private func barClicked() {
        onShowAllShortcuts?()
    }

    /// Test accessors: how the strip wrapped at the current width.
    var rowCountForTesting: Int { grid.numberOfRows }
    /// How many chord/caption pairs `items` currently declares.
    static var itemCountForTesting: Int { items.count }
    var pairsPerRowForTesting: Int { pairsPerRow }
    var wideFittingWidthForTesting: CGFloat { wideFittingWidth }
    /// How many chord/caption pairs the strip advertises, so the ghost-row test
    /// doesn't have to restate `items.count` every time the list is edited.
    var itemCountForTesting: Int { Self.items.count }
    /// Live cell views under the grid — catches rows orphaned by a re-wrap.
    var contentViewCountForTesting: Int { grid.subviews.count }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        layer?.backgroundColor = NSColor.clear.cgColor
        rule.layer?.backgroundColor = resolvedCGColor(Self.topLine)
        for chip in chips {
            chip.layer?.backgroundColor = resolvedCGColor(Self.chipBg)
        }
    }
}

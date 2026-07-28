import AppKit

/// Layout primitives for the Settings window.
///
/// Settings used to be an `NSTabView` where every tab hand-placed its controls.
/// That stopped scaling: a new option meant a fresh constraint block, and a tab
/// bar only holds so many labels. This is the shape macOS settings converged on
/// — a sidebar of pages, and inside a page, titled groups of uniform rows.
///
/// The point is that a new option is one `SettingsRow.make(...)` call, so these
/// types stay dumb: they own spacing, fills, and nothing else.
enum SettingsChrome {
    static let sidebarWidth: CGFloat = 200
    static let rowInset: CGFloat = 16
    static let groupSpacing: CGFloat = 26
    static let cornerRadius: CGFloat = 10
    static let controlCornerRadius: CGFloat = 7
    /// Right-hand controls share one edge across every group, so a page reads as
    /// a column of values rather than a ragged set of widgets.
    static let controlWidth: CGFloat = 200
    /// Traffic lights sit over the sidebar, so its content starts below them.
    static let titlebarInset: CGFloat = 44
}

/// The Settings window runs its own neutral palette rather than the app's teal.
///
/// The app chrome is a saturated navy that works behind terminals; the same
/// `Theme.border` used as a hairline around every settings card reads as a stack
/// of bright outlines. Settings wants surfaces that separate by *fill* — a card
/// one step lighter than the page, a control one step lighter again — and no
/// strokes at all.
enum SettingsPalette {
    static let windowBg: NSColor = dynamic(dark: 0x1a1a1c, light: 0xf2f2f4)
    static let sidebarBg: NSColor = dynamic(dark: 0x161617, light: 0xeaeaec)
    static let cardBg: NSColor = dynamic(dark: 0x212123, light: 0xffffff)
    /// Popup buttons, text fields — one step above the card.
    static let controlBg: NSColor = dynamic(dark: 0x2d2d30, light: 0xf0f0f2)
    static let sidebarSelected: NSColor = dynamic(dark: 0x2f2f32, light: 0xdcdce0)
    static let separator: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.06)
                          : NSColor.black.withAlphaComponent(0.07)
    }
    static let text: NSColor = dynamic(dark: 0xe8e8ea, light: 0x1c1c1e)
    static let secondary: NSColor = dynamic(dark: 0x98989d, light: 0x6c6c70)

    private static func dynamic(dark: Int, light: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(hex: appearance.isDark ? dark : light)
        }
    }
}

/// Top-down container for scroll view content. AppKit's origin is bottom-left,
/// which parks a short page at the bottom of the clip view instead of the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Controls

/// Text field styled like the reference popup buttons: filled, rounded, no
/// bezel, no focus ring.
final class SettingsTextField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyStyle()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        applyStyle()
    }

    private func applyStyle() {
        let padded = PaddedCell(textCell: "")
        padded.isEditable = true
        padded.isSelectable = true
        padded.isScrollable = true
        padded.usesSingleLineMode = true
        padded.lineBreakMode = .byClipping
        cell = padded

        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: 13)
        textColor = SettingsPalette.text
        alignment = .right
        wantsLayer = true
        layer?.cornerRadius = SettingsChrome.controlCornerRadius
        layer?.backgroundColor = SettingsPalette.controlBg.cgColor
    }

    override func updateLayer() {
        layer?.backgroundColor = SettingsPalette.controlBg.cgColor
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width, height: 28)
    }

    /// Insets the text so it doesn't touch the rounded fill.
    private final class PaddedCell: NSTextFieldCell {
        private let inset = NSSize(width: 9, height: 5)

        override func drawingRect(forBounds rect: NSRect) -> NSRect {
            super.drawingRect(forBounds: rect.insetBy(dx: inset.width, dy: inset.height))
        }

        override func edit(withFrame rect: NSRect, in view: NSView,
                           editor: NSText, delegate: Any?, event: NSEvent?) {
            super.edit(withFrame: drawingRect(forBounds: rect), in: view,
                       editor: editor, delegate: delegate, event: event)
        }

        override func select(withFrame rect: NSRect, in view: NSView, editor: NSText,
                             delegate: Any?, start: Int, length: Int) {
            super.select(withFrame: drawingRect(forBounds: rect), in: view, editor: editor,
                         delegate: delegate, start: start, length: length)
        }
    }
}

enum SettingsControls {
    /// The reference uses a switch for booleans, not a checkbox.
    static func toggle(on: Bool, target: AnyObject, action: Selector) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.state = on ? .on : .off
        toggle.target = target
        toggle.action = action
        return toggle
    }

    /// Wraps a scroll view (list, editor, table) in the same filled, unstroked
    /// surface the single-line controls use.
    static func surface(_ content: NSView, height: CGFloat? = nil) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = SettingsPalette.controlBg.cgColor
        box.layer?.cornerRadius = SettingsChrome.controlCornerRadius
        box.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)

        var constraints = [
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
        ]
        if let height { constraints.append(box.heightAnchor.constraint(equalToConstant: height)) }
        NSLayoutConstraint.activate(constraints)
        return box
    }

    static func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12)
        return button
    }
}

// MARK: - Rows

enum SettingsRow {
    /// One `title — control` line. `subtitle` is the sentence that stops a
    /// setting being a guess; it wraps and grows the row.
    static func make(_ title: String,
                     subtitle: String? = nil,
                     control: NSView? = nil,
                     accessibilityId: String? = nil) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityIdentifier(accessibilityId)

        let titleLabel = label(title)
        row.addSubview(titleLabel)

        var constraints: [NSLayoutConstraint] = [
            titleLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor,
                                                constant: SettingsChrome.rowInset),
        ]

        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(control)
            constraints += [
                control.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                control.trailingAnchor.constraint(equalTo: row.trailingAnchor,
                                                  constant: -SettingsChrome.rowInset),
                control.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor,
                                                 constant: 12),
            ]
            // Switches and buttons size themselves; value fields share the column.
            if control is SettingsTextField {
                constraints.append(control.widthAnchor.constraint(
                    equalToConstant: SettingsChrome.controlWidth))
            }
        } else {
            constraints.append(titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: row.trailingAnchor, constant: -SettingsChrome.rowInset))
        }

        if let subtitle {
            let hint = makeHint(subtitle)
            row.addSubview(hint)
            constraints += [
                hint.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
                hint.leadingAnchor.constraint(equalTo: row.leadingAnchor,
                                              constant: SettingsChrome.rowInset),
                hint.trailingAnchor.constraint(equalTo: row.trailingAnchor,
                                               constant: -SettingsChrome.rowInset),
                hint.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
            ]
        } else {
            constraints += [
                titleLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
                row.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            ]
        }

        NSLayoutConstraint.activate(constraints)
        return row
    }

    /// A row whose content needs the full width — a list, an editor, a QR code.
    /// The title sits above it instead of beside it.
    static func stacked(_ title: String?,
                        subtitle: String? = nil,
                        content: NSView,
                        height: CGFloat? = nil) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false

        var previous: NSView?
        var constraints: [NSLayoutConstraint] = []

        if let title {
            let titleLabel = label(title)
            row.addSubview(titleLabel)
            constraints += [
                titleLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
                titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor,
                                                    constant: SettingsChrome.rowInset),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor,
                                                     constant: -SettingsChrome.rowInset),
            ]
            previous = titleLabel
        }

        if let subtitle {
            let hint = makeHint(subtitle)
            row.addSubview(hint)
            constraints += [
                hint.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? row.topAnchor,
                                          constant: previous == nil ? 14 : 3),
                hint.leadingAnchor.constraint(equalTo: row.leadingAnchor,
                                              constant: SettingsChrome.rowInset),
                hint.trailingAnchor.constraint(equalTo: row.trailingAnchor,
                                               constant: -SettingsChrome.rowInset),
            ]
            previous = hint
        }

        row.addSubview(content)
        constraints += [
            content.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? row.topAnchor,
                                         constant: previous == nil ? 14 : 10),
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor,
                                             constant: SettingsChrome.rowInset),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor,
                                              constant: -SettingsChrome.rowInset),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
        ]
        if let height {
            constraints.append(content.heightAnchor.constraint(equalToConstant: height))
        }

        NSLayoutConstraint.activate(constraints)
        return row
    }

    /// A row of buttons, right-aligned like the controls above them.
    static func actions(_ buttons: [NSView], leading: [NSView] = []) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: buttons)
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)

        var constraints = [
            stack.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor,
                                            constant: -SettingsChrome.rowInset),
        ]

        if !leading.isEmpty {
            let leadingStack = NSStackView(views: leading)
            leadingStack.spacing = 8
            leadingStack.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(leadingStack)
            constraints += [
                leadingStack.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
                leadingStack.leadingAnchor.constraint(equalTo: row.leadingAnchor,
                                                      constant: SettingsChrome.rowInset),
                leadingStack.trailingAnchor.constraint(lessThanOrEqualTo: stack.leadingAnchor,
                                                       constant: -12),
            ]
        }

        NSLayoutConstraint.activate(constraints)
        return row
    }

    static func makeHint(_ text: String) -> NSTextField {
        let hint = NSTextField(wrappingLabelWithString: text)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = SettingsPalette.secondary
        hint.isSelectable = false
        hint.translatesAutoresizingMaskIntoConstraints = false
        return hint
    }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = SettingsPalette.text
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}

// MARK: - Groups

/// A titled card of rows. Rows separate by a faint hairline; the card itself has
/// no stroke — it reads as a raised fill.
final class SettingsGroupView: NSView {
    init(title: String?, rows: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = SettingsPalette.cardBg.cgColor
        card.layer?.cornerRadius = SettingsChrome.cornerRadius
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        for (index, row) in rows.enumerated() {
            if index > 0 { stack.addArrangedSubview(Self.separator()) }
            stack.addArrangedSubview(row)
        }

        var constraints: [NSLayoutConstraint] = [
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ]
        // NSStackView only stretches along its axis, so cross-axis width is
        // pinned per child.
        for child in stack.arrangedSubviews {
            constraints.append(child.leadingAnchor.constraint(equalTo: stack.leadingAnchor))
            constraints.append(child.trailingAnchor.constraint(equalTo: stack.trailingAnchor))
        }

        if let title {
            let header = NSTextField(labelWithString: title.uppercased())
            header.font = .systemFont(ofSize: 11, weight: .semibold)
            header.textColor = SettingsPalette.secondary
            header.translatesAutoresizingMaskIntoConstraints = false
            addSubview(header)
            constraints += [
                header.topAnchor.constraint(equalTo: topAnchor),
                header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                card.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 9),
            ]
        } else {
            constraints.append(card.topAnchor.constraint(equalTo: topAnchor))
        }

        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private static func separator() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = SettingsPalette.separator.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }
}

// MARK: - Sidebar

/// The page list, with the search field above it. A stack of buttons rather than
/// an `NSTableView`: there are a handful of fixed pages, and owning the pill
/// highlight directly beats fighting `NSTableView`'s selection styling.
final class SettingsSidebarView: NSView {
    struct Item {
        let id: String
        let title: String
        /// SF Symbol name.
        let symbol: String
        /// Extra words the search field matches, beyond the title.
        var keywords: [String] = []
    }

    var onSelect: ((String) -> Void)?
    private(set) var selectedId: String?

    private let items: [Item]
    private var buttons: [String: SidebarButton] = [:]
    private let searchField = NSSearchField()
    private let stack = NSStackView()

    init(items: [Item]) {
        self.items = items
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = SettingsPalette.sidebarBg.cgColor

        searchField.placeholderString = "Search"
        searchField.font = .systemFont(ofSize: 12)
        searchField.focusRingType = .none
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityIdentifier("settings.sidebar.search")
        addSubview(searchField)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for item in items {
            let button = SidebarButton(item: item)
            button.onClick = { [weak self] in self?.select(item.id) }
            buttons[item.id] = button
            stack.addArrangedSubview(button)
            button.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            button.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor,
                                             constant: SettingsChrome.titlebarInset),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            stack.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func select(_ id: String) {
        guard selectedId != id else { return }
        selectedId = id
        for (buttonId, button) in buttons { button.isSelected = buttonId == id }
        onSelect?(id)
    }

    /// Flag a page that needs attention (a missing permission, a stale session).
    func setBadge(_ text: String?, for id: String) {
        buttons[id]?.badge = text
    }

    /// Filter the page list. Hiding rather than reordering keeps the list stable
    /// while typing, and the current page stays listed even when it stops
    /// matching — yanking the visible page out of the list mid-search reads as a
    /// bug.
    @objc private func searchChanged() {
        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespaces)
            .lowercased()

        for item in items {
            guard let button = buttons[item.id] else { continue }
            let haystack = ([item.title] + item.keywords).map { $0.lowercased() }
            let matches = query.isEmpty || haystack.contains { $0.contains(query) }
            button.isHidden = !(matches || item.id == selectedId)
        }
    }

    // MARK: -

    private final class SidebarButton: NSView {
        var onClick: (() -> Void)?
        var isSelected = false { didSet { updateAppearance() } }
        var badge: String? {
            didSet {
                badgeLabel.stringValue = badge ?? ""
                badgeLabel.isHidden = badge == nil
            }
        }

        private let iconView = NSImageView()
        private let titleLabel: NSTextField
        private let badgeLabel = NSTextField(labelWithString: "")

        init(item: Item) {
            titleLabel = NSTextField(labelWithString: item.title)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true
            layer?.cornerRadius = 6

            iconView.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            iconView.contentTintColor = SettingsPalette.secondary
            iconView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)

            titleLabel.font = .systemFont(ofSize: 13)
            titleLabel.textColor = SettingsPalette.secondary
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(titleLabel)

            badgeLabel.font = .systemFont(ofSize: 11, weight: .medium)
            badgeLabel.textColor = .systemOrange
            badgeLabel.isHidden = true
            badgeLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(badgeLabel)

            setAccessibilityIdentifier("settings.sidebar.\(item.id)")

            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 32),
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 16),

                titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

                badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                badgeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor,
                                                    constant: 4),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        override func mouseDown(with event: NSEvent) { onClick?() }

        private func updateAppearance() {
            layer?.backgroundColor = isSelected ? SettingsPalette.sidebarSelected.cgColor
                                                : NSColor.clear.cgColor
            let color = isSelected ? SettingsPalette.text : SettingsPalette.secondary
            titleLabel.textColor = color
            iconView.contentTintColor = color
        }
    }
}

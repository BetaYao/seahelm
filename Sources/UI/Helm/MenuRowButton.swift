import AppKit

/// A single autocomplete row: `‹trigger› name … desc`, with hover highlight.
/// `/ @ #` autocomplete row. Internal so the Dashboard overview's composer can
/// render the command menu.
final class MenuRowButton: NSView {
    private var trackingArea: NSTrackingArea?
    private var selected = false
    private var hovered = false
    private let accentBar = NSView()
    private let nameLabel: NSTextField
    private let descLabel: NSTextField
    private let symLabel: NSTextField
    private let triggerColor: NSColor

    var onPick: (() -> Void)?

    func setSelected(_ on: Bool) {
        selected = on
        refreshBackground()
        accentBar.isHidden = !on
    }

    init(name: String, desc: String, triggerSymbol: String, triggerColor: NSColor) {
        self.triggerColor = triggerColor
        self.symLabel = NSTextField(labelWithString: triggerSymbol)
        self.nameLabel = NSTextField(labelWithString: name)
        self.descLabel = NSTextField(labelWithString: desc)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        accentBar.wantsLayer = true
        accentBar.isHidden = true
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentBar)
        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: topAnchor),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 2),
        ])

        symLabel.font = AppFont.mono(size: 12, weight: .bold)
        symLabel.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = AppFont.mono(size: 12, weight: .regular)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        descLabel.font = AppFont.mono(size: 11, weight: .regular)
        descLabel.alignment = .right
        descLabel.lineBreakMode = .byTruncatingTail
        descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(symLabel)
        addSubview(nameLabel)
        addSubview(descLabel)
        NSLayoutConstraint.activate([
            symLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            symLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: symLabel.trailingAnchor, constant: 9),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            descLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 10),
            descLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            descLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refreshColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        accentBar.layer?.backgroundColor = resolvedCGColor(triggerColor)
        symLabel.textColor = triggerColor
        nameLabel.textColor = SemanticColors.text
        descLabel.textColor = SemanticColors.muted
        refreshBackground()
    }

    private func refreshBackground() {
        let fill: NSColor
        if selected {
            fill = NSColor.controlAccentColor.withAlphaComponent(0.18)
        } else if hovered {
            fill = NSColor.controlAccentColor.withAlphaComponent(0.10)
        } else {
            fill = .clear
        }
        layer?.backgroundColor = resolvedCGColor(fill)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); trackingArea = t
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true
        refreshBackground()
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        refreshBackground()
    }
    // mouseDown (not click recognizer) so the field editor's resignFirstResponder
    // doesn't swallow the first interaction with the menu.
    override func mouseDown(with event: NSEvent) { onPick?() }
}

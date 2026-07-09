import AppKit

/// A single autocomplete row: `‹trigger› name … desc`, with hover highlight.
/// `/ @ #` autocomplete row. Internal so the Dashboard overview's composer can
/// render the command menu.
final class MenuRowButton: NSView {
    private static let ink      = NSColor(srgbRed: 0xcf/255, green: 0xe0/255, blue: 0xe0/255, alpha: 1)
    private static let inkFaint = NSColor(srgbRed: 0x55/255, green: 0x71/255, blue: 0x70/255, alpha: 1)
    private static let hoverBg  = NSColor(srgbRed: 0x1f/255, green: 0xc8/255, blue: 0xda/255, alpha: 0.10)

    private static let selBg    = NSColor(srgbRed: 0x1f/255, green: 0xc8/255, blue: 0xda/255, alpha: 0.16)

    var onPick: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var selected = false
    private let accentBar = NSView()

    func setSelected(_ on: Bool) {
        selected = on
        layer?.backgroundColor = (on ? Self.selBg : NSColor.clear).cgColor
        accentBar.isHidden = !on
    }

    init(name: String, desc: String, triggerSymbol: String, triggerColor: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = triggerColor.cgColor
        accentBar.isHidden = true
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentBar)
        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: topAnchor),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 2),
        ])

        let sym = NSTextField(labelWithString: triggerSymbol)
        sym.font = AppFont.mono(size: 12, weight: .bold)
        sym.textColor = triggerColor
        sym.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = AppFont.mono(size: 12, weight: .regular)
        nameLabel.textColor = Self.ink
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let descLabel = NSTextField(labelWithString: desc)
        descLabel.font = AppFont.mono(size: 11, weight: .regular)
        descLabel.textColor = Self.inkFaint
        descLabel.alignment = .right
        descLabel.lineBreakMode = .byTruncatingTail
        descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(sym); addSubview(nameLabel); addSubview(descLabel)
        NSLayoutConstraint.activate([
            sym.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            sym.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: sym.trailingAnchor, constant: 9),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            descLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 10),
            descLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            descLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); trackingArea = t
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = Self.hoverBg.cgColor }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = (selected ? Self.selBg : NSColor.clear).cgColor
    }
    // mouseDown (not click recognizer) so the field editor's resignFirstResponder
    // doesn't swallow the first interaction with the menu.
    override func mouseDown(with event: NSEvent) { onPick?() }
}

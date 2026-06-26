import AppKit

/// Helm command line: `› ____  / 命令 · @ 仓库 · # agent`.
/// Pure input surface — it emits text changes and submit; the cockpit owns the
/// autocomplete dropdown (so it can float over the Orders/Watch list unclipped).
/// Keyboard navigation of the menu is deferred to WP-6; completion is mouse-driven.
final class CommandInputView: NSView {

    // Bare-TUI palette (prototype THEME.A)
    private static let ink        = NSColor(srgbRed: 0xcf/255, green: 0xe0/255, blue: 0xe0/255, alpha: 1)
    private static let inkFaint   = NSColor(srgbRed: 0x55/255, green: 0x71/255, blue: 0x70/255, alpha: 1)
    private static let accent     = NSColor(srgbRed: 0x1f/255, green: 0xc8/255, blue: 0xda/255, alpha: 1)
    private static let cornflower = NSColor(srgbRed: 0x5b/255, green: 0x93/255, blue: 0xf0/255, alpha: 1)
    private static let orange     = NSColor(srgbRed: 0xff/255, green: 0x8a/255, blue: 0x3d/255, alpha: 1)

    var onTextChanged: ((String) -> Void)?
    var onSubmit: ((String) -> Void)?

    private let field = NSTextField()

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        let prompt = NSTextField(labelWithString: "›")
        prompt.font = AppFont.mono(size: 13, weight: .bold)
        prompt.textColor = Self.accent
        prompt.translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AppFont.mono(size: 12, weight: .regular)
        field.textColor = Self.ink
        field.placeholderString = "下达指令 — / 命令 · @ 仓库 · # agent"
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityIdentifier("helm.commandInput")

        let hint = makeHintRow()

        addSubview(prompt)
        addSubview(field)
        addSubview(hint)

        NSLayoutConstraint.activate([
            prompt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            prompt.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            field.leadingAnchor.constraint(equalTo: prompt.trailingAnchor, constant: 9),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            field.centerYAnchor.constraint(equalTo: prompt.centerYAnchor),

            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            hint.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    private func makeHintRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        let specs: [(String, NSColor, String)] = [
            ("/", Self.accent, "命令"),
            ("@", Self.cornflower, "仓库 / worktree"),
            ("#", Self.orange, "agent"),
        ]
        for (sym, color, label) in specs {
            let s = NSTextField(labelWithString: "")
            let attr = NSMutableAttributedString(
                string: sym,
                attributes: [.foregroundColor: color,
                             .font: AppFont.mono(size: 10.5, weight: .bold)])
            attr.append(NSAttributedString(
                string: " \(label)",
                attributes: [.foregroundColor: Self.inkFaint,
                             .font: AppFont.mono(size: 10.5, weight: .regular)]))
            s.attributedStringValue = attr
            row.addArrangedSubview(s)
        }
        return row
    }

    func focusInput() { window?.makeFirstResponder(field) }

    @objc private func submit() {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onSubmit?(value)
        field.stringValue = ""
        onTextChanged?("")
    }
}

extension CommandInputView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onTextChanged?(field.stringValue)
    }
}

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

    enum MenuKey { case up, down, accept }

    var onTextChanged: ((String) -> Void)?
    var onSubmit: ((String) -> Void)?
    /// Esc pressed while the field is focused (used to close the cockpit).
    var onCancel: (() -> Void)?
    /// Arrow/Enter while the autocomplete menu is open. Return true if the host
    /// consumed it (menu visible) so the keystroke doesn't also edit/submit.
    var onMenuKey: ((MenuKey) -> Bool)?

    private let field = FocusReportingTextField()
    private var hintRow: NSView?
    private let box = NSView()

    /// Anchors of the bordered input box, so the host can align the autocomplete
    /// dropdown to the box's bottom edge (not below the hint row).
    var boxBottomAnchor: NSLayoutYAxisAnchor { box.bottomAnchor }
    var boxLeadingAnchor: NSLayoutXAxisAnchor { box.leadingAnchor }
    var boxTrailingAnchor: NSLayoutXAxisAnchor { box.trailingAnchor }

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private static let lineStrong = NSColor(srgbRed: 150/255, green: 215/255, blue: 225/255, alpha: 0.18)
    private static let boxBg      = NSColor(srgbRed: 120/255, green: 210/255, blue: 225/255, alpha: 0.03)

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        let prompt = NSTextField(labelWithString: "›")
        prompt.font = AppFont.mono(size: 14, weight: .bold)
        prompt.textColor = Self.accent
        prompt.translatesAutoresizingMaskIntoConstraints = false

        // Bordered rounded input box (prototype). The `›` prompt sits outside it.
        box.wantsLayer = true
        box.layer?.cornerRadius = 7
        box.layer?.borderWidth = 1
        box.layer?.borderColor = Self.lineStrong.cgColor
        box.layer?.backgroundColor = Self.boxBg.cgColor
        box.translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AppFont.mono(size: 12.5, weight: .regular)
        field.textColor = Self.ink
        field.placeholderString = "下达指令 — / 命令 · @ 仓库 · # agent"
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityIdentifier("helm.commandInput")
        field.onFocusChange = { [weak self] focused in
            // Hint shows whenever the field is focused (not tied to the menu).
            if focused { self?.hintRow?.isHidden = false }
        }
        box.addSubview(field)

        let hint = makeHintRow()
        hint.isHidden = true  // only shown while the field is focused
        hintRow = hint

        addSubview(prompt)
        addSubview(box)
        addSubview(hint)

        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            box.heightAnchor.constraint(equalToConstant: 40),

            prompt.trailingAnchor.constraint(equalTo: box.leadingAnchor, constant: -9),
            prompt.centerYAnchor.constraint(equalTo: box.centerYAnchor),

            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            field.centerYAnchor.constraint(equalTo: box.centerYAnchor),

            hint.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 2),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor),
            hint.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 8),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
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

    /// Set the text, focus the field, and place the caret at the END (not a
    /// select-all, which would wipe the value on the next keystroke).
    func setTextAndFocusEnd(_ s: String) {
        field.stringValue = s
        window?.makeFirstResponder(field)
        // makeFirstResponder selects all; override to a collapsed caret at end.
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (s as NSString).length, length: 0)
        }
        onTextChanged?(s)
    }

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

    func controlTextDidEndEditing(_ obj: Notification) { hintRow?.isHidden = true }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        case #selector(NSResponder.moveUp(_:)):
            return onMenuKey?(.up) ?? false
        case #selector(NSResponder.moveDown(_:)):
            return onMenuKey?(.down) ?? false
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            // Accept the highlighted menu item if the menu is open; otherwise let
            // the field submit (Enter) / change focus (Tab) as usual.
            return onMenuKey?(.accept) ?? false
        default:
            return false
        }
    }
}

/// NSTextField that reports focus changes (becomeFirstResponder fires on focus,
/// unlike controlTextDidBeginEditing which only fires on the first edit).
final class FocusReportingTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }
}

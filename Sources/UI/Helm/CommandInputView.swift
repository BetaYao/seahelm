import AppKit

/// Helm command line: a bordered input box (`/ command · @ repo · # agent` placeholder).
/// Pure input surface — it emits text changes and submit; the cockpit owns the
/// autocomplete dropdown (so it can float over the Orders/Watch list unclipped).
/// Keyboard navigation of the menu is deferred to WP-6; completion is mouse-driven.
final class CommandInputView: NSView {

    // Bare-TUI palette (prototype THEME.A)
    private static let ink        = NSColor(srgbRed: 0xcf/255, green: 0xe0/255, blue: 0xe0/255, alpha: 1)
    private static let accent     = NSColor(srgbRed: 0x1f/255, green: 0xc8/255, blue: 0xda/255, alpha: 1)

    enum MenuKey { case up, down, accept }

    var onTextChanged: ((String) -> Void)?
    var onSubmit: ((String) -> Void)?
    /// Esc pressed while the field is focused (used to close the cockpit).
    var onCancel: (() -> Void)?
    /// Arrow/Enter while the autocomplete menu is open. Return true if the host
    /// consumed it (menu visible) so the keystroke doesn't also edit/submit.
    var onMenuKey: ((MenuKey) -> Bool)?

    private let field = FocusReportingTextField()
    private let box = NSView()
    private let spinner = NSProgressIndicator()
    private var savedPlaceholder: String?

    /// Anchors of the bordered input box, so the host can align the autocomplete
    /// dropdown to the box's bottom edge.
    var boxBottomAnchor: NSLayoutYAxisAnchor { box.bottomAnchor }
    var boxLeadingAnchor: NSLayoutXAxisAnchor { box.leadingAnchor }
    var boxTrailingAnchor: NSLayoutXAxisAnchor { box.trailingAnchor }

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    /// Corner radius of the input box. Defaults to 7 (Cockpit/THEME B). The
    /// Dashboard overview (Bare TUI / THEME A) sets 0 for square corners.
    var boxCornerRadius: CGFloat = 7 {
        didSet { box.layer?.cornerRadius = boxCornerRadius }
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

        // Bordered rounded input box (prototype).
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
        field.placeholderString = "Give an order — / command · @ repo · # agent"
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityIdentifier("helm.commandInput")
        box.addSubview(field)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(spinner)

        addSubview(box)

        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            box.heightAnchor.constraint(equalToConstant: 40),

            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            field.centerYAnchor.constraint(equalTo: box.centerYAnchor),

            spinner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            spinner.centerYAnchor.constraint(equalTo: box.centerYAnchor),

            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    func focusInput() { window?.makeFirstResponder(field) }

    /// Show a busy state while an async command runs: disable editing, swap the
    /// placeholder to `message`, and spin.
    func setLoading(_ loading: Bool, message: String = "Working…") {
        if loading {
            savedPlaceholder = field.placeholderString
            field.stringValue = ""
            field.placeholderString = message
            field.isEditable = false
            field.isSelectable = false
            spinner.startAnimation(nil)
        } else {
            field.placeholderString = savedPlaceholder ?? field.placeholderString
            field.isEditable = true
            field.isSelectable = true
            spinner.stopAnimation(nil)
        }
    }

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

import AppKit

/// Helm command line (`/ command · @ repo · # agent` placeholder).
/// Pure input surface — it emits text changes and submit; the cockpit owns the
/// autocomplete dropdown (so it can float over the Orders/Watch list unclipped).
/// Keyboard navigation of the menu is deferred to WP-6; completion is mouse-driven.
final class CommandInputView: NSView {

    // Appearance-aware text; accents stay fixed.
    private static let ink: NSColor = SemanticColors.text
    private static let inkDim: NSColor = SemanticColors.muted

    enum MenuKey { case up, down, accept }

    var onTextChanged: ((String) -> Void)?
    var onSubmit: ((String) -> Void)?
    /// Esc pressed while the field is focused (used to close the cockpit).
    var onCancel: (() -> Void)?
    /// Arrow/Enter while the autocomplete menu is open. Return true if the host
    /// consumed it (menu visible) so the keystroke doesn't also edit/submit.
    var onMenuKey: ((MenuKey) -> Bool)?
    /// ↑ pressed while the field is focused, the menu is closed, and the text is
    /// empty — the nav ring reclaims focus. Return true when consumed.
    var onArrowUpAtEmpty: (() -> Bool)?
    /// The field became first responder (keyboard OR mouse click) — lets the
    /// host's focus model track that the command row is active.
    var onFocused: (() -> Void)?
    /// The field resigned first responder (click elsewhere, Tab, etc.).
    var onUnfocused: (() -> Void)?

    private let field = FocusReportingTextField()
    private let box = FrostedPanelView()
    private let spinner = NSProgressIndicator()
    private var savedPlaceholder: String?
    private var placeholder: String = "" {
        didSet { refreshPlaceholder() }
    }

    /// Anchors of the bordered input box, so the host can align the autocomplete
    /// dropdown to the box's bottom edge.
    var boxBottomAnchor: NSLayoutYAxisAnchor { box.bottomAnchor }
    var boxLeadingAnchor: NSLayoutXAxisAnchor { box.leadingAnchor }
    var boxTrailingAnchor: NSLayoutXAxisAnchor { box.trailingAnchor }

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    /// Corner radius of the input box. Defaults to 8 (system menu glass).
    var boxCornerRadius: CGFloat = 8 {
        didSet { box.layer?.cornerRadius = boxCornerRadius }
    }

    /// When false, no hairline border — glass fill only.
    var showsChrome: Bool = true {
        didSet { refreshChromeColors() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        box.kind = .input
        box.translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AppFont.mono(size: 12.5, weight: .regular)
        field.textColor = Self.ink
        placeholder = "Give an order — / command · @ repo · # agent"
        refreshChromeColors()
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityIdentifier("helm.commandInput")
        field.onFocusChange = { [weak self] focused in
            if focused {
                self?.onFocused?()
            } else {
                self?.onUnfocused?()
            }
        }
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChromeColors()
    }

    private func refreshPlaceholder() {
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: Self.inkDim,
                .font: field.font ?? AppFont.mono(size: 12.5, weight: .regular),
            ]
        )
    }

    private func refreshChromeColors() {
        box.kind = .input
        box.layer?.cornerRadius = boxCornerRadius
        if showsChrome {
            box.layer?.borderWidth = 0.5
            box.layer?.borderColor = resolvedCGColor(NSColor.separatorColor.withAlphaComponent(0.55))
        } else {
            box.layer?.borderWidth = 0
            box.layer?.borderColor = nil
        }
        field.textColor = Self.ink
        refreshPlaceholder()
    }

    func focusInput() { window?.makeFirstResponder(field) }

    /// Whether the command field (or its field editor) currently owns focus.
    var isFieldFocused: Bool {
        guard let window else { return false }
        if window.firstResponder === field { return true }
        if let editor = field.currentEditor(), window.firstResponder === editor { return true }
        return false
    }

    /// Show a busy state while an async command runs: disable editing, swap the
    /// placeholder to `message`, and spin.
    func setLoading(_ loading: Bool, message: String = "Working…") {
        if loading {
            savedPlaceholder = placeholder
            field.stringValue = ""
            placeholder = message
            field.isEditable = false
            field.isSelectable = false
            spinner.startAnimation(nil)
        } else {
            placeholder = savedPlaceholder ?? placeholder
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
            if onMenuKey?(.up) == true { return true }
            if field.stringValue.isEmpty { return onArrowUpAtEmpty?() ?? false }
            return false
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
///
/// Unfocus is deferred one turn so we don't treat the handoff to the field
/// editor as a blur — AppKit resigns the text field itself when the editor
/// becomes first responder.
final class FocusReportingTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let window = self.window else {
                    self.onFocusChange?(false)
                    return
                }
                if window.firstResponder === self { return }
                if let editor = self.currentEditor(), window.firstResponder === editor { return }
                self.onFocusChange?(false)
            }
        }
        return ok
    }
}

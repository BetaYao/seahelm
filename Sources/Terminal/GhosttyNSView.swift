import AppKit

// MARK: - GhosttyNSView

/// The NSView subclass that hosts a Ghostty Metal surface.
/// Forwards keyboard and mouse events to the Ghostty C API.
class GhosttyNSView: NSView, NSTextInputClient {
    var surface: ghostty_surface_t?
    weak var station: Station?
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    /// Called when this view becomes first responder (e.g. on mouse click).
    var onFocusAcquired: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        focusRingType = .none
        applyFocusVisualState(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        focusRingType = .none
        applyFocusVisualState(false)
    }

    override var acceptsFirstResponder: Bool { true }

    override var canBecomeKeyView: Bool { true }

    private(set) var lastSyncedSize: NSSize = .zero

    /// Reset the debounce guard so the next syncSurfaceSize() runs unconditionally.
    func resetLastSyncedSize() {
        lastSyncedSize = .zero
    }

    /// Test accessor for lastSyncedSize
    var lastSyncedSizeForTesting: NSSize { lastSyncedSize }

    /// Test helper: set lastSyncedSize to simulate a previous sync
    func resetLastSyncedSizeForTesting(to size: NSSize) {
        lastSyncedSize = size
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSurfaceSize()
    }

    override func removeFromSuperview() {
        super.removeFromSuperview()
        // Reset debounce so the next container gets a fresh sync
        lastSyncedSize = .zero
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let surface, let window else { return }
        let scale = Double(window.backingScaleFactor)
        ghostty_surface_set_content_scale(surface, scale, scale)
        syncSurfaceSize()
    }

    func syncSurfaceSize() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        guard size != lastSyncedSize else { return }
        lastSyncedSize = size

        guard let surface else { return }

        // Update content scale in case we moved to a different window/screen
        if let window {
            let scale = Double(window.backingScaleFactor)
            ghostty_surface_set_content_scale(surface, scale, scale)
        }

        let scale = window?.backingScaleFactor ?? 2.0
        ghostty_surface_set_size(surface, UInt32(size.width * scale), UInt32(size.height * scale))
        ghostty_surface_refresh(surface)
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        applyFocusVisualState(true)
        if let surface {
            ghostty_surface_set_focus(surface, true)
        }
        onFocusAcquired?()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        applyFocusVisualState(false)
        if let surface {
            ghostty_surface_set_focus(surface, false)
        }
        #if DEBUG
        let symbols = Thread.callStackSymbols.prefix(12).joined(separator: "\n")
        NSLog("GhosttyNSView.resignFirstResponder — stack:\n%@", symbols)
        #endif
        return super.resignFirstResponder()
    }

    private func applyFocusVisualState(_ focused: Bool) {
        guard let layer else { return }
        layer.masksToBounds = false
        layer.shadowOffset = .zero
        layer.shadowRadius = 5
        layer.shadowColor = NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
        layer.shadowOpacity = focused ? 0.22 : 0
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard event.type == .keyDown else { return }
        guard let surface else { return }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = hasMarkedText()
        interpretKeyEvents([event])
        syncPreedit(clearIfNeeded: markedTextBefore)

        let accumulated = keyTextAccumulator ?? []
        if !accumulated.isEmpty {
            for text in accumulated {
                sendKey(surface: surface, action: action, event: event, text: text)
            }
            return
        }

        guard Self.shouldSendRawKey(
            markedTextBefore: markedTextBefore,
            hasMarkedTextNow: hasMarkedText(),
            hasAccumulatedText: false
        ) else {
            return
        }

        sendKey(surface: surface, action: action, event: event, text: nil)
    }

    override func doCommand(by selector: Selector) {
        // No-op: prevents AppKit from beeping for unhandled selector commands.
        // Paste is handled in performKeyEquivalent via isPasteShortcut.
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // performKeyEquivalent is called on every view in the hierarchy, not just the
        // first responder. Only the focused GhosttyNSView should handle events to
        // prevent multi-pane routing bugs (paste going to pane 1, etc.).
        guard event.type == .keyDown else { return false }
        guard window?.firstResponder === self else { return false }

        if Self.isPasteShortcut(event) || Self.shouldHandleControlKeyEquivalent(event) {
            // Delegate to Ghostty's native key handling. This preserves:
            //  - Image paste support (Ghostty reads clipboard natively, not just .string)
            //  - Correct Ctrl+C behavior per the session's keyboard protocol level
            if let surface {
                sendKey(surface: surface, action: GHOSTTY_ACTION_PRESS, event: event, text: nil)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @IBAction func paste(_ sender: Any?) {
        guard let surface else { return }
        guard let str = NSPasteboard.general.string(forType: .string), !str.isEmpty else { return }
        str.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
    }

    @IBAction func pasteAsPlainText(_ sender: Any?) {
        paste(sender)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let surface else { return }
        let text: String
        switch string {
        case let attributed as NSAttributedString:
            text = attributed.string
        case let plain as String:
            text = plain
        default:
            return
        }
        guard !text.isEmpty else { return }

        unmarkText()

        if var accumulator = keyTextAccumulator {
            accumulator.append(text)
            keyTextAccumulator = accumulator
            return
        }

        sendKey(surface: surface, action: GHOSTTY_ACTION_PRESS, event: NSApp.currentEvent, text: text)
    }

    override func keyUp(with event: NSEvent) {
        guard event.type == .keyUp else { return }
        guard let surface else { return }
        var keyInput = ghostty_input_key_s()
        keyInput.action = GHOSTTY_ACTION_RELEASE
        keyInput.keycode = UInt32(event.keyCode)
        keyInput.mods = modsFromEvent(event)
        _ = ghostty_surface_key(surface, keyInput)
    }

    override func flagsChanged(with event: NSEvent) {
        guard event.type == .flagsChanged else { return }
        guard let surface else { return }
        var keyInput = ghostty_input_key_s()
        keyInput.action = GHOSTTY_ACTION_PRESS  // Ghostty handles press/release internally for modifiers
        keyInput.keycode = UInt32(event.keyCode)
        keyInput.mods = modsFromEvent(event)
        _ = ghostty_surface_key(surface, keyInput)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }

        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, Double(bounds.height) - pos.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, Double(bounds.height) - pos.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, Double(bounds.height) - pos.y, modsFromEvent(event))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, Double(bounds.height) - pos.y, modsFromEvent(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else {
            super.scrollWheel(with: event)
            return
        }
        var scrollMods: ghostty_input_scroll_mods_t = 0
        if event.hasPreciseScrollingDeltas {
            scrollMods |= 1  // precision bit
        }
        // Send mouse position before scroll so Ghostty knows where the cursor is
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, Double(bounds.height) - pos.y, modsFromEvent(event))
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, scrollMods)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    // MARK: - Tracking area for mouseMoved

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    // MARK: - Helpers

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        let flags = event.modifierFlags
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    private func sendKey(
        surface: ghostty_surface_t,
        action: ghostty_input_action_e,
        event: NSEvent?,
        text: String?
    ) {
        var keyInput = ghostty_input_key_s()
        keyInput.action = action
        keyInput.composing = hasMarkedText()

        if let event, event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged {
            keyInput.keycode = UInt32(event.keyCode)
            keyInput.mods = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))

            // consumed_mods: Shift and Option are "consumed" by text generation
            // (they change the character produced). Ctrl and Cmd are not consumed.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var consumed: UInt32 = 0
            if flags.contains(.shift) { consumed |= GHOSTTY_MODS_SHIFT.rawValue }
            if flags.contains(.option) { consumed |= GHOSTTY_MODS_ALT.rawValue }
            keyInput.consumed_mods = ghostty_input_mods_e(rawValue: consumed)

            // unshifted_codepoint: Unicode scalar with no modifiers applied
            if #available(macOS 13.0, *),
               let unshifted = event.characters(byApplyingModifiers: [])?.first {
                keyInput.unshifted_codepoint = unshifted.unicodeScalars.first.map { UInt32($0.value) } ?? 0
            }
        } else {
            keyInput.keycode = 0
            keyInput.mods = GHOSTTY_MODS_NONE
        }

        // Do NOT hold ghosttyLock here: ghostty_surface_key can trigger
        // synchronous callbacks (readClipboard, wakeup, etc.) that may need
        // the main thread or re-enter Ghostty, causing a deadlock.
        // Ghostty's C API is internally thread-safe for key input.
        if let text, !text.isEmpty {
            text.withCString { cStr in
                keyInput.text = cStr
                _ = ghostty_surface_key(surface, keyInput)
            }
        } else {
            _ = ghostty_surface_key(surface, keyInput)
        }
    }

    static func shouldSendRawKey(
        markedTextBefore: Bool,
        hasMarkedTextNow: Bool,
        hasAccumulatedText: Bool
    ) -> Bool {
        if hasAccumulatedText { return false }
        if markedTextBefore || hasMarkedTextNow { return false }
        return true
    }

    static func isPasteShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.charactersIgnoringModifiers?.lowercased() == "v"
        else {
            return false
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command) else { return false }

        let disallowed: NSEvent.ModifierFlags = [.control, .option, .shift, .function]
        if !mods.isDisjoint(with: disallowed) {
            return false
        }

        return true
    }

    static func shouldHandleControlKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return mods.contains(.control) && !mods.contains(.command)
    }

    // MARK: - NSTextInputClient

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attributed as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: attributed)
        case let plain as String:
            markedText = NSMutableAttributedString(string: plain)
        default:
            markedText = NSMutableAttributedString()
        }

        if keyTextAccumulator == nil {
            syncPreedit(clearIfNeeded: true)
        }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText = NSMutableAttributedString()
            syncPreedit(clearIfNeeded: true)
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let viewRect = NSRect(
            x: x,
            y: frame.size.height - y,
            width: width,
            height: max(height, 1)
        )
        let winRect = convert(viewRect, to: nil)
        guard let window else { return winRect }
        return window.convertToScreen(winRect)
    }

    private func syncPreedit(clearIfNeeded: Bool) {
        guard let surface else { return }

        if markedText.length > 0 {
            let string = markedText.string
            let utf8 = string.utf8CString
            guard !utf8.isEmpty else { return }
            string.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(utf8.count - 1))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}

import AppKit
import QuartzCore

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
    /// Context-menu hooks, wired by `SplitContainerView` to the split delegate.
    var onRequestSplit: ((SplitAxis) -> Void)?
    var onRequestClose: (() -> Void)?
    /// Wired by `SplitContainerView` to open a file in the app's file viewer.
    var onRequestPreview: ((URL) -> Void)?
    /// Wired by `SplitContainerView` to open a GitHub PR review for a detected URL.
    /// Tuple: (owner, repo, prNumber).
    var onRequestPRPreview: ((String, String, Int) -> Void)?

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

    /// Record that the PTY was already sized to `size` (e.g. Station.create's
    /// initial `ghostty_surface_set_size`) so the next `setFrame` of the same
    /// size does not emit a redundant SIGWINCH.
    func markSurfaceSizeSynced(_ size: NSSize) {
        lastSyncedSize = size
    }

    /// Adopt current AppKit bounds without `ghostty_surface_set_size`.
    /// Structural splits use this on the *existing* pane so fancy prompts
    /// (starship / oh-my-zsh powerline) do not reprint on SIGWINCH. The PTY
    /// grid is corrected on the next keypress via `flushPendingPtyGridSyncIfNeeded()`.
    ///
    /// Hard-freezes `set_size` until that flush (or an explicit `syncSize`):
    /// relying only on `lastSyncedSize` is not enough — `endLiveResize`, a
    /// coalesced sync, or a follow-up layout pass can still reach
    /// `applySurfaceSize` and SIGWINCH the shell.
    func absorbBoundsWithoutPtyResize() {
        surfaceSyncGeneration += 1
        surfaceSizeDeferred = false
        surfaceSyncScheduled = false
        lastSyncedSize = bounds.size
        pendingPtyGridSync = true
        freezePtyGridResize = true
        if let surface {
            ghostty_surface_refresh(surface)
        }
        needsDisplay = true
    }

    /// Apply a deferred PTY `set_size` from `absorbBoundsWithoutPtyResize()`.
    @discardableResult
    func flushPendingPtyGridSyncIfNeeded() -> Bool {
        guard pendingPtyGridSync || freezePtyGridResize else { return false }
        pendingPtyGridSync = false
        freezePtyGridResize = false
        lastSyncedSize = .zero
        syncSurfaceSize()
        return true
    }

    /// Allow PTY grid sync again (window resize / explicit `Station.syncSize`).
    func clearPtyGridResizeFreeze() {
        freezePtyGridResize = false
        pendingPtyGridSync = false
    }

    // MARK: - OSC 9;4 progress

    /// Thin progress bar pinned to the pane's top edge, created on first report so
    /// panes that never emit OSC 9;4 (most of them) carry no extra layer.
    private var progressBar: PaneProgressBar?

    /// Show/update the pane's progress bar. Main thread only.
    func updateProgress(_ progress: OSCProgress?) {
        if progressBar == nil {
            guard let progress, progress.isActive else { return }   // nothing to show yet
            let bar = PaneProgressBar(frame: progressBarFrame())
            bar.autoresizingMask = [.width, .minYMargin]
            addSubview(bar)
            progressBar = bar
        }
        progressBar?.frame = progressBarFrame()
        progressBar?.update(progress)
    }

    private func progressBarFrame() -> NSRect {
        NSRect(x: 0, y: bounds.height - PaneProgressBar.barHeight,
               width: bounds.width, height: PaneProgressBar.barHeight)
    }

    /// Test accessor for lastSyncedSize
    var lastSyncedSizeForTesting: NSSize { lastSyncedSize }
    /// Test accessor: the progress bar, if one has been created.
    var progressBarForTesting: NSView? { progressBar }
    var freezePtyGridResizeForTesting: Bool { freezePtyGridResize }
    var pendingPtyGridSyncForTesting: Bool { pendingPtyGridSync }

    /// Test helper: set lastSyncedSize to simulate a previous sync
    func resetLastSyncedSizeForTesting(to size: NSSize) {
        lastSyncedSize = size
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Shadow is computed from an explicit path so Core Animation never has to
        // derive it from the live Metal contents (which forces offscreen passes).
        layer?.shadowPath = CGPath(rect: bounds, transform: nil)
        syncWashLayerFrame()
        syncSurfaceSize()
    }

    // MARK: - Inactive wash

    /// Scrim over this pane while another pane holds the split's focus. It lives
    /// *inside* the view as a sublayer rather than as a sibling overlay: sibling
    /// views get buried whenever a surface is re-added on top (tab switch,
    /// reparent), which made the cue appear in some worktrees and not others.
    private var washLayer: CALayer?

    /// Whether the pane currently wears the inactive scrim.
    private(set) var showsInactiveWash = false

    func setInactiveWash(_ on: Bool, animated: Bool = true) {
        guard let layer else { return }
        showsInactiveWash = on
        if on, washLayer == nil {
            let wash = CALayer()
            wash.frame = bounds
            // Above the Metal contents drawn into this view's own layer.
            wash.zPosition = 100
            wash.opacity = 0
            layer.addSublayer(wash)
            washLayer = wash
        }
        guard let wash = washLayer else { return }
        wash.backgroundColor = Self.washColor(for: effectiveAppearance)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.12)
        wash.opacity = on ? 1 : 0
        CATransaction.commit()
    }

    private func syncWashLayerFrame() {
        guard let wash = washLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        washLayer?.backgroundColor = Self.washColor(for: effectiveAppearance)
    }

    /// Dark themes are already near-black, so a black wash lands on black and two
    /// agent panes read as identical — lift the inactive one instead. Light themes
    /// take the opposite treatment (a light wash there would be invisible).
    private static func washColor(for appearance: NSAppearance) -> CGColor {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = dark
            ? NSColor.white.withAlphaComponent(0.085)
            : NSColor.black.withAlphaComponent(0.055)
        return (color.usingColorSpace(.sRGB) ?? color).cgColor
    }

    override func removeFromSuperview() {
        super.removeFromSuperview()
        // Reparenting (dashboard focus panel, another tab) starts from a clean
        // pane; whoever embeds it next re-applies the wash if it belongs there.
        setInactiveWash(false, animated: false)
        // Reset debounce for the next embed — but keep a structural-split freeze
        // so a reparent mid-absorb cannot immediately SIGWINCH.
        if !freezePtyGridResize {
            lastSyncedSize = .zero
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let surface, let window else { return }
        let scale = Double(window.backingScaleFactor)
        ghostty_surface_set_content_scale(surface, scale, scale)
        syncSurfaceSize()
    }

    /// Dragging the window to a display with a different `backingScaleFactor`
    /// (e.g. built-in Retina 2x ↔ external 1x) fires this. The view's *point*
    /// bound are unchanged, so `syncSurfaceSize()`'s `size == lastSyncedSize`
    /// guard would skip the resync and the Metal framebuffer would keep
    /// rendering at the old scale — the reported "font jumps big/small across
    /// monitors" bug. Push the new content scale and force a resync past the
    /// debounce (the pixel size *does* change with scale, so `set_size` fires
    /// and the framebuffer re-renders at the correct DPI).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()

        // Update the layer's contentsScale so Core Animation doesn't scale
        // the Metal framebuffer during compositing. Must match the window's
        // actual backing scale, not a cached value.
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }

        guard let surface, let window, bounds.width > 0, bounds.height > 0 else { return }
        // Use convertToBacking for the actual X/Y scale — window.backingScaleFactor
        // is a single scalar and can be wrong for non-integer scales or when the
        // view has a transform. This mirrors upstream Ghostty's approach.
        let fbFrame = convertToBacking(bounds)
        let xScale = fbFrame.size.width / bounds.width
        let yScale = fbFrame.size.height / bounds.height
        ghostty_surface_set_content_scale(surface, xScale, yScale)
        // The pixel size changes with scale, so force a resync.
        ghostty_surface_set_size(surface, UInt32(fbFrame.size.width), UInt32(fbFrame.size.height))
        ghostty_surface_refresh(surface)
        // Mark the point size as synced so the debounced syncSurfaceSize doesn't
        // re-fire with stale scale info.
        lastSyncedSize = bounds.size
        needsDisplay = true
    }

    private var lastSurfaceSyncTime: CFTimeInterval = 0
    private var surfaceSyncScheduled = false
    private var surfaceSizeDeferred = false
    /// After a structural split we adopt the new AppKit frame without
    /// `set_size` (avoids SIGWINCH → prompt redraw). Flush the real PTY grid
    /// on the next keypress into this pane.
    private var pendingPtyGridSync = false
    /// While true, `applySurfaceSize` never calls `ghostty_surface_set_size`.
    private var freezePtyGridResize = false
    /// Bumped to cancel in-flight coalesced `syncSurfaceSize` callbacks.
    private var surfaceSyncGeneration: UInt64 = 0
    /// Divider drags and animated layouts call setFrameSize once per mouse/frame
    /// event; resizing the Ghostty grid at that rate is the dominant drag cost.
    /// Coalesce to ~30Hz — the deferred pass re-reads bounds, so the final size
    /// always lands.
    private static let surfaceSyncMinInterval: CFTimeInterval = 1.0 / 30.0

    func syncSurfaceSize() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        guard size != lastSyncedSize else { return }

        // Split absorb: track AppKit size only — never schedule a coalesced
        // set_size, and never call through to the real PTY resize path.
        if freezePtyGridResize {
            lastSyncedSize = size
            if let surface {
                ghostty_surface_refresh(surface)
            }
            needsDisplay = true
            return
        }

        // During chrome/window live-resize, grow/shrink the view but hold the
        // PTY grid until the gesture ends (one SIGWINCH). Rapid set_size floods
        // starship/zsh and leaves blank prompt gaps in the scrollback.
        if GhosttyBridge.shared.isLiveResizing {
            surfaceSizeDeferred = true
            needsDisplay = true
            return
        }

        let now = CACurrentMediaTime()
        let elapsed = now - lastSurfaceSyncTime
        // First sync after a reset/reparent (lastSyncedSize == .zero) must land
        // immediately — only continuous resize streams get coalesced.
        if lastSyncedSize != .zero, elapsed < Self.surfaceSyncMinInterval {
            if !surfaceSyncScheduled {
                surfaceSyncScheduled = true
                let delay = Self.surfaceSyncMinInterval - elapsed
                let generation = surfaceSyncGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    guard self.surfaceSyncGeneration == generation else { return }
                    self.surfaceSyncScheduled = false
                    self.syncSurfaceSize()
                }
            }
            return
        }
        applySurfaceSize(size)
    }

    /// Flush a size sync deferred during `GhosttyBridge.beginLiveResize()`.
    /// - Parameter pinHeight: Chrome sidebar drag (horizontal). We deliberately
    ///   do **not** call `ghostty_surface_set_size` — any PTY resize sends
    ///   SIGWINCH and starship/zsh reprint a blank line above the prompt.
    ///   The view frame already follows Auto Layout; the grid catches up on the
    ///   next real window resize instead.
    func flushDeferredSurfaceSize(pinHeight: Bool = false) {
        guard surfaceSizeDeferred || bounds.size != lastSyncedSize else { return }
        surfaceSizeDeferred = false
        surfaceSyncScheduled = false

        // Structural-split absorb and chrome sidebar drag: never SIGWINCH here.
        if pinHeight || freezePtyGridResize {
            lastSyncedSize = bounds.size
            if let surface {
                ghostty_surface_refresh(surface)
            }
            needsDisplay = true
            return
        }

        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        applySurfaceSize(size)
    }

    private func applySurfaceSize(_ size: NSSize) {
        lastSurfaceSyncTime = CACurrentMediaTime()
        surfaceSizeDeferred = false

        // Split absorb: AppKit frame may change, but the PTY grid stays put
        // until an explicit flush (keypress) or `clearPtyGridResizeFreeze`.
        if freezePtyGridResize {
            lastSyncedSize = size
            if let surface {
                ghostty_surface_refresh(surface)
            }
            needsDisplay = true
            return
        }

        pendingPtyGridSync = false

        guard let surface else {
            lastSyncedSize = size
            return
        }

        // Update content scale in case we moved to a different window/screen.
        // Use convertToBacking for the actual X/Y scale factor — more accurate
        // than window.backingScaleFactor for non-integer or asymmetric scales.
        let pixelW: UInt32
        let pixelH: UInt32
        if bounds.width > 0, bounds.height > 0 {
            let fbFrame = convertToBacking(bounds)
            let xScale = fbFrame.size.width / bounds.width
            let yScale = fbFrame.size.height / bounds.height
            ghostty_surface_set_content_scale(surface, xScale, yScale)
            pixelW = UInt32(fbFrame.size.width.rounded(.towardZero))
            pixelH = UInt32(fbFrame.size.height.rounded(.towardZero))
        } else {
            let scale = CGFloat(window?.backingScaleFactor ?? 2.0)
            pixelW = UInt32((size.width * scale).rounded(.towardZero))
            pixelH = UInt32((size.height * scale).rounded(.towardZero))
        }
        guard pixelW > 0, pixelH > 0 else { return }

        let current = ghostty_surface_size(surface)
        if current.width_px == pixelW, current.height_px == pixelH {
            lastSyncedSize = size
            return
        }

        // Sidebar drag: never SIGWINCH. View size may diverge from the PTY grid
        // until the next window resize clears this suppression.
        if GhosttyBridge.shared.suppressSurfaceGridResize {
            lastSyncedSize = size
            ghostty_surface_refresh(surface)
            needsDisplay = true
            return
        }

        // Ghostty's TIOCSWINSZ path fires SIGWINCH even when only pixel size
        // changes. Skip when the character grid is unchanged so starship/zsh
        // don't reprint a blank prompt line on every sub-cell drag.
        if current.cell_width_px > 0, current.cell_height_px > 0,
           current.columns > 0, current.rows > 0 {
            let colSpan = UInt32(current.columns) * current.cell_width_px
            let rowSpan = UInt32(current.rows) * current.cell_height_px
            let padX = current.width_px > colSpan ? current.width_px - colSpan : 0
            let padY = current.height_px > rowSpan ? current.height_px - rowSpan : 0
            let usableW = pixelW > padX ? pixelW - padX : pixelW
            let usableH = pixelH > padY ? pixelH - padY : pixelH
            let newCols = usableW / current.cell_width_px
            let newRows = usableH / current.cell_height_px
            if newCols == UInt32(current.columns), newRows == UInt32(current.rows) {
                lastSyncedSize = size
                needsDisplay = true
                return
            }
        }

        lastSyncedSize = size
        ghostty_surface_set_size(surface, pixelW, pixelH)
        ghostty_surface_refresh(surface)
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        applyFocusVisualState(true)
        if let surface {
            ghostty_surface_set_focus(surface, true)
        }
        // Do not flush a split-absorbed grid on focus alone — clicking back into
        // the old pane would still SIGWINCH and trash powerline prompts. Sync on
        // the first keypress instead (see keyDown).
        onFocusAcquired?()
        // Click→title fast path: announce from the view itself so every host
        // (repo tab, dashboard focus panel) hears it — `onFocusAcquired` is only
        // wired by SplitContainerView, and the ShipLog path trails the 2s poll.
        if let station {
            NotificationCenter.default.post(name: .paneDidAcquireFocus, object: station)
        }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        applyFocusVisualState(false)
        if let surface {
            ghostty_surface_set_focus(surface, false)
        }
        return super.resignFirstResponder()
    }

    private func applyFocusVisualState(_ focused: Bool) {
        guard let layer else { return }
        layer.masksToBounds = false
        layer.shadowPath = CGPath(rect: bounds, transform: nil)
        layer.shadowOffset = .zero
        layer.shadowRadius = 5
        layer.shadowColor = NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
        layer.shadowOpacity = focused ? 0.22 : 0
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard event.type == .keyDown else { return }
        guard let surface else { return }
        flushPendingPtyGridSyncIfNeeded()

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

    /// Text of the most recent terminal selection, captured on `mouseUp`. The
    /// live selection is often cleared by the time our `rightMouseDown` runs (the
    /// right-button event delivery clears it before we can read it), so we snapshot
    /// it here while it's still intact and use the snapshot to build the menu.
    private var cachedSelectionText: String?

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        // A fresh left-click starts a new selection (or clears the old one);
        // drop the snapshot until the matching mouseUp captures the result.
        cachedSelectionText = nil

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
        // Copy-on-select has usually cleared the live selection by now, so only
        // overwrite the drag-time snapshot if something is still readable (e.g.
        // copy-on-select disabled). Never clobber a good snapshot with nil.
        if let text = readSelectionText() { cachedSelectionText = text }
    }

    /// Read the current terminal selection as a string, or nil if there's none.
    private func readSelectionText() -> String? {
        guard let surface, ghostty_surface_has_selection(surface) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let cString = text.text else { return nil }
        let s = String(cString: cString)
        return s.isEmpty ? nil : s
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, Double(bounds.height) - pos.y, modsFromEvent(event))
        // Snapshot the selection *during* the drag. Ghostty's copy-on-select
        // clears the live selection the moment the button is released, so by
        // mouseUp (and certainly by right-click) it's already gone — but here,
        // mid-drag, it's still intact and readable.
        if let text = readSelectionText() { cachedSelectionText = text }
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

    /// File URL captured from the selection at right-click time, consumed when
    /// building the context menu. Read *before* `makeFirstResponder`, which can
    /// clear the terminal selection out from under us.
    private var pendingPreviewURL: URL?
    /// GitHub PR URL captured from the same row, checked after `pendingPreviewURL`
    /// (a PR link is not a file so `filePathAtClick` won't return it).
    private var pendingPRPreview: (owner: String, repo: String, number: Int)?

    override func rightMouseDown(with event: NSEvent) {
        // Resolve a previewable file for the menu. Prefer the path token under the
        // click point (works even in mouse-reporting TUIs like Claude Code, where
        // dragging never creates a ghostty selection); fall back to an explicit
        // text selection.
        let fileURL = filePathAtClick(event)
        self.pendingPreviewURL = fileURL ?? selectedFilePath()
        // If the click didn't hit a file path, check for a GitHub PR URL on the row.
        if fileURL == nil {
            self.pendingPRPreview = prURLAtClick(event)
        } else {
            self.pendingPRPreview = nil
        }
        // Focus the right-clicked pane so menu actions target it, then show
        // our pane context menu (split/close/copy/paste).
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        NSMenu.popUpContextMenu(makePaneContextMenu(), with: event, for: self)
    }

    override func rightMouseUp(with event: NSEvent) {
        // Consumed by the context menu in rightMouseDown; nothing to forward.
    }

    // MARK: - Pane context menu

    private func makePaneContextMenu() -> NSMenu {
        let menu = NSMenu()

        let splitH = NSMenuItem(title: "Split Horizontally", action: #selector(contextSplitHorizontal), keyEquivalent: "")
        splitH.target = self
        menu.addItem(splitH)

        let splitV = NSMenuItem(title: "Split Vertically", action: #selector(contextSplitVertical), keyEquivalent: "")
        splitV.target = self
        menu.addItem(splitV)

        menu.addItem(.separator())

        if let path = pendingPreviewURL {
            let previewItem = NSMenuItem(title: "Preview", action: #selector(contextPreview), keyEquivalent: "")
            previewItem.target = self
            previewItem.representedObject = path
            menu.addItem(previewItem)
            menu.addItem(.separator())
        } else if let pr = pendingPRPreview {
            let prItem = NSMenuItem(
                title: "Preview PR #\(pr.number) (\(pr.owner)/\(pr.repo))",
                action: #selector(contextPRPreview),
                keyEquivalent: ""
            )
            prItem.target = self
            menu.addItem(prItem)
            menu.addItem(.separator())
        }

        let copyItem = NSMenuItem(title: "Copy", action: #selector(contextCopy), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = surface.map { ghostty_surface_has_selection($0) } ?? false
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(contextPaste), keyEquivalent: "")
        pasteItem.target = self
        pasteItem.isEnabled = NSPasteboard.general.string(forType: .string)?.isEmpty == false
        menu.addItem(pasteItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: "Close Pane", action: #selector(contextClose), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)

        return menu
    }

    /// Which logical line of a multi-row read to search. Ghostty joins soft-wrapped
    /// rows when reading a selection (`Screen.selectionString` hardcodes
    /// `unwrap = true`) and emits `\n` only at hard line breaks, so a multi-row read
    /// split on `\n` hands back whole logical lines.
    enum LogicalLinePick {
        /// The read covers one row; use all of it.
        case only
        /// The read starts at the clicked row; the logical line beginning there is first.
        case first
        /// The read ends at the clicked row; the logical line reaching it is last.
        case last
    }

    /// One read to try when hunting for the token under a click.
    struct WrapSearchStep: Equatable {
        let range: ClosedRange<Int>
        let pick: LogicalLinePick
    }

    /// How many rows above/below the click to search for the rest of a wrapped token.
    static let wrapSearchRows = 3

    /// Row ranges to read for a click on `row`, in priority order.
    ///
    /// The clicked row alone comes first: it is the cheapest read and cannot pull in a
    /// token from a neighbouring line. A token longer than the remaining width soft-wraps
    /// though, and a single-row read truncates it — `…/2026_sessions_source_read_pa` for a
    /// path whose `th.sql` tail sits on the next row — which then fails to resolve. So fall
    /// back to reading downward (the token started on the clicked row) and then upward (the
    /// click landed on a continuation row), taking only the logical line that touches the
    /// clicked row so neighbouring lines can never be mistaken for the clicked one.
    static func wrapSearchPlan(row: Int, rowCount: Int, span: Int = wrapSearchRows) -> [WrapSearchStep] {
        guard rowCount > 0, row >= 0, row < rowCount else { return [] }
        var plan = [WrapSearchStep(range: row...row, pick: .only)]
        let lastRow = rowCount - 1
        if row < lastRow {
            plan.append(WrapSearchStep(range: row...min(row + span, lastRow), pick: .first))
        }
        if row > 0 {
            plan.append(WrapSearchStep(range: max(0, row - span)...row, pick: .last))
        }
        return plan
    }

    /// Pull the logical line named by `pick` out of a multi-row read.
    static func logicalLine(from text: String, pick: LogicalLinePick) -> String {
        switch pick {
        case .only:
            return text
        case .first:
            return String(text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
        case .last:
            return String(text.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
        }
    }

    /// The viewport row the event landed on, or nil if it fell outside the grid.
    private func viewportRow(for event: NSEvent) -> Int? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.cell_height_px > 0, size.rows > 0, bounds.height > 0 else { return nil }

        // Click point: AppKit points, origin bottom-left. Convert to a viewport
        // row using the pixel cell height (scale = pixels per point).
        let pos = convert(event.locationInWindow, from: nil)
        let scale = Double(size.height_px) / Double(bounds.height)
        let yPx = (Double(bounds.height) - pos.y) * scale
        let row = Int(yPx / Double(size.cell_height_px))
        guard row >= 0, row < Int(size.rows) else { return nil }
        return row
    }

    /// Read a span of viewport rows as text, full width.
    private func readViewportRows(_ rows: ClosedRange<Int>) -> String? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                      x: 0, y: UInt32(rows.lowerBound)),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                          x: UInt32(max(0, Int(size.columns) - 1)), y: UInt32(rows.upperBound)),
            rectangle: false
        )
        guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let cString = text.text else { return nil }
        return String(cString: cString)
    }

    /// Run `match` over the whitespace-delimited tokens of every logical line that
    /// touches the clicked row, stopping at the first hit.
    ///
    /// Working in tokens means we never need an exact column-to-character mapping,
    /// which CJK width breaks. Multiple matching tokens on one line are rare enough
    /// that first-hit-wins is reliable.
    private func firstTokenAtClick<T>(_ event: NSEvent, match: (String) -> T?) -> T? {
        guard let surface, let row = viewportRow(for: event) else { return nil }
        let rowCount = Int(ghostty_surface_size(surface).rows)

        for step in Self.wrapSearchPlan(row: row, rowCount: rowCount) {
            guard let text = readViewportRows(step.range) else { continue }
            let line = Self.logicalLine(from: text, pick: step.pick)
            for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                if let hit = match(String(token)) { return hit }
            }
        }
        return nil
    }

    /// Resolve a previewable file from the terminal cell under the right-click.
    /// Works regardless of text selection — important in mouse-reporting TUIs where
    /// a drag is consumed by the app and never becomes a ghostty selection.
    private func filePathAtClick(_ event: NSEvent) -> URL? {
        let bases = pathResolutionBases()
        return firstTokenAtClick(event) { Self.resolveSelectedPath(raw: $0, bases: bases) }
    }

    /// Checks the tokens around the click for a GitHub PR URL
    /// (`https://github.com/{owner}/{repo}/pull/{number}`).
    private func prURLAtClick(_ event: NSEvent) -> (owner: String, repo: String, number: Int)? {
        firstTokenAtClick(event) { Self.parsePRURL($0) }
    }

    /// Directories a relative path is resolved against, most specific first.
    private func pathResolutionBases() -> [String?] {
        let worktreePath = station.map { ShipLog.shared.sailor(for: $0.id)?.worktreePath } ?? nil
        return [station?.pwd, worktreePath, station?.initialWorkingDirectory]
    }

    /// Parse a GitHub PR URL from a token, e.g.
    /// `https://github.com/owner/repo/pull/123` or `github.com/owner/repo/pull/123`.
    static func parsePRURL(_ token: String) -> (owner: String, repo: String, number: Int)? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip common URL wrappers: markdown link syntax, trailing paren/bracket.
        let cleaned = trimmed
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .punctuationCharacters)

        // Match: https://github.com/owner/repo/pull/123
        // Or:      github.com/owner/repo/pull/123
        // Or:   www.github.com/owner/repo/pull/123
        let pattern = #"^(?:https?://)?(?:www\.)?github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/pull/(\d+)/?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              match.numberOfRanges == 4 else { return nil }

        guard let ownerRange = Range(match.range(at: 1), in: cleaned),
              let repoRange = Range(match.range(at: 2), in: cleaned),
              let numRange = Range(match.range(at: 3), in: cleaned),
              let number = Int(cleaned[numRange]), number > 0 else { return nil }

        return (owner: String(cleaned[ownerRange]),
                repo: String(cleaned[repoRange]),
                number: number)
    }

    /// If the current selection is a path pointing at an existing file (relative
    /// paths resolved against the pane's working directory), return that file's
    /// URL. Returns nil for no selection, directories, or non-existent paths so
    /// the Preview menu item is only offered when it will actually work.
    private func selectedFilePath() -> URL? {
        // Prefer the snapshot taken on mouseUp; fall back to the live selection
        // in case one exists that we didn't capture (e.g. keyboard selection).
        guard let raw = cachedSelectionText ?? readSelectionText() else { return nil }
        return Self.resolveSelectedPath(raw: raw, bases: pathResolutionBases())
    }

    /// Pure resolver (unit-testable): trims `raw`, rejects multi-token/multi-line
    /// selections, then returns the first existing *file* found by treating `raw`
    /// as an absolute/`~` path or resolving it against each base in `bases`
    /// (first non-empty base that yields an existing file wins).
    static func resolveSelectedPath(raw: String, bases: [String?]) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A path shouldn't span lines or contain interior whitespace; reject
        // multi-token selections rather than guessing.
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0 == "\n" || $0 == " " || $0 == "\t" }) else { return nil }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let candidates: [String]
        if expanded.hasPrefix("/") {
            candidates = [expanded]
        } else {
            candidates = bases
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .map { ($0 as NSString).appendingPathComponent(expanded) }
        }

        let fm = FileManager.default
        for candidate in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    @objc private func contextPreview(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onRequestPreview?(url)
    }

    @objc private func contextPRPreview(_ sender: NSMenuItem) {
        guard let pr = pendingPRPreview else { return }
        onRequestPRPreview?(pr.owner, pr.repo, pr.number)
    }

    @objc private func contextSplitHorizontal() { onRequestSplit?(.horizontal) }
    @objc private func contextSplitVertical() { onRequestSplit?(.vertical) }
    @objc private func contextClose() { onRequestClose?() }
    @objc private func contextPaste() { paste(nil) }

    @objc private func contextCopy() {
        guard let surface, ghostty_surface_has_selection(surface) else { return }
        "copy_to_clipboard".withCString { ptr in
            _ = ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
        }
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

import AppKit

protocol TerminalSurfaceDelegate: AnyObject {
    /// Called when a stale session was detected and the surface was recreated.
    /// The delegate should re-embed `surface.view` into the appropriate container.
    func terminalSurfaceDidRecover(_ surface: TerminalSurface)
}

/// Manages a single Ghostty terminal surface (NSView + PTY + Metal renderer).
/// Each worktree gets one TerminalSurface instance.
class TerminalSurface {
    /// Unique identifier for this terminal instance (used as primary key in AgentHead)
    let id: String = UUID().uuidString

    /// The NSView that Ghostty renders into (layer-backed, Metal)
    private(set) var view: GhosttyNSView!
    private(set) var surface: ghostty_surface_t?
    private weak var containerView: NSView?

    /// Session name for persistence backend (nil = direct shell)
    var sessionName: String?
    /// Persistence backend for the sessionName above.
    var backend: String = "zmx"
    /// Delegate notified when a stale session is recovered.
    weak var delegate: TerminalSurfaceDelegate?

    private var recoveryTimer: DispatchWorkItem?
    private static let recoveryDelay: TimeInterval = 3.0

    /// Serializes Ghostty C API access across threads.
    /// Background polling (readViewportText) and main-thread input (key/mouse)
    /// must not call into the same ghostty_surface_t concurrently.
    let ghosttyLock = NSLock()

    /// Create the terminal surface and add it to the given container view.
    /// If sessionName is provided, the surface runs inside a persistent backend session.
    func create(in container: NSView, workingDirectory: String? = nil, sessionName: String? = nil, completion: (() -> Void)? = nil) -> Bool {
        guard let app = GhosttyBridge.shared.app else {
            NSLog("GhosttyBridge not initialized")
            return false
        }

        if let sessionName {
            if backend == "tmux" {
                // Check tmux session existence on background thread to avoid blocking UI
                Self.tmuxSessionExistsAsync(sessionName) { [weak self] exists in
                    guard let self else { return }
                    let tmuxCommand: String
                    if exists {
                        tmuxCommand = "tmux attach-session -t \(sessionName) \\; set-option status off"
                    } else {
                        tmuxCommand = "tmux new-session -s \(sessionName) \\; set-option status off"
                    }
                    self._createWithCommand(app: app, container: container, workingDirectory: workingDirectory, command: tmuxCommand)
                    completion?()
                }
                return true  // Surface creation is deferred
            }

            if backend == "zmx" {
                let zmxCommand = "zmx attach \(sessionName)"
                _createWithCommand(app: app, container: container, workingDirectory: workingDirectory, command: zmxCommand)
                if surface != nil {
                    scheduleZmxHealthCheck(sessionName: sessionName, container: container, workingDirectory: workingDirectory)
                }
                return surface != nil
            }
        }

        _createWithCommand(app: app, container: container, workingDirectory: workingDirectory, command: nil)
        return surface != nil
    }

    @discardableResult
    func createEphemeral(in container: NSView, workingDirectory: String? = nil, command: String) -> Bool {
        guard let app = GhosttyBridge.shared.app else {
            NSLog("GhosttyBridge not initialized")
            return false
        }

        _createWithCommand(app: app, container: container, workingDirectory: workingDirectory, command: command)
        return surface != nil
    }

    private func _createWithCommand(app: ghostty_app_t, container: NSView, workingDirectory: String?, command: String?) {
        let termView = GhosttyNSView(frame: container.bounds)
        termView.wantsLayer = true

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(termView).toOpaque()
        config.scale_factor = Double(container.window?.backingScaleFactor ?? 2.0)

        // Use a flat closure that receives C pointers directly.
        // Pointers are only valid within the withCString scope,
        // so _createSurface must be called inside the innermost closure.
        let create = { [self] (wdPtr: UnsafePointer<CChar>?, cmdPtr: UnsafePointer<CChar>?) in
            if let wdPtr { config.working_directory = wdPtr }
            if let cmdPtr { config.command = cmdPtr }
            self._createSurface(app: app, config: &config, view: termView, container: container)
        }

        switch (workingDirectory, command) {
        case let (wd?, cmd?):
            wd.withCString { wdPtr in cmd.withCString { cmdPtr in create(wdPtr, cmdPtr) } }
        case let (wd?, nil):
            wd.withCString { wdPtr in create(wdPtr, nil) }
        case let (nil, cmd?):
            cmd.withCString { cmdPtr in create(nil, cmdPtr) }
        case (nil, nil):
            create(nil, nil)
        }
    }

    private func _createSurface(app: ghostty_app_t, config: inout ghostty_surface_config_s, view: GhosttyNSView, container: NSView) {
        guard let s = ghostty_surface_new(app, &config) else {
            NSLog("Failed to create Ghostty surface")
            return
        }
        self.surface = s
        self.view = view
        self.containerView = container
        view.surface = s
        view.terminalSurface = self

        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Set initial size — Ghostty expects pixel (framebuffer) dimensions, not points
        let size = container.bounds.size
        let scale = container.window?.backingScaleFactor ?? 2.0
        ghostty_surface_set_content_scale(s, Double(scale), Double(scale))
        ghostty_surface_set_size(s, UInt32(size.width * scale), UInt32(size.height * scale))
        ghostty_surface_set_focus(s, false)  // Start unfocused; focus set via makeFirstResponder
    }

    /// Check if a tmux session with given name exists (async, avoids blocking main thread)
    private static func tmuxSessionExistsAsync(_ name: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["tmux", "has-session", "-t", name]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            let exists: Bool
            do {
                try process.run()
                process.waitUntilExit()
                exists = process.terminationStatus == 0
            } catch {
                exists = false
            }
            DispatchQueue.main.async {
                completion(exists)
            }
        }
    }

    /// Reparent this terminal's view to a different container
    func reparent(to container: NSView) {
        guard let view, let surface else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        CATransaction.commit()

        self.containerView = container

        // Force size sync after constraints resolve — need TWO deferred
        // passes because the first run loop resolves constraints (setting frame)
        // and the second one is needed for Ghostty to recalculate the grid
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.view, let surface = self.surface else { return }
            self.syncContentScale()
            self.syncSize()
            // Restore AppKit first responder so keyboard events reach the terminal.
            // Only grab focus if no other terminal already has it (e.g. in a split pane
            // where showTerminal() already focused the correct leaf).
            if !(view.window?.firstResponder is GhosttyNSView) {
                view.window?.makeFirstResponder(view)
            }
            view.needsDisplay = true
            // Third pass: read the grid size AFTER Ghostty has processed the resize
            DispatchQueue.main.async { [weak self] in
                self?.refreshSessionLayout()
            }
        }
    }

    /// Tell tmux to resize its window to match the terminal's actual grid size.
    /// zmx handles size syncing automatically, so this is tmux-only behavior.
    func refreshSessionLayout() {
        guard backend == "tmux" else { return }
        guard let sessionName, let surface else { return }
        let gridSize = ghostty_surface_size(surface)
        guard gridSize.columns > 0, gridSize.rows > 0 else { return }
        let cols = Int(gridSize.columns)
        let rows = Int(gridSize.rows)
        DispatchQueue.global().async {
            SessionManager.resizeTmuxSession(sessionName, cols: cols, rows: rows)
        }
    }

    /// Static version for when we don't have the surface (tmux fallback).
    static func refreshTmuxClient(_ sessionName: String) {
        DispatchQueue.global().async {
            SessionManager.refreshTmuxClient(sessionName)
        }
    }

    /// Sync the surface size with the current container bounds
    func syncSize() {
        guard let view else { return }
        // Reset the debounce so syncSurfaceSize() will run even if the
        // same size was already synced through setFrameSize.
        view.resetLastSyncedSize()
        view.syncSurfaceSize()
    }

    /// Sync the content scale (Retina vs non-Retina)
    func syncContentScale() {
        guard let surface, let view, let window = view.window else { return }
        let scale = Double(window.backingScaleFactor)
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    /// Set keyboard focus
    func setFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    /// Check if the process has exited
    var processExited: Bool {
        guard let surface else { return true }
        ghosttyLock.lock()
        defer { ghosttyLock.unlock() }
        return ghostty_surface_process_exited(surface)
    }

    /// Read visible terminal text from the viewport
    /// Type text into the terminal (e.g. an initial agent command). Include a
    /// trailing "\r" to run it. Mirrors the paste path's `ghostty_surface_text`.
    func sendText(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
    }

    func readViewportText() -> String? {
        guard let surface else { return nil }

        ghosttyLock.lock()
        defer { ghosttyLock.unlock() }

        let size = ghostty_surface_size(surface)
        guard size.rows > 0, size.columns > 0 else { return nil }

        var selection = ghostty_selection_s()
        selection.top_left = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        selection.bottom_right = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: UInt32(size.columns - 1),
            y: UInt32(size.rows - 1)
        )
        selection.rectangle = false

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &text) }

        guard let ptr = text.text, text.text_len > 0 else { return nil }
        return String(cString: ptr)
    }

    /// Get the process status for status detection
    var processStatus: ProcessStatus {
        guard let surface else { return .unknown }
        ghosttyLock.lock()
        defer { ghosttyLock.unlock() }
        if ghostty_surface_process_exited(surface) {
            // We don't have the exit code from ghostty, so assume exited
            return .exited
        }
        return .running
    }

    // MARK: - Search

    /// Start a search in the terminal scrollback using Ghostty's binding action system.
    func startSearch(_ query: String) {
        guard let surface else { return }
        // Trigger Ghostty's built-in search with the query as parameter
        let action = "search:\(query)"
        action.withCString { cstr in
            _ = ghostty_surface_binding_action(surface, cstr, UInt(strlen(cstr)))
        }
    }

    /// End the current search.
    func endSearch() {
        guard let surface else { return }
        let action = "close_surface_overlay"
        action.withCString { cstr in
            _ = ghostty_surface_binding_action(surface, cstr, UInt(strlen(cstr)))
        }
    }

    /// Navigate to the next search match.
    func searchNext() {
        guard let surface else { return }
        let action = "search_forward"
        action.withCString { cstr in
            _ = ghostty_surface_binding_action(surface, cstr, UInt(strlen(cstr)))
        }
    }

    /// Navigate to the previous search match.
    func searchPrev() {
        guard let surface else { return }
        let action = "search_backward"
        action.withCString { cstr in
            _ = ghostty_surface_binding_action(surface, cstr, UInt(strlen(cstr)))
        }
    }

    // MARK: - Zmx Session Recovery

    /// Schedule a health check after zmx attach. If the surface has no content
    /// after the delay, the session is presumed stale — kill it and recreate.
    private func scheduleZmxHealthCheck(sessionName: String, container: NSView, workingDirectory: String?) {
        recoveryTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.checkZmxHealth(sessionName: sessionName, container: container, workingDirectory: workingDirectory)
        }
        recoveryTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recoveryDelay, execute: work)
    }

    private func checkZmxHealth(sessionName: String, container: NSView, workingDirectory: String?) {
        // If the surface was already destroyed or has content, nothing to do
        guard let _ = surface else { return }
        let text = readViewportText() ?? ""
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }

        NSLog("TerminalSurface: zmx session '%@' appears stale — recovering", sessionName)
        recoverZmxSession(sessionName: sessionName, container: container, workingDirectory: workingDirectory)
    }

    private func recoverZmxSession(sessionName: String, container: NSView, workingDirectory: String?) {
        // 1. Kill the stale session in the background
        DispatchQueue.global(qos: .utility).async {
            Self.forceKillZmxSession(sessionName)

            // 2. Recreate on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let app = GhosttyBridge.shared.app else { return }

                // Tear down old surface
                self.destroy()

                // Recreate with a fresh zmx attach
                let zmxCommand = "zmx attach \(sessionName)"
                self._createWithCommand(app: app, container: container, workingDirectory: workingDirectory, command: zmxCommand)
                self.delegate?.terminalSurfaceDidRecover(self)
            }
        }
    }

    /// Kill a zmx session, force-killing the daemon process and removing the
    /// socket file if the graceful `zmx kill` fails (e.g. unreachable session).
    static func forceKillZmxSession(_ sessionName: String) {
        // Try graceful kill first
        ProcessRunner.runSync(["zmx", "kill", sessionName])

        // Check if session is still alive by parsing `zmx list`
        guard let listOutput = ProcessRunner.output(["zmx", "list"]) else { return }
        let stillAlive = listOutput
            .components(separatedBy: "\n")
            .contains { $0.contains("name=\(sessionName)") }
        guard stillAlive else { return }

        NSLog("TerminalSurface: zmx session '%@' still alive after kill — force cleaning", sessionName)

        // Find and kill the daemon process via its socket
        if let socketDir = Self.zmxSocketDir() {
            let socketPath = (socketDir as NSString).appendingPathComponent(sessionName)
            // Use lsof to find the PID holding the socket
            if let lsofOutput = ProcessRunner.output(["lsof", "-t", socketPath]),
               let pid = Int32(lsofOutput.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
                NSLog("TerminalSurface: sent SIGKILL to zmx daemon pid %d", pid)
                // Brief wait for process to exit
                usleep(100_000) // 100ms
            }
            // Remove the stale socket file
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    /// Parse the zmx socket directory from `zmx version` output.
    private static func zmxSocketDir() -> String? {
        guard let versionOutput = ProcessRunner.output(["zmx", "version"]) else { return nil }
        for line in versionOutput.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("socket_dir") {
                let parts = trimmed.components(separatedBy: CharacterSet.whitespaces)
                return parts.last
            }
        }
        return nil
    }

    /// Destroy the surface and clean up
    func destroy() {
        recoveryTimer?.cancel()
        recoveryTimer = nil
        if let surface {
            ghostty_surface_request_close(surface)
        }
        view?.removeFromSuperview()
        surface = nil
        view = nil
        containerView = nil
    }

    deinit {
        destroy()
    }
}

// MARK: - GhosttyNSView

/// The NSView subclass that hosts a Ghostty Metal surface.
/// Forwards keyboard and mouse events to the Ghostty C API.
class GhosttyNSView: NSView, NSTextInputClient {
    var surface: ghostty_surface_t?
    weak var terminalSurface: TerminalSurface?
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

        // Resize backend session layout if needed (tmux only)
        terminalSurface?.refreshSessionLayout()
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

import AppKit

protocol StationDelegate: AnyObject {
    /// Called when a stale session was detected and the station was recreated.
    /// The delegate should re-embed `station.view` into the appropriate container.
    func stationDidRecover(_ station: Station)
    /// Called after a station tore its surface down to sleep. The delegate should
    /// drop the now-dead view registration so layout skips the leaf.
    func stationDidSleep(_ station: Station)
    /// A live view a woken station can be created into when the container it
    /// slept in is gone. Placement is not this view's job — `stationDidRecover`
    /// fires immediately afterwards and lays the surface out properly — so any
    /// view still in the hierarchy will do.
    func stationContainer(for station: Station) -> NSView?
}

extension StationDelegate {
    func stationDidSleep(_ station: Station) {}
    func stationContainer(for station: Station) -> NSView? { nil }
}

/// Manages a single Ghostty terminal surface (NSView + PTY + Metal renderer).
/// Each worktree gets one Station instance.
class Station {
    /// Unique identifier for this terminal instance (used as primary key in AgentRegistry)
    let id: String = UUID().uuidString

    /// The NSView that Ghostty renders into (layer-backed, Metal)
    private(set) var view: GhosttyNSView!
    private(set) var surface: ghostty_surface_t?
    private weak var containerView: NSView?

    /// Latest OSC signals Ghostty surfaced for this pane, fed to the detection
    /// engine's osc_title / osc_progress regions. Written from Ghostty's action
    /// callback thread, read from the status-poll thread — guarded by oscLock.
    private let oscLock = NSLock()
    private var _oscTitle = ""
    private var _oscProgress = ""
    /// Live shell cwd from OSC 7 / `GHOSTTY_ACTION_PWD` (empty until reported).
    private var _pwd = ""
    var oscTitle: String { oscLock.lock(); defer { oscLock.unlock() }; return _oscTitle }
    var oscProgress: String { oscLock.lock(); defer { oscLock.unlock() }; return _oscProgress }
    var pwd: String { oscLock.lock(); defer { oscLock.unlock() }; return _pwd }
    func setOscTitle(_ t: String) { oscLock.lock(); _oscTitle = t; oscLock.unlock() }
    func setOscProgress(_ p: String) { oscLock.lock(); _oscProgress = p; oscLock.unlock() }
    func setPwd(_ p: String) { oscLock.lock(); _pwd = p; oscLock.unlock() }
    /// Directory the pane's surface was created in (worktree root, typically).
    /// Used as a fallback base for resolving relative paths when the live OSC 7
    /// `pwd` hasn't been reported — which is the common case inside zmx sessions.
    private(set) var initialWorkingDirectory: String?

    /// Whether typing into this pane can actually reach it.
    ///
    /// A pane whose tab has not been opened in this run owns a Station but no
    /// surface yet, and both `sendText` and `sendEnterKey` quietly return in
    /// that state. Callers must ask before preferring the surface over the
    /// persistent session, or the input is dropped with nothing to show for it.
    var canDeliverInput: Bool { surface != nil }

    /// Session name for persistence backend (nil = direct shell)
    var paneSessionKey: String?
    /// Last-known "strong" pane title (agent session / OSC title), persisted in
    /// the split layout so a restored pane shows its real title immediately —
    /// before a fresh OSC title or agent session ref lands after relaunch.
    var persistedTitle: String?
    /// True only for a pane restored from the saved layout whose live title hasn't
    /// arrived yet. `persistedTitle` bridges the header during that gap; once any
    /// live source (OSC/session/command) resolves, this flips false so the stale
    /// title can never resurface on a *later* session started in the same pane
    /// (e.g. after `/clear` or an agent restart), which read as a duplicate title.
    var titleBridgeActive: Bool = false
    /// Persistence backend for the paneSessionKey above.
    var backend: String = "zmx"
    /// Agent resume ref, if this pane runs a recognized agent. When a *fresh*
    /// backend session must be created (restore into a missing session, or zmx
    /// recovery), the session is seeded with the agent's resume command instead
    /// of a plain shell. Populated from Config on restore and from live hook
    /// events mid-session.
    var agentSessionRef: AgentSessionRef?
    /// Delegate notified when a stale session is recovered.
    weak var delegate: StationDelegate?

    private var recoveryTimer: DispatchWorkItem?
    private static let recoveryDelay: TimeInterval = 3.0
    /// Gap before a second probe is allowed to confirm an unreachable session.
    /// A daemon busy enough to miss one `zmx list` probe is indistinguishable
    /// from a wedged one in that instant; only the wedged one is still
    /// unreachable a beat later.
    private static let unreachableConfirmDelay: TimeInterval = 5.0
    /// Recoveries attempted since this pane was last seen healthy. A backend
    /// broken for reasons recovery cannot touch — the volume holding the zmx
    /// binary is gone — would otherwise thrash forever, because every recovery
    /// re-attaches and schedules the next health check.
    private var zmxRecoveryAttempts = 0
    private static let maxZmxRecoveryAttempts = 3

    /// Owned C strings passed into `ghostty_surface_config_s`. libghostty's
    /// embedded path copies `working_directory` into its arena but assigns
    /// `command` as a borrowed slice — if we only use `String.withCString`,
    /// the pointer dies when the closure returns and the PTY starts a plain
    /// login shell instead of `zmx attach` (sessions look "brand new" every launch).
    private var ownedCommand: UnsafeMutablePointer<CChar>?
    private var ownedWorkingDirectory: UnsafeMutablePointer<CChar>?

    /// Serializes Ghostty C API access across threads.
    /// Background polling (readViewportText) and main-thread input (key/mouse)
    /// must not call into the same ghostty_surface_t concurrently.
    let ghosttyLock = NSLock()

    /// Create the terminal surface and add it to the given container view.
    /// If paneSessionKey is provided, the surface runs inside a persistent backend session.
    /// - Parameter initialFrame: When set (split create), embed with frame layout at
    ///   this rect and size the PTY to it immediately — avoids Auto Layout fill of the
    ///   full container (which used to SIGWINCH the sibling pane mid-create).
    func create(
        in container: NSView,
        workingDirectory: String? = nil,
        paneSessionKey: String? = nil,
        initialFrame: CGRect? = nil,
        completion: (() -> Void)? = nil
    ) -> Bool {
        guard let app = GhosttyBridge.shared.app else {
            NSLog("GhosttyBridge not initialized")
            return false
        }

        if let paneSessionKey {
            if backend == "zmx" {
                // If this pane runs an agent and the backend session no longer
                // exists (e.g. reboot lost the zmx daemon), seed a fresh session
                // running the agent's resume command before attaching, instead
                // of attaching into an empty shell. Seeding needs blocking
                // process calls, so defer to a background thread and attach on
                // main.
                if let resumeCmd = agentSessionRef?.resumeCommandLine(), let cwd = workingDirectory {
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        ZmxSessionRecovery.seedSessionIfMissing(name: paneSessionKey, cwd: cwd, agentCommandLine: resumeCmd)
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.attachZmx(
                                app: app,
                                container: container,
                                workingDirectory: workingDirectory,
                                paneSessionKey: paneSessionKey,
                                initialFrame: initialFrame
                            )
                            completion?()
                        }
                    }
                    return true  // Surface creation is deferred
                }
                attachZmx(
                    app: app,
                    container: container,
                    workingDirectory: workingDirectory,
                    paneSessionKey: paneSessionKey,
                    initialFrame: initialFrame
                )
                return surface != nil
            }
        }

        _createWithCommand(
            app: app,
            container: container,
            workingDirectory: workingDirectory,
            command: nil,
            initialFrame: initialFrame
        )
        return surface != nil
    }

    /// Attach to a zmx session and schedule the post-attach health check.
    /// Build the pane command for attaching to a zmx session. `env -u` guards
    /// against a leaked ZMX_SESSION (e.g. app relaunched from inside a pane):
    /// zmx attach prefers $ZMX_SESSION over its argument, which would silently
    /// attach every pane to the wrong session.
    static func zmxAttachCommand(paneSessionKey: String) -> String {
        "/usr/bin/env -u ZMX_SESSION \(ShellEscape.singleQuote(ZmxLocator.executable())) attach \(paneSessionKey)"
    }

    private func attachZmx(
        app: ghostty_app_t,
        container: NSView,
        workingDirectory: String?,
        paneSessionKey: String,
        initialFrame: CGRect? = nil
    ) {
        let zmxCommand = Self.zmxAttachCommand(paneSessionKey: paneSessionKey)
        _createWithCommand(
            app: app,
            container: container,
            workingDirectory: workingDirectory,
            command: zmxCommand,
            initialFrame: initialFrame
        )
        if surface != nil {
            scheduleZmxHealthCheck(paneSessionKey: paneSessionKey, container: container, workingDirectory: workingDirectory)
        }
    }

    private func _createWithCommand(
        app: ghostty_app_t,
        container: NSView,
        workingDirectory: String?,
        command: String?,
        initialFrame: CGRect? = nil
    ) {
        let frame = initialFrame ?? container.bounds
        let termView = GhosttyNSView(frame: frame)
        termView.wantsLayer = true

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(termView).toOpaque()
        config.scale_factor = Double(container.window?.backingScaleFactor ?? 2.0)

        // strdup + retain until destroy — see `ownedCommand` docs.
        freeOwnedSurfaceStrings()
        if let workingDirectory {
            initialWorkingDirectory = workingDirectory
            ownedWorkingDirectory = strdup(workingDirectory)
            config.working_directory = UnsafePointer(ownedWorkingDirectory)
        }
        if let command {
            ownedCommand = strdup(command)
            config.command = UnsafePointer(ownedCommand)
        }

        _createSurface(
            app: app,
            config: &config,
            view: termView,
            container: container,
            initialFrame: initialFrame
        )
    }

    private func freeOwnedSurfaceStrings() {
        if let ownedCommand {
            free(ownedCommand)
            self.ownedCommand = nil
        }
        if let ownedWorkingDirectory {
            free(ownedWorkingDirectory)
            self.ownedWorkingDirectory = nil
        }
    }

    private func _createSurface(
        app: ghostty_app_t,
        config: inout ghostty_surface_config_s,
        view: GhosttyNSView,
        container: NSView,
        initialFrame: CGRect? = nil
    ) {
        guard let s = ghostty_surface_new(app, &config) else {
            NSLog("Failed to create Ghostty surface")
            return
        }
        self.surface = s
        self.view = view
        self.containerView = container
        view.surface = s
        view.station = self

        if let initialFrame {
            // Split create: frame-based at the final leaf rect. Auto Layout fill
            // of the whole container would trigger a partial layoutTree and
            // SIGWINCH the sibling before this leaf is registered.
            view.translatesAutoresizingMaskIntoConstraints = true
            view.frame = initialFrame
            container.addSubview(view)
        } else {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        // Set initial size — Ghostty expects pixel (framebuffer) dimensions, not points.
        // Use convertToBacking for the actual scale factor (handles non-integer scales).
        let viewFrame = initialFrame ?? container.bounds
        let fbFrame = container.convertToBacking(viewFrame)
        let xScale = viewFrame.width > 0 ? fbFrame.width / viewFrame.width : 2.0
        let yScale = viewFrame.height > 0 ? fbFrame.height / viewFrame.height : 2.0
        ghostty_surface_set_content_scale(s, Double(xScale), Double(yScale))
        ghostty_surface_set_size(s, UInt32(fbFrame.width), UInt32(fbFrame.height))
        view.markSurfaceSizeSynced(viewFrame.size)
        ghostty_surface_set_focus(s, false)  // Start unfocused; focus set via makeFirstResponder
        ghostty_surface_set_color_scheme(s, GhosttyBridge.shared.currentColorScheme)
    }

    /// Reparent this terminal's view to a different container
    func reparent(to container: NSView) {
        guard let view, surface != nil else { return }

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

        // Resolve constraints and sync the surface inside the same disabled-
        // actions transaction, so the first displayed frame already has the
        // final geometry — the old deferred sync showed one frame at the
        // previous grid size after a reparent.
        container.layoutSubtreeIfNeeded()
        syncContentScale()
        syncSize()

        CATransaction.commit()

        self.containerView = container

        // Focus restoration stays deferred: it must run after Ghostty's own
        // deferred focus handling on this runloop turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.view, self.surface != nil else { return }
            // Restore AppKit first responder so keyboard events reach the terminal.
            // Only grab focus if no other terminal already has it (e.g. in a split pane
            // where showTerminal() already focused the correct leaf).
            if !(view.window?.firstResponder is GhosttyNSView) {
                view.window?.makeFirstResponder(view)
            }
            view.needsDisplay = true
        }
    }

    /// Sync the surface size with the current container bounds
    func syncSize() {
        guard let view else { return }
        // Explicit sync (window resize / reparent) must override a split absorb
        // freeze — otherwise the PTY grid stays stuck at the pre-split size.
        view.clearPtyGridResizeFreeze()
        // Reset the debounce so syncSurfaceSize() will run even if the
        // same size was already synced through setFrameSize.
        view.resetLastSyncedSize()
        view.syncSurfaceSize()
    }

    /// Sync the content scale (Retina vs non-Retina)
    func syncContentScale() {
        guard let surface, let view, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let fbFrame = view.convertToBacking(view.bounds)
        let xScale = fbFrame.width / view.bounds.width
        let yScale = fbFrame.height / view.bounds.height
        ghostty_surface_set_content_scale(surface, Double(xScale), Double(yScale))
    }

    /// Check if the process has exited
    var processExited: Bool {
        // Read `surface` inside the lock: destroy() frees it under the same
        // lock, so a pointer captured before locking could dangle.
        ghosttyLock.lock()
        defer { ghosttyLock.unlock() }
        guard let surface else { return true }
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

    /// How long to wait between `sendText` and `sendEnterKey`.
    ///
    /// A real Return key event still reads as part of the paste if it lands in
    /// the same burst — agent TUIs debounce their input to decide where a paste
    /// ends, so the Return becomes a newline in the composer and the text sits
    /// there unsent. Every "type this, then run it" path must space the two.
    static let enterSubmitDelay: TimeInterval = 0.08

    /// Send a real Return key press+release (not a `\r` via the text path). Agent
    /// TUIs (Claude Code, codex) treat a `\r` arriving through text/paste as a
    /// literal newline, but a genuine Enter key event as submit. Used to send a
    /// command after `sendText` so it actually executes — after
    /// `enterSubmitDelay`, never in the same burst.
    func sendEnterKey() {
        guard let surface else { return }
        let returnKeycode: UInt32 = 36  // macOS kVK_Return
        var press = ghostty_input_key_s()
        press.action = GHOSTTY_ACTION_PRESS
        press.keycode = returnKeycode
        press.mods = GHOSTTY_MODS_NONE
        "\r".withCString { cStr in
            press.text = cStr
            _ = ghostty_surface_key(surface, press)
        }
        var release = ghostty_input_key_s()
        release.action = GHOSTTY_ACTION_RELEASE
        release.keycode = returnKeycode
        release.mods = GHOSTTY_MODS_NONE
        _ = ghostty_surface_key(surface, release)
    }

    func readViewportText() -> String? {
        var contended = false
        return readViewportText(tryOnly: false, contended: &contended)
    }

    /// Background poll variant: gives up without blocking when `ghosttyLock` is
    /// held (someone is typing / pasting) — input latency matters more than one
    /// poll cycle, and the poller retries 2s later. `contended` lets the caller
    /// tell "skip this cycle" apart from "viewport is empty".
    func readViewportTextForPoll() -> (contended: Bool, text: String?) {
        var contended = false
        let text = readViewportText(tryOnly: true, contended: &contended)
        return (contended, text)
    }

    private func readViewportText(tryOnly: Bool, contended: inout Bool) -> String? {
        // Hold ghosttyLock only for the C calls plus a raw byte copy. Building
        // the String (UTF-8 validation + allocation over a full viewport) used
        // to happen inside the lock, stalling main-thread input that contends
        // for it during every background status poll. `surface` must be read
        // inside the lock — destroy() frees it under the same lock.
        var bytes: [UInt8]?
        if tryOnly {
            guard ghosttyLock.try() else {
                contended = true
                return nil
            }
        } else {
            ghosttyLock.lock()
        }
        guard let surface else {
            ghosttyLock.unlock()
            return nil
        }
        let size = ghostty_surface_size(surface)
        if size.rows > 0, size.columns > 0 {
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
            if ghostty_surface_read_text(surface, selection, &text) {
                if let ptr = text.text, text.text_len > 0 {
                    ptr.withMemoryRebound(to: UInt8.self, capacity: Int(text.text_len)) {
                        bytes = Array(UnsafeBufferPointer(start: $0, count: Int(text.text_len)))
                    }
                }
                // Freeing this matters: the poll runs per pane every 2s, and a
                // free that does not land leaks a viewport buffer each time —
                // 105 MB/h across 19 panes when the header and implementation
                // disagreed about this signature. check-ghostty-abi.py guards it.
                ghostty_surface_free_text(surface, &text)
            }
        }
        ghosttyLock.unlock()

        guard var buf = bytes else { return nil }
        // Match String(cString:) semantics: the buffer is NUL-terminated and
        // text_len may include the terminator.
        if let nul = buf.firstIndex(of: 0) { buf.removeSubrange(nul...) }
        guard !buf.isEmpty else { return nil }
        return String(decoding: buf, as: UTF8.self)
    }

    /// True when a live ghostty surface exists. Background dashboard cards that
    /// were never opened have no surface, so `readViewportText()` returns nil and
    /// status scanning must fall back to `readBackendText()`.
    var hasLiveSurface: Bool { surface != nil }

    /// Capture the current backend session frame for status scanning when there
    /// is no live surface to read (e.g. an overview card never selected). zmx
    /// `history` includes the live rendered frame — alt-screen TUIs like Claude
    /// Code included — so the agent's status line ("esc to interrupt", prompts)
    /// is present. Returns the last `lines` rows to approximate a viewport (keeps
    /// bottom-anchored detection rules honest and bounds scrollback false matches).
    /// Runs a subprocess — call off the main thread only. Returns nil when there
    /// is a live surface (use `readViewportText()` instead) or no backend session.
    func readBackendText(lines: Int = 60) -> String? {
        guard surface == nil, backend == "zmx", let paneSessionKey else { return nil }
        return ZmxChannel(paneSessionKey: paneSessionKey).readOutput(lines: lines)
    }

    /// Get the process status for status detection
    var processStatus: ProcessStatus {
        ghosttyLock.lock()
        defer { ghosttyLock.unlock() }
        guard let surface else { return .unknown }
        if ghostty_surface_process_exited(surface) {
            // We don't have the exit code from ghostty, so assume exited
            return .exited
        }
        return .running
    }

    // MARK: - Zmx Session Recovery

    /// Schedule a health check after zmx attach. If the attach client has
    /// exited, re-attach (and only recreate the daemon when it is truly gone).
    private func scheduleZmxHealthCheck(paneSessionKey: String, container: NSView, workingDirectory: String?) {
        recoveryTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.checkZmxHealth(paneSessionKey: paneSessionKey, container: container, workingDirectory: workingDirectory)
        }
        recoveryTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recoveryDelay, execute: work)
    }

    private func checkZmxHealth(paneSessionKey: String, container: NSView, workingDirectory: String?) {
        // If the surface was already destroyed, nothing to do.
        guard surface != nil else { return }
        // Deliberately no "did the attach process exit?" gate here. A daemon
        // wedged by its volume disappearing leaves the client hanging rather than
        // exiting, so gating on exit meant the one failure that never recovers on
        // its own was also the one this check never looked at.
        probeZmxSession(
            paneSessionKey: paneSessionKey,
            container: container,
            workingDirectory: workingDirectory,
            processExited: processStatus == .exited,
            confirmUnreachable: true
        )
    }

    /// Probe the session's reachability off the main thread and act on the plan.
    ///
    /// `confirmUnreachable` spends one delayed re-probe before an unreachable
    /// reading is allowed to mean "dead" — see `ZmxSessionRecovery.plan`.
    private func probeZmxSession(
        paneSessionKey: String,
        container: NSView,
        workingDirectory: String?,
        processExited: Bool,
        confirmUnreachable: Bool
    ) {
        // Reachability is a blocking `zmx list`, and a slow one exactly when
        // sessions are wedged — never on the main thread.
        let queue = DispatchQueue.global(qos: .utility)
        queue.async { [weak self] in
            guard self != nil else { return }
            let reachability = SessionManager.sessionReachability(name: paneSessionKey, backend: "zmx")
            if reachability == .unreachable, confirmUnreachable {
                // asyncAfter, not sleep: with a dozen panes probing at once,
                // parking a pool thread each is how the dispatch pool starves.
                queue.asyncAfter(deadline: .now() + Self.unreachableConfirmDelay) { [weak self] in
                    self?.probeZmxSession(
                        paneSessionKey: paneSessionKey,
                        container: container,
                        workingDirectory: workingDirectory,
                        processExited: processExited,
                        confirmUnreachable: false
                    )
                }
                return
            }
            let plan = ZmxSessionRecovery.plan(processExited: processExited, reachability: reachability)
            guard plan != .none else {
                // A pane confirmed healthy gets its recovery budget back.
                if reachability == .reachable {
                    DispatchQueue.main.async { self?.zmxRecoveryAttempts = 0 }
                }
                return
            }
            NSLog(
                "Station: zmx session '%@' unhealthy — exited=%@ reachability=%@ plan=%@",
                paneSessionKey,
                processExited ? "yes" : "no",
                String(describing: reachability),
                String(describing: plan)
            )
            DispatchQueue.main.async {
                self?.recoverZmxSession(
                    paneSessionKey: paneSessionKey,
                    container: container,
                    workingDirectory: workingDirectory,
                    plan: plan
                )
            }
        }
    }

    private func recoverZmxSession(
        paneSessionKey: String,
        container: NSView,
        workingDirectory: String?,
        plan: ZmxSessionRecovery.Plan
    ) {
        guard zmxRecoveryAttempts < Self.maxZmxRecoveryAttempts else {
            NSLog(
                "Station: giving up on zmx session '%@' after %d recovery attempts",
                paneSessionKey, zmxRecoveryAttempts
            )
            return
        }
        zmxRecoveryAttempts += 1
        let resumeCmd = agentSessionRef?.resumeCommandLine()
        DispatchQueue.global(qos: .utility).async {
            switch plan {
            case .none:
                return
            case .reattach:
                // Client died; daemon (and agent) still alive — do not kill.
                break
            case .recreate:
                // Session is gone. Clear any stale socket, then optionally seed
                // an agent resume so we don't land in an empty shell.
                ZmxSessionRecovery.forceKillSession(paneSessionKey)
                if let resumeCmd, let cwd = workingDirectory {
                    ZmxSessionRecovery.seedSessionIfMissing(
                        name: paneSessionKey, cwd: cwd, agentCommandLine: resumeCmd)
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let app = GhosttyBridge.shared.app else { return }

                self.destroy()

                let zmxCommand = Self.zmxAttachCommand(paneSessionKey: paneSessionKey)
                self._createWithCommand(
                    app: app,
                    container: container,
                    workingDirectory: workingDirectory,
                    command: zmxCommand
                )
                self.delegate?.stationDidRecover(self)
            }
        }
    }

    // MARK: - Sleep / Wake

    /// True while this pane's ghostty surface is torn down to reclaim memory.
    /// Only the surface goes away — the zmx session (and the agent inside it)
    /// keeps running, and status detection falls back to `readBackendText()`,
    /// the same path already used for dashboard cards that were never opened.
    private(set) var isAsleep = false
    /// Superview + frame captured at sleep so `wake()` can rebuild in place.
    private weak var sleepContainer: NSView?
    private var sleepFrame: CGRect?

    /// Whether this pane may sleep. A pane with no persistent backend session
    /// has nowhere to keep its process, so sleeping it would silently kill the
    /// work — `local` panes are never eligible.
    var canSleep: Bool {
        surface != nil && !isAsleep && backend == "zmx" && !(paneSessionKey ?? "").isEmpty
    }

    /// Pins the post-`sleep()` flag without a live Ghostty surface, so layout /
    /// Wake wiring can be unit-tested. Precondition: no surface (same as after
    /// a real sleep).
    func adoptAsleepStateForTesting() {
        precondition(surface == nil, "adoptAsleepStateForTesting requires no surface")
        isAsleep = true
    }

    /// Whether an embed/restore pass should call `create`. Asleep panes keep
    /// `surface == nil` on purpose; recreating one while leaving `isAsleep`
    /// set makes the Wake button a no-op (`wake()` used to require
    /// `surface == nil`).
    static func shouldCreateSurfaceOnEmbed(hasSurface: Bool, isAsleep: Bool) -> Bool {
        !hasSurface && !isAsleep
    }

    /// How `wake()` should proceed. Pure so the "Wake does nothing" regressions
    /// are pin-downable without a live Ghostty surface.
    enum WakePlan: Equatable {
        case noop
        /// Surface already exists (embed incorrectly recreated it while asleep).
        case adoptExisting
        /// Need to recreate into the given container.
        case recreate
    }

    static func wakePlan(isAsleep: Bool, hasSurface: Bool, hasContainer: Bool) -> WakePlan {
        guard isAsleep else { return .noop }
        if hasSurface { return .adoptExisting }
        return hasContainer ? .recreate : .noop
    }

    /// Free the ghostty surface (Metal drawables + screen buffer) while leaving
    /// the backend session running. Main thread. Returns false if not eligible.
    @discardableResult
    func sleep() -> Bool {
        guard canSleep else { return false }
        sleepContainer = view?.superview ?? containerView
        sleepFrame = view?.frame
        destroy()
        isAsleep = true
        delegate?.stationDidSleep(self)
        return true
    }

    /// Re-create the surface and re-attach to the backend session, then hand the
    /// new view back to the container through the same re-embed path zmx recovery
    /// uses. Main thread. Returns false if the station wasn't asleep.
    @discardableResult
    func wake() -> Bool {
        // `sleepContainer` is weak, and a pane can stay asleep long enough for
        // the container it slept in to be torn down (worktree switch, layout
        // rebuild). Without a fallback such a pane is stranded: `wake()` bails,
        // and with `surface == nil` it can never be slept or woken again either.
        let originalContainer = sleepContainer
        let container = originalContainer ?? delegate?.stationContainer(for: self)
        switch Self.wakePlan(isAsleep: isAsleep, hasSurface: surface != nil, hasContainer: container != nil) {
        case .noop:
            return false
        case .adoptExisting:
            // Embed recreated the surface while we were still marked asleep —
            // clear the flag and re-register so the placeholder goes away.
            isAsleep = false
            sleepContainer = nil
            sleepFrame = nil
            delegate?.stationDidRecover(self)
            return true
        case .recreate:
            guard let container, let app = GhosttyBridge.shared.app else { return false }
            _createWithCommand(
                app: app,
                container: container,
                workingDirectory: initialWorkingDirectory,
                command: paneSessionKey.map { Self.zmxAttachCommand(paneSessionKey: $0) },
                // The captured frame only means anything inside the container it was
                // captured from; a substitute container lays out from its own bounds.
                initialFrame: originalContainer != nil ? sleepFrame : nil
            )
            // Stay asleep if the surface did not come back, so the pane keeps the one
            // state `wake()` accepts and the next attempt can retry. Clearing the flag
            // first left a failed wake as `!isAsleep && surface == nil`, which neither
            // `sleep()` nor `wake()` will touch again.
            guard surface != nil else { return false }
            // Before `stationDidRecover`, which registers the new view: `layoutTree`
            // hides the surface view of a leaf it still believes is asleep, and only
            // the placeholder is ever un-hidden.
            isAsleep = false
            sleepContainer = nil
            sleepFrame = nil
            delegate?.stationDidRecover(self)
            return true
        }
    }

    /// Destroy the surface and clean up
    func destroy() {
        recoveryTimer?.cancel()
        recoveryTimer = nil
        view?.surface = nil
        view?.removeFromSuperview()
        // Free under ghosttyLock so the background status poll can't be mid-read
        // on this surface. Freeing (not just request_close) is what tears down
        // the PTY and renderer — request_close only fires the host callback.
        ghosttyLock.lock()
        if let surface {
            ghostty_surface_free(surface)
        }
        surface = nil
        ghosttyLock.unlock()
        freeOwnedSurfaceStrings()
        view = nil
        containerView = nil
    }

    deinit {
        destroy()
    }
}

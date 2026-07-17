import AppKit
import SwiftUI

/// Owns the floating notch panel. The window is always at its maximum
/// (opened) size and never resizes — mixing AppKit window animation with
/// SwiftUI springs causes visible jank, so all morphing is done in SwiftUI
/// inside this fixed transparent window. Clicks outside the current visual
/// content pass through via `IslandHostingView.hitTest`.
final class IslandPanelController {
    static let maxOpenedContentHeight: CGFloat = 520
    private static let shadowInset: CGFloat = 24

    let model = IslandModel()

    private var panel: IslandPanel?
    private var eventMonitors = IslandEventMonitors()
    private var hoverTimer: DispatchWorkItem?
    private var eventAutoCloseTimer: DispatchWorkItem?
    /// Pointer has entered the surface since an event-open — once engaged,
    /// leaving the surface collapses it again.
    private var eventOpenEngaged = false
    private static let eventAutoCloseDelay: TimeInterval = 10

    func install() {
        guard panel == nil else { return }
        guard let screen = targetScreen() else { return }
        updateGeometry(for: screen)

        let panel = IslandPanel(
            contentRect: panelFrame(on: screen),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        // `.stationary` keeps the overlay pinned during the Sonoma "click
        // wallpaper to reveal desktop" gesture and Mission Control.
        panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .ignoresCycle, .stationary]

        let hosting = IslandHostingView(rootView: IslandRootView(model: model))
        hosting.controller = self
        panel.contentView = hosting
        panel.onEscape = { [weak self] in
            guard let self, self.model.isOpened else { return false }
            self.model.close()
            return true
        }

        self.panel = panel
        panel.orderFrontRegardless()

        eventMonitors.start { [weak self] location in
            self?.handleMouseMoved(location)
        } mouseDownHandler: { [weak self] location in
            self?.handleMouseDown(location)
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        updateVisibility()
    }

    func uninstall() {
        eventMonitors.stop()
        panel?.orderOut(nil)
        panel = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func activeSpaceChanged() {
        updateVisibility()
    }

    /// Open the island with the command field focused (Cmd+N entry point).
    func openCommandBar(prefill: String) {
        guard let panel else { return }
        if !panel.isVisible { panel.orderFrontRegardless() }
        model.pendingCommandPrefill = prefill
        model.open(reason: .click)
        panel.makeKey()
    }

    /// Auto-expand for an arriving suggestion so the card is visible without
    /// hovering. Collapses again after a timeout if the pointer never comes,
    /// or as soon as it leaves after having engaged.
    func openForEvent() {
        guard let panel, !model.isOpened else { return }
        if !panel.isVisible { updateVisibility() }
        guard panel.isVisible else { return }
        eventOpenEngaged = false
        model.open(reason: .event)
        panel.makeKey()
        scheduleEventAutoClose()
    }

    private func scheduleEventAutoClose() {
        eventAutoCloseTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.isOpened, self.model.openReason == .event,
                  !self.eventOpenEngaged else { return }
            self.model.close()
        }
        eventAutoCloseTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.eventAutoCloseDelay, execute: work)
    }

    /// Hide the island while the target screen is in a fullscreen space —
    /// the pill's wings (and the whole simulated notch on external displays)
    /// would otherwise sit on top of the fullscreen app. A pending
    /// suggestion overrides the hide: it is actionable and time-sensitive.
    func updateVisibility() {
        guard let panel, let screen = targetScreen() else { return }
        let fullscreen = Self.hasFullscreenWindow(on: screen)
        let shouldShow = !fullscreen || !model.orders.isEmpty
        if shouldShow {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible {
            model.close()
            panel.orderOut(nil)
        }
    }

    /// True when another app's normal-layer window fully covers the screen
    /// in the current space. Fullscreen windows cover the whole frame
    /// including the menu-bar band; ordinary maximized windows don't, so
    /// they never match. (`visibleFrame` is not reliable here — AppKit often
    /// doesn't refresh it for fullscreen spaces.)
    private static func hasFullscreenWindow(on screen: NSScreen) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        // CG coordinates: top-left origin of the primary display.
        let primaryHeight = NSScreen.screens.first.map { $0.frame.maxY } ?? 0
        let target = CGRect(
            x: screen.frame.minX,
            y: primaryHeight - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
        let ownPID = ProcessInfo.processInfo.processIdentifier

        for info in windows {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
            )
            if bounds.insetBy(dx: -2, dy: -2).contains(target) {
                return true
            }
        }
        return false
    }

    @objc private func screensChanged() {
        guard let panel, let screen = targetScreen() else { return }
        updateGeometry(for: screen)
        let frame = panelFrame(on: screen)
        if panel.frame != frame {
            // Instant — no AppKit animation (see class comment).
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: - Geometry

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        if let notched = screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? screens[0]
    }

    private func updateGeometry(for screen: NSScreen) {
        let isNotched = screen.safeAreaInsets.top > 0
        model.isNotchedDisplay = isNotched
        if isNotched {
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            model.notchWidth = screen.frame.width - left - right + 4
            model.notchHeight = screen.safeAreaInsets.top
        } else {
            model.notchWidth = 190
            // Sit inside the menu bar band on plain displays.
            model.notchHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY) > 0
                ? (screen.frame.maxY - screen.visibleFrame.maxY)
                : 30
        }
        model.openedWidth = max(360, min(540, screen.visibleFrame.width - 32))
    }

    private func panelFrame(on screen: NSScreen) -> NSRect {
        let width = model.openedWidth + Self.shadowInset * 2
        let height = model.notchHeight + Self.maxOpenedContentHeight
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    /// Screen-coordinate rect of the current visual content — the closed
    /// pill or the opened surface. Used for both event routing and hitTest.
    func visibleContentRect() -> NSRect? {
        guard let panel else { return nil }
        let frame = panel.frame
        if model.isOpened {
            let height = model.measuredOpenedHeight > 0
                ? min(model.measuredOpenedHeight, Self.maxOpenedContentHeight)
                : Self.maxOpenedContentHeight
            return NSRect(
                x: frame.midX - model.openedWidth / 2,
                y: frame.maxY - height,
                width: model.openedWidth,
                height: height
            )
        }
        return NSRect(
            x: frame.midX - model.closedWidth / 2,
            y: frame.maxY - model.notchHeight,
            width: model.closedWidth,
            height: model.notchHeight
        )
    }

    // MARK: - Mouse handling

    private func handleMouseMoved(_ location: NSPoint) {
        let inPill = !model.isOpened && (visibleContentRect()?.insetBy(dx: -8, dy: -4).contains(location) ?? false)
        if inPill {
            scheduleHoverOpen()
        } else {
            hoverTimer?.cancel()
            hoverTimer = nil
        }

        // Event-opened surface: engage on enter, collapse on leave.
        if model.isOpened, model.openReason == .event,
           let rect = visibleContentRect() {
            let inside = rect.insetBy(dx: -12, dy: -12).contains(location)
            if inside {
                eventOpenEngaged = true
                eventAutoCloseTimer?.cancel()
            } else if eventOpenEngaged {
                model.close()
            }
        }
    }

    private func handleMouseDown(_ location: NSPoint) {
        guard let rect = visibleContentRect() else { return }
        if model.isOpened {
            if rect.contains(location) {
                // Monitors run before normal dispatch — make the panel key
                // now so the SwiftUI Button fires instead of consuming the
                // click for key acquisition. (hitTest may route mouseDown to
                // an internal SwiftUI subview, bypassing the hosting view's
                // own makeKey fallback.)
                panel?.makeKey()
            } else {
                model.close()
                repostMouseDown(at: location)
            }
        } else if rect.contains(location) {
            hoverTimer?.cancel()
            hoverTimer = nil
            model.open(reason: .click)
            panel?.makeKey()
        }
    }

    private func scheduleHoverOpen() {
        guard hoverTimer == nil, !model.isOpened else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.isOpened else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            self.model.open(reason: .hover)
            self.panel?.makeKey()
            self.hoverTimer = nil
        }
        hoverTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + IslandModel.hoverOpenDelay, execute: work)
    }

    /// The click that closed the island was swallowed by our monitors —
    /// re-post it so it still lands on the app underneath.
    private func repostMouseDown(at screenPoint: NSPoint) {
        let flippedY = NSScreen.screens.first.map { $0.frame.height - screenPoint.y } ?? screenPoint.y
        let position = CGPoint(x: screenPoint.x, y: flippedY)
        guard let down = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: position, mouseButton: .left
        ) else { return }
        down.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseUp,
                mouseCursorPosition: position, mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - IslandPanel

private final class IslandPanel: NSPanel {
    var onEscape: (() -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        if onEscape?() != true { super.cancelOperation(sender) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, onEscape?() == true { return }
        super.keyDown(with: event)
    }
}

// MARK: - IslandHostingView

private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    weak var controller: IslandPanelController?

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let controller,
              let window,
              let contentRect = controller.visibleContentRect() else { return nil }
        // `point` is in the superview's coordinate system — and the window
        // frame view is flipped, so convert properly instead of treating it
        // as local coordinates (that mirrored y and killed clicks near the
        // top of the surface).
        let local = superview.map { convert(point, from: $0) } ?? point
        let windowPoint = convert(local, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        guard contentRect.contains(screenPoint) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {
        // Non-activating panels aren't key when hover-opened; make key
        // before SwiftUI sees the click so gestures fire on the first tap.
        window?.makeKey()
        super.mouseDown(with: event)
    }
}

// MARK: - IslandEventMonitors

private final class IslandEventMonitors {
    private var monitors: [Any] = []

    func start(
        mouseMoveHandler: @escaping (NSPoint) -> Void,
        mouseDownHandler: @escaping (NSPoint) -> Void
    ) {
        guard monitors.isEmpty else { return }
        var lastMove: TimeInterval = 0
        let throttle: TimeInterval = 0.05

        let onMove: (NSEvent) -> Void = { _ in
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastMove >= throttle else { return }
            lastMove = now
            mouseMoveHandler(NSEvent.mouseLocation)
        }
        let onDown: (NSEvent) -> Void = { _ in
            mouseDownHandler(NSEvent.mouseLocation)
        }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: onMove) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { onMove($0); return $0 }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: onDown) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { onDown($0); return $0 }) {
            monitors.append(m)
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}

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
    }

    func uninstall() {
        eventMonitors.stop()
        panel?.orderOut(nil)
        panel = nil
        NotificationCenter.default.removeObserver(self)
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
    }

    private func handleMouseDown(_ location: NSPoint) {
        guard let rect = visibleContentRect() else { return }
        if model.isOpened {
            if !rect.contains(location) {
                model.close()
                repostMouseDown(at: location)
            }
        } else if rect.contains(location) {
            hoverTimer?.cancel()
            hoverTimer = nil
            model.open(reason: .click)
        }
    }

    private func scheduleHoverOpen() {
        guard hoverTimer == nil, !model.isOpened else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.isOpened else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            self.model.open(reason: .hover)
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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - IslandHostingView

private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    weak var controller: IslandPanelController?

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // With .nonactivatingPanel a hover-opened panel isn't key, so a
        // SwiftUI Button would consume the first click acquiring key status
        // instead of firing. Make key before SwiftUI sees the click.
        window?.makeKey()
        super.mouseDown(with: event)
    }

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
        let windowPoint = convert(point, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        guard contentRect.contains(screenPoint) else { return nil }
        return super.hitTest(point) ?? self
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

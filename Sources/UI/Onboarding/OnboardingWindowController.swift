import AppKit

/// Shared palette + small controls for the onboarding wizard. Mirrors the
/// product's bare-TUI look: JetBrains Mono, near-black surface with a cyan
/// cast, and the #1FC8DA accent used by the island and cockpit.
enum OnboardingStyle {
    static let accent = NSColor(red: 0x1f / 255, green: 0xc8 / 255, blue: 0xda / 255, alpha: 1)
    static let background = NSColor(red: 0.016, green: 0.055, blue: 0.066, alpha: 1)
    static let panel = NSColor.white.withAlphaComponent(0.05)
    static let panelHover = NSColor.white.withAlphaComponent(0.09)
    static let panelSelected = accent.withAlphaComponent(0.12)
    static let stroke = NSColor.white.withAlphaComponent(0.08)
    static let strokeSelected = accent.withAlphaComponent(0.8)
    static let textPrimary = NSColor.white.withAlphaComponent(0.92)
    static let textSecondary = NSColor.white.withAlphaComponent(0.5)
    static let textFaint = NSColor.white.withAlphaComponent(0.32)

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = textPrimary) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = AppFont.mono(size: size, weight: weight)
        field.textColor = color
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    static func wrappingLabel(_ text: String, size: CGFloat,
                              color: NSColor = textSecondary) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = AppFont.mono(size: size)
        field.textColor = color
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// Style a checkbox/button title in mono white without replacing the control.
    static func monoTitle(_ button: NSButton, size: CGFloat, color: NSColor = textPrimary) {
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [.font: AppFont.mono(size: size), .foregroundColor: color]
        )
    }
}

/// Flat rounded panel with optional hover/selected states.
final class OnboardingPanel: NSView {
    var isSelected = false { didSet { refresh() } }
    var onClick: (() -> Void)?
    private var hovering = false
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }
    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick() } else { super.mouseDown(with: event) }
    }

    private func refresh() {
        let bg: NSColor = isSelected
            ? OnboardingStyle.panelSelected
            : (hovering && onClick != nil ? OnboardingStyle.panelHover : OnboardingStyle.panel)
        layer?.backgroundColor = bg.cgColor
        layer?.borderColor = (isSelected ? OnboardingStyle.strokeSelected : OnboardingStyle.stroke).cgColor
        layer?.borderWidth = isSelected ? 1.5 : 1
    }
}

/// Accent-filled primary action button (mono, dark text on cyan).
final class OnboardingPrimaryButton: NSButton {
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var title: String {
        didSet { refresh() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func refresh() {
        layer?.backgroundColor = (hovering
            ? OnboardingStyle.accent.withAlphaComponent(0.85)
            : OnboardingStyle.accent).cgColor
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: AppFont.mono(size: 13, weight: .bold),
                .foregroundColor: NSColor.black.withAlphaComponent(0.85),
            ]
        )
    }
}

/// Modal first-launch wizard. Completing it writes config and invokes `onComplete`.
final class OnboardingWindowController: NSWindowController {
    var onComplete: ((Config) -> Void)?

    private var config: Config
    private let contentVC: OnboardingViewController

    init(config: Config) {
        self.config = config
        self.contentVC = OnboardingViewController(config: config)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Seahelm"
        // Branded chrome: the wizard is part of the product, not a system sheet.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = OnboardingStyle.background
        window.isReleasedWhenClosed = false
        window.contentViewController = contentVC
        super.init(window: window)
        window.center()
        contentVC.onFinished = { [weak self] updated in
            guard let self else { return }
            self.config = updated
            self.onComplete?(updated)
            self.close()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Render each step to `<dir>/onboarding-step<N>.png` without showing a
    /// window — design iteration on headless/locked machines.
    static func renderSnapshots(to dir: String) {
        let vc = OnboardingViewController(config: Config.load())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = vc
        for i in 0..<3 {
            vc.debugShowStep(i)
            // Let deferred main-queue work (scroll-to-top, layout passes) land.
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            vc.view.layoutSubtreeIfNeeded()
            guard let rep = vc.view.bitmapImageRepForCachingDisplay(in: vc.view.bounds) else { continue }
            vc.view.cacheDisplay(in: vc.view.bounds, to: rep)
            let url = URL(fileURLWithPath: "\(dir)/onboarding-step\(i + 1).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}

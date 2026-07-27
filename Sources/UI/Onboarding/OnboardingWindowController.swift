import AppKit

/// Modal first-launch wizard. Completing it writes config and invokes `onComplete`.
///
/// The window wears the same glass as the main window and inherits
/// `NSApp.appearance`, so picking a theme in step 3 restyles the wizard itself
/// rather than leaving it in a fixed bright skin that contradicts the choice.
final class OnboardingWindowController: NSWindowController {
    var onComplete: ((Config) -> Void)?

    private var config: Config
    private let contentVC: OnboardingViewController
    private let backgroundEffectView = NSVisualEffectView()

    static let windowSize = NSSize(width: 900, height: 720)

    init(config: Config) {
        self.config = config
        self.contentVC = OnboardingViewController(config: config)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Seahelm"
        // Branded chrome: the wizard is part of the product, not a system sheet.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.contentViewController = contentVC
        super.init(window: window)
        installGlass(in: window)
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

    /// Mirror `MainWindowController`'s background: `SemanticColors` are tuned to
    /// sit on `.underWindowBackground` glass, and several are translucent, so on
    /// a plain opaque window they read washed out.
    private func installGlass(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        let config = WindowStyling.glassBackgroundConfig(isDark: window.effectiveAppearance.isDark)
        backgroundEffectView.material = config.material
        backgroundEffectView.blendingMode = config.blendingMode
        backgroundEffectView.state = .followsWindowActiveState
        backgroundEffectView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(backgroundEffectView, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            backgroundEffectView.topAnchor.constraint(equalTo: contentView.topAnchor),
            backgroundEffectView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Render every step in both appearances to
    /// `<dir>/onboarding-<light|dark>-step<N>.png`, without showing a window —
    /// design iteration on headless/locked machines.
    static func renderSnapshots(to dir: String) {
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let vc = OnboardingViewController(config: Config.load())
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: windowSize),
                styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
            )
            window.appearance = NSAppearance(named: appearance)
            window.contentViewController = vc
            vc.usesOpaqueBackground = true
            for index in 0..<5 {
                vc.debugShowStep(index)
                // Let deferred main-queue work (scroll-to-top, layout) land.
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                vc.view.layoutSubtreeIfNeeded()
                guard let rep = vc.view.bitmapImageRepForCachingDisplay(in: vc.view.bounds) else { continue }
                vc.view.cacheDisplay(in: vc.view.bounds, to: rep)
                let url = URL(fileURLWithPath: "\(dir)/onboarding-\(name)-step\(index + 1).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }
}

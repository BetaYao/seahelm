import AppKit

/// Modal first-launch wizard. Completing it writes config and invokes `onComplete`.
final class OnboardingWindowController: NSWindowController {
    var onComplete: ((Config) -> Void)?

    private var config: Config
    private let contentVC: OnboardingViewController

    init(config: Config) {
        self.config = config
        self.contentVC = OnboardingViewController(config: config)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Seahelm"
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
}

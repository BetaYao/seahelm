import AppKit

/// Hosts the 3-step onboarding flow with progress and navigation.
final class OnboardingViewController: NSViewController {
    var onFinished: ((Config) -> Void)?

    private var config: Config
    private var stepIndex = 0

    private let logoLabel = NSTextField(labelWithString: "")
    private let progressLabel = OnboardingStyle.label("[1/3]", size: 12, color: OnboardingStyle.textSecondary)
    private let progressStack = NSStackView()
    private var progressSegments: [NSView] = []

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let stepContainer = NSView()

    private let footerRule = NSView()
    private let backButton = NSButton(title: "← Back", target: nil, action: nil)
    private let shortcutHint = OnboardingStyle.label("⌘↩", size: 11, color: OnboardingStyle.textFaint)
    private let continueButton = OnboardingPrimaryButton(frame: .zero)

    private lazy var agentStep = OnboardingAgentStepView()
    private lazy var themeStep = OnboardingThemeStepView()
    private lazy var permissionsStep = OnboardingPermissionsStepView()

    private var currentStepView: NSView?

    init(config: Config) {
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 640))
        view.wantsLayer = true
        view.layer?.backgroundColor = OnboardingStyle.background.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildChrome()
        agentStep.configure(config: config)
        themeStep.configure(config: config)
        permissionsStep.configure(config: config)
        showStep(0)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        if event.modifierFlags.contains(.command),
           event.keyCode == 36 /* Return */ {
            advance()
            return nil
        }
        return event
    }

    private func buildChrome() {
        // Wordmark: cyan prompt glyph + product name, like the cockpit.
        let logo = NSMutableAttributedString()
        logo.append(NSAttributedString(string: "❯ ", attributes: [
            .font: AppFont.mono(size: 16, weight: .bold),
            .foregroundColor: OnboardingStyle.accent,
        ]))
        logo.append(NSAttributedString(string: "seahelm", attributes: [
            .font: AppFont.mono(size: 16, weight: .bold),
            .foregroundColor: OnboardingStyle.textPrimary,
        ]))
        logo.append(NSAttributedString(string: "  setup", attributes: [
            .font: AppFont.mono(size: 12),
            .foregroundColor: OnboardingStyle.textFaint,
        ]))
        logoLabel.attributedStringValue = logo
        logoLabel.translatesAutoresizingMaskIntoConstraints = false

        // Segmented progress: one cyan bar per step.
        progressStack.orientation = .horizontal
        progressStack.spacing = 6
        progressStack.distribution = .fillEqually
        progressStack.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<3 {
            let seg = NSView()
            seg.wantsLayer = true
            seg.layer?.cornerRadius = 2
            seg.translatesAutoresizingMaskIntoConstraints = false
            seg.heightAnchor.constraint(equalToConstant: 4).isActive = true
            progressSegments.append(seg)
            progressStack.addArrangedSubview(seg)
        }

        titleLabel.font = AppFont.mono(size: 24, weight: .bold)
        titleLabel.textColor = OnboardingStyle.textPrimary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = AppFont.mono(size: 12.5)
        subtitleLabel.textColor = OnboardingStyle.textSecondary
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        stepContainer.translatesAutoresizingMaskIntoConstraints = false

        footerRule.wantsLayer = true
        footerRule.layer?.backgroundColor = OnboardingStyle.stroke.cgColor
        footerRule.translatesAutoresizingMaskIntoConstraints = false

        backButton.target = self
        backButton.action = #selector(backTapped)
        backButton.isBordered = false
        OnboardingStyle.monoTitle(backButton, size: 12, color: OnboardingStyle.textSecondary)
        backButton.translatesAutoresizingMaskIntoConstraints = false

        continueButton.target = self
        continueButton.action = #selector(continueTapped)
        continueButton.keyEquivalent = "\r"

        view.addSubview(logoLabel)
        view.addSubview(progressLabel)
        view.addSubview(progressStack)
        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        view.addSubview(stepContainer)
        view.addSubview(footerRule)
        view.addSubview(backButton)
        view.addSubview(shortcutHint)
        view.addSubview(continueButton)

        NSLayoutConstraint.activate([
            logoLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 30),
            logoLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),

            progressLabel.centerYAnchor.constraint(equalTo: logoLabel.centerYAnchor),
            progressLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),

            progressStack.topAnchor.constraint(equalTo: logoLabel.bottomAnchor, constant: 18),
            progressStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            progressStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),

            titleLabel.topAnchor.constraint(equalTo: progressStack.bottomAnchor, constant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            stepContainer.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 26),
            stepContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            stepContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            stepContainer.bottomAnchor.constraint(equalTo: footerRule.topAnchor, constant: -20),

            footerRule.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerRule.heightAnchor.constraint(equalToConstant: 1),
            footerRule.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -76),

            backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            backButton.centerYAnchor.constraint(equalTo: continueButton.centerYAnchor),

            continueButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            continueButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -22),
            continueButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            continueButton.heightAnchor.constraint(equalToConstant: 36),

            shortcutHint.trailingAnchor.constraint(equalTo: continueButton.leadingAnchor, constant: -12),
            shortcutHint.centerYAnchor.constraint(equalTo: continueButton.centerYAnchor),
        ])
    }

    private func showStep(_ index: Int) {
        stepIndex = index
        currentStepView?.removeFromSuperview()
        let step: NSView
        let title: String
        switch index {
        case 0:
            title = "Choose your default agent"
            subtitleLabel.stringValue = "Seahelm works with CLI agents. Pick the one you use most — you can switch anytime. Detected agents are selected for hook install by default."
            continueButton.title = "Continue"
            backButton.isHidden = true
            step = agentStep
        case 1:
            title = "Make it feel like home"
            subtitleLabel.stringValue = "Choose a theme you'd like to stare at for hours."
            continueButton.title = "Continue"
            backButton.isHidden = false
            themeStep.configure(config: config)
            step = themeStep
        default:
            title = "Set up notifications"
            subtitleLabel.stringValue = "Seahelm notifies you when an agent finishes or needs help."
            continueButton.title = "Get started"
            backButton.isHidden = false
            permissionsStep.configure(config: config)
            step = permissionsStep
        }

        // Prompt-style title: cyan ❯ prefix.
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(string: "❯ ", attributes: [
            .font: AppFont.mono(size: 24, weight: .bold),
            .foregroundColor: OnboardingStyle.accent,
        ]))
        attributed.append(NSAttributedString(string: title, attributes: [
            .font: AppFont.mono(size: 24, weight: .bold),
            .foregroundColor: OnboardingStyle.textPrimary,
        ]))
        titleLabel.attributedStringValue = attributed

        progressLabel.stringValue = "[\(index + 1)/3]"
        for (i, seg) in progressSegments.enumerated() {
            seg.layer?.backgroundColor = (i <= index
                ? OnboardingStyle.accent
                : NSColor.white.withAlphaComponent(0.12)).cgColor
        }

        step.translatesAutoresizingMaskIntoConstraints = false
        stepContainer.addSubview(step)
        NSLayoutConstraint.activate([
            step.topAnchor.constraint(equalTo: stepContainer.topAnchor),
            step.leadingAnchor.constraint(equalTo: stepContainer.leadingAnchor),
            step.trailingAnchor.constraint(equalTo: stepContainer.trailingAnchor),
            step.bottomAnchor.constraint(equalTo: stepContainer.bottomAnchor),
        ])
        currentStepView = step

        // Gentle fade-in so step changes don't hard-swap. Skip when offscreen
        // (snapshot rendering) — the animator never runs without a runloop and
        // the step would stay at alpha 0.
        if view.window?.isVisible == true {
            step.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                step.animator().alphaValue = 1
            }
        } else {
            step.alphaValue = 1
        }
    }

    /// Design-iteration hook for offscreen snapshots (`--render-onboarding`).
    func debugShowStep(_ index: Int) {
        showStep(index)
    }

    @objc private func backTapped() {
        guard stepIndex > 0 else { return }
        applyCurrentStepToConfig()
        showStep(stepIndex - 1)
    }

    @objc private func continueTapped() {
        advance()
    }

    private func advance() {
        applyCurrentStepToConfig()
        if stepIndex == 0 {
            // Install hooks for checked agents before leaving step 1.
            let ids = agentStep.selectedHookAgentIds()
            OnboardingHookInstaller.install(agents: ids)
            config.enabledHookAgents = ids
            config.defaultAgent = agentStep.selectedDefaultAgent().rawValue
            config.agentYolo = agentStep.isYoloEnabled
            config.save()
        }
        if stepIndex >= 2 {
            finish()
            return
        }
        showStep(stepIndex + 1)
    }

    private func applyCurrentStepToConfig() {
        switch stepIndex {
        case 0:
            config.defaultAgent = agentStep.selectedDefaultAgent().rawValue
            config.agentYolo = agentStep.isYoloEnabled
            config.enabledHookAgents = agentStep.selectedHookAgentIds()
        case 1:
            config.themeMode = themeStep.selectedThemeMode().rawValue
            ThemeMode.applyAppearance(themeStep.selectedThemeMode())
        case 2:
            config.notificationSound = permissionsStep.selectedSoundPreference()
            NotificationManager.shared.soundPreference = config.notificationSound
        default:
            break
        }
    }

    private func finish() {
        applyCurrentStepToConfig()
        config.onboardingCompleted = true
        config.save()
        onFinished?(config)
    }
}

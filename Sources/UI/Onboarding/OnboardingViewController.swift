import AppKit

/// Hosts the 3-step onboarding flow with progress and navigation.
final class OnboardingViewController: NSViewController {
    var onFinished: ((Config) -> Void)?

    private var config: Config
    private var stepIndex = 0

    private let margin: CGFloat = 48

    private let logoGlyph = OnboardingStyle.monoLabel("❯", size: 17, weight: .bold, color: OnboardingStyle.accent)
    private let logoName = OnboardingStyle.label("Seahelm", size: 16, weight: .semibold)
    private let progressStack = NSStackView()
    private let progressLabel = OnboardingStyle.label("1 / 3", size: 12, color: OnboardingStyle.textFaint)
    private var progressSegments: [NSView] = []
    private var progressWidths: [NSLayoutConstraint] = []

    private let eyebrowLabel = OnboardingStyle.label("", size: 11.5, weight: .semibold,
                                                     color: OnboardingStyle.textFaint)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let stepContainer = NSView()

    private let footerRule = NSView()
    private let backButton = NSButton(title: "‹  Back", target: nil, action: nil)
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
        view = NSView(frame: NSRect(origin: .zero, size: OnboardingWindowController.windowSize))
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
        // Wordmark: accent prompt glyph + product name.
        let logoStack = NSStackView(views: [logoGlyph, logoName])
        logoStack.orientation = .horizontal
        logoStack.spacing = 7
        logoStack.alignment = .firstBaseline
        logoStack.translatesAutoresizingMaskIntoConstraints = false

        // Segmented progress, left-aligned: the active segment stretches and
        // darkens; the rest stay short and faint. "1 / 3" sits alongside.
        progressStack.orientation = .horizontal
        progressStack.spacing = 8
        progressStack.alignment = .centerY
        progressStack.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<3 {
            let seg = NSView()
            seg.wantsLayer = true
            seg.layer?.cornerRadius = 1.5
            seg.translatesAutoresizingMaskIntoConstraints = false
            seg.heightAnchor.constraint(equalToConstant: 3).isActive = true
            let width = seg.widthAnchor.constraint(equalToConstant: 26)
            width.isActive = true
            progressWidths.append(width)
            progressSegments.append(seg)
            progressStack.addArrangedSubview(seg)
        }
        progressStack.setCustomSpacing(14, after: progressSegments[2])
        progressStack.addArrangedSubview(progressLabel)

        eyebrowLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 32, weight: .bold)
        titleLabel.textColor = OnboardingStyle.textPrimary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = NSFont.systemFont(ofSize: 14.5)
        subtitleLabel.textColor = OnboardingStyle.textSecondary
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        stepContainer.translatesAutoresizingMaskIntoConstraints = false

        footerRule.wantsLayer = true
        footerRule.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        footerRule.translatesAutoresizingMaskIntoConstraints = false

        backButton.bezelStyle = .rounded
        backButton.controlSize = .large
        backButton.target = self
        backButton.action = #selector(backTapped)
        OnboardingStyle.systemTitle(backButton, size: 13, color: OnboardingStyle.textPrimary)
        backButton.translatesAutoresizingMaskIntoConstraints = false

        continueButton.target = self
        continueButton.action = #selector(continueTapped)
        continueButton.keyEquivalent = "\r"

        view.addSubview(logoStack)
        view.addSubview(progressStack)
        view.addSubview(eyebrowLabel)
        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        view.addSubview(stepContainer)
        view.addSubview(footerRule)
        view.addSubview(backButton)
        view.addSubview(continueButton)

        NSLayoutConstraint.activate([
            logoStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 34),
            logoStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),

            progressStack.topAnchor.constraint(equalTo: logoStack.bottomAnchor, constant: 26),
            progressStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),

            eyebrowLabel.topAnchor.constraint(equalTo: progressStack.bottomAnchor, constant: 30),
            eyebrowLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),

            titleLabel.topAnchor.constraint(equalTo: eyebrowLabel.bottomAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            stepContainer.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 28),
            stepContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            stepContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            stepContainer.bottomAnchor.constraint(equalTo: footerRule.topAnchor, constant: -20),

            footerRule.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            footerRule.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            footerRule.heightAnchor.constraint(equalToConstant: 1),
            footerRule.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -82),

            continueButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            continueButton.centerYAnchor.constraint(equalTo: view.bottomAnchor, constant: -41),
            continueButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            continueButton.heightAnchor.constraint(equalToConstant: 40),

            backButton.trailingAnchor.constraint(equalTo: continueButton.leadingAnchor, constant: -10),
            backButton.centerYAnchor.constraint(equalTo: continueButton.centerYAnchor),
            backButton.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    private func showStep(_ index: Int) {
        stepIndex = index
        currentStepView?.removeFromSuperview()
        let step: NSView
        switch index {
        case 0:
            eyebrowLabel.stringValue = "WELCOME TO SEAHELM"
            titleLabel.stringValue = "Choose your default agent"
            subtitleLabel.stringValue = "Seahelm works with CLI agents. Pick the one you use most — you can switch anytime."
            continueButton.text = "Continue"
            backButton.isHidden = true
            step = agentStep
        case 1:
            eyebrowLabel.stringValue = ""
            titleLabel.stringValue = "Make it feel like home"
            subtitleLabel.stringValue = "Choose a theme you'd like to stare at for hours."
            continueButton.text = "Continue"
            backButton.isHidden = false
            themeStep.configure(config: config)
            step = themeStep
        default:
            eyebrowLabel.stringValue = ""
            titleLabel.stringValue = "Set up notifications"
            subtitleLabel.stringValue = "Seahelm notifies you when an agent finishes or needs help."
            continueButton.text = "Get started"
            backButton.isHidden = false
            permissionsStep.configure(config: config)
            step = permissionsStep
        }
        eyebrowLabel.attributedStringValue = NSAttributedString(
            string: eyebrowLabel.stringValue,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: OnboardingStyle.textFaint,
                .kern: 1.6,
            ]
        )

        progressLabel.stringValue = "\(index + 1) / 3"
        for (i, seg) in progressSegments.enumerated() {
            let active = i == index
            let done = i < index
            seg.layer?.backgroundColor = (active
                ? NSColor.black.withAlphaComponent(0.85)
                : NSColor.black.withAlphaComponent(done ? 0.45 : 0.14)).cgColor
            progressWidths[i].constant = active ? 44 : 26
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
        // Synchronous: bootstrapMainApp -> MainWindowController does its own
        // Config.load() right after this, and a debounced write would lose the race.
        config.saveNow()
        onFinished?(config)
    }
}

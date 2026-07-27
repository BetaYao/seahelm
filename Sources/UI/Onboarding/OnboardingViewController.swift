import AppKit

/// Hosts the onboarding flow: a welcome, three setup steps, and a receipt.
///
/// The old wizard opened straight on "choose your default agent" and ended the
/// moment the last choice was made, so a new user never learned what Seahelm is
/// and never saw what it had installed on their behalf. The flow is now
/// bookended: `welcome` explains the model, `ready` reports the outcome.
final class OnboardingViewController: NSViewController {
    var onFinished: ((Config) -> Void)?

    private enum Step: Int, CaseIterable {
        case welcome, agent, appearance, permissions, ready

        var eyebrow: String {
            switch self {
            case .welcome: return "WELCOME ABOARD"
            case .agent: return "STEP 1 · YOUR AGENT"
            case .appearance: return "STEP 2 · APPEARANCE"
            case .permissions: return "STEP 3 · PERMISSIONS"
            case .ready: return "ALL SET"
            }
        }

        var title: String {
            switch self {
            case .welcome: return "Seahelm steers your agent fleet"
            case .agent: return "Which agent do you reach for?"
            case .appearance: return "Pick your light"
            case .permissions: return "Two permissions, both optional"
            case .ready: return "You're ready to sail"
            }
        }

        var subtitle: String {
            switch self {
            case .welcome:
                return "A terminal built for the way agents are actually used: several at once, "
                    + "each in its own worktree, all of them watched."
            case .agent:
                return "Seahelm launches this one in every new cabin, and wires it to report its "
                    + "status back. You can still run anything else in any pane."
            case .appearance:
                return "The wizard re-themes as you choose — what you see here is what the app looks like."
            case .permissions:
                return "Grant them now or skip and do it later. Seahelm runs either way; "
                    + "you just lose the feature each one powers."
            case .ready:
                return "Here's what Seahelm set up. All of it is reversible in Settings."
            }
        }

        var callToAction: String {
            switch self {
            case .welcome: return "Let's set up"
            case .ready: return "Enter the helm"
            default: return "Continue"
            }
        }
    }

    private var config: Config
    private var step: Step = .welcome
    private var installSteps: [OnboardingHookInstaller.InstallStep] = []

    private let margin: CGFloat = 46

    private let logoGlyph = OnboardingStyle.monoLabel("❯", size: 16, weight: .bold,
                                                      color: OnboardingStyle.accent)
    private let logoName = OnboardingStyle.label("Seahelm", size: 15, weight: .semibold)
    private let progressStack = NSStackView()
    private var progressSegments: [NSView] = []
    private var progressWidths: [NSLayoutConstraint] = []

    private let eyebrowLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let stepContainer = NSView()

    private let footerRule = NSView()
    private let backButton = OnboardingSecondaryButton(text: "Back", symbol: "chevron.left")
    private let continueButton = OnboardingPrimaryButton(frame: .zero)

    private lazy var welcomeStep = OnboardingWelcomeStepView()
    private lazy var agentStep = OnboardingAgentStepView()
    private lazy var themeStep = OnboardingThemeStepView()
    private lazy var permissionsStep = OnboardingPermissionsStepView()
    private lazy var readyStep = OnboardingReadyStepView()

    private var currentStepView: NSView?
    private var keyMonitor: Any?

    /// Snapshot rendering has no window behind it to blur, so the glass reads as
    /// nothing at all. Offscreen renders paint the flat equivalent instead.
    var usesOpaqueBackground = false {
        didSet { applyTheme() }
    }

    init(config: Config) {
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// Root view that forwards appearance flips — `NSViewController` has no
    /// `viewDidChangeEffectiveAppearance` of its own.
    private final class RootView: NSView {
        var onAppearanceChange: (() -> Void)?
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            onAppearanceChange?()
        }
    }

    override func loadView() {
        let root = RootView(frame: NSRect(origin: .zero, size: OnboardingWindowController.windowSize))
        root.wantsLayer = true
        root.onAppearanceChange = { [weak self] in self?.applyTheme() }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildChrome()
        // Apply the stored appearance before the first layout so the wizard never
        // flashes the system theme on launch.
        ThemeMode.applyAppearance(ThemeMode(rawValue: config.themeMode) ?? .system)
        agentStep.configure(config: config)
        themeStep.configure(config: config)
        themeStep.onThemeChanged = { [weak self] _ in self?.applyTheme() }
        permissionsStep.configure(config: config)
        show(.welcome)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // ⌘↩ advances; ⌘[ / ← goes back. Escape deliberately does nothing —
        // there is no "cancel" for first-run setup.
        if event.modifierFlags.contains(.command), event.keyCode == 36 /* Return */ {
            advance()
            return nil
        }
        if event.modifierFlags.contains(.command), event.keyCode == 33 /* [ */ {
            goBack()
            return nil
        }
        return event
    }

    // MARK: - Chrome

    private func buildChrome() {
        let logoStack = NSStackView(views: [logoGlyph, logoName])
        logoStack.orientation = .horizontal
        logoStack.spacing = 7
        logoStack.alignment = .firstBaseline
        logoStack.translatesAutoresizingMaskIntoConstraints = false

        // Segmented rail: the active segment stretches and takes the accent,
        // completed ones stay solid but short, upcoming ones fade out.
        progressStack.orientation = .horizontal
        progressStack.spacing = 6
        progressStack.alignment = .centerY
        progressStack.translatesAutoresizingMaskIntoConstraints = false
        for _ in Step.allCases {
            let seg = NSView()
            seg.wantsLayer = true
            seg.layer?.cornerRadius = 1.5
            seg.translatesAutoresizingMaskIntoConstraints = false
            seg.heightAnchor.constraint(equalToConstant: 3).isActive = true
            let width = seg.widthAnchor.constraint(equalToConstant: 22)
            width.isActive = true
            progressWidths.append(width)
            progressSegments.append(seg)
            progressStack.addArrangedSubview(seg)
        }

        eyebrowLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 30, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.systemFont(ofSize: 14)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        stepContainer.translatesAutoresizingMaskIntoConstraints = false
        footerRule.wantsLayer = true
        footerRule.translatesAutoresizingMaskIntoConstraints = false

        backButton.target = self
        backButton.action = #selector(backTapped)

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
            logoStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 32),
            logoStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),

            progressStack.centerYAnchor.constraint(equalTo: logoStack.centerYAnchor),
            progressStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            eyebrowLabel.topAnchor.constraint(equalTo: logoStack.bottomAnchor, constant: 34),
            eyebrowLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),

            titleLabel.topAnchor.constraint(equalTo: eyebrowLabel.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            // Prose is easier to scan short of full width.
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor,
                                                    constant: -margin - 60),

            stepContainer.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 26),
            stepContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            stepContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            stepContainer.bottomAnchor.constraint(equalTo: footerRule.topAnchor, constant: -20),

            footerRule.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            footerRule.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            footerRule.heightAnchor.constraint(equalToConstant: 1),
            footerRule.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -78),

            continueButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            continueButton.centerYAnchor.constraint(equalTo: view.bottomAnchor, constant: -39),
            continueButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 165),
            continueButton.heightAnchor.constraint(equalToConstant: 38),

            backButton.trailingAnchor.constraint(equalTo: continueButton.leadingAnchor, constant: -10),
            backButton.centerYAnchor.constraint(equalTo: continueButton.centerYAnchor),
        ])

        applyTheme()
    }

    /// Re-resolve every color the chrome caches. Dynamic `NSColor`s in text
    /// fields re-resolve on their own; layer colors and attributed strings do not.
    private func applyTheme() {
        view.layer?.backgroundColor = usesOpaqueBackground
            ? view.resolvedCGColor(Theme.background).copy(alpha: 1)
            : view.resolvedCGColor(.clear)
        logoGlyph.textColor = OnboardingStyle.accent
        logoName.textColor = OnboardingStyle.textPrimary
        titleLabel.textColor = OnboardingStyle.textPrimary
        subtitleLabel.textColor = OnboardingStyle.textSecondary
        footerRule.layer?.backgroundColor = view.resolvedCGColor(OnboardingStyle.stroke)
        eyebrowLabel.attributedStringValue = OnboardingStyle.eyebrow(step.eyebrow)
        refreshProgress()
        view.onboardingApplyThemeRecursively()
    }

    private func refreshProgress() {
        for (i, seg) in progressSegments.enumerated() {
            let active = i == step.rawValue
            let done = i < step.rawValue
            let color: NSColor = active
                ? OnboardingStyle.accent
                : (done ? OnboardingStyle.textSecondary : SemanticColors.lineAlpha45)
            seg.layer?.backgroundColor = view.resolvedCGColor(color)
            progressWidths[i].constant = active ? 30 : 16
        }
    }

    // MARK: - Steps

    private func show(_ next: Step) {
        step = next
        currentStepView?.removeFromSuperview()

        let stepView: NSView
        switch next {
        case .welcome:
            stepView = welcomeStep
        case .agent:
            agentStep.configure(config: config)
            stepView = agentStep
        case .appearance:
            themeStep.configure(config: config)
            stepView = themeStep
        case .permissions:
            permissionsStep.configure(config: config)
            stepView = permissionsStep
        case .ready:
            readyStep.configure(config: config, installSteps: installSteps)
            stepView = readyStep
        }

        titleLabel.stringValue = next.title
        subtitleLabel.stringValue = next.subtitle
        continueButton.text = next.callToAction
        backButton.isHidden = next == .welcome
        applyTheme()

        stepView.translatesAutoresizingMaskIntoConstraints = false
        stepContainer.addSubview(stepView)
        NSLayoutConstraint.activate([
            stepView.topAnchor.constraint(equalTo: stepContainer.topAnchor),
            stepView.leadingAnchor.constraint(equalTo: stepContainer.leadingAnchor),
            stepView.trailingAnchor.constraint(equalTo: stepContainer.trailingAnchor),
            stepView.bottomAnchor.constraint(equalTo: stepContainer.bottomAnchor),
        ])
        currentStepView = stepView

        // Gentle fade so step changes don't hard-swap. Skipped when offscreen
        // (snapshot rendering) — the animator never runs without a runloop and
        // the step would stay at alpha 0.
        if view.window?.isVisible == true {
            stepView.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                stepView.animator().alphaValue = 1
            }
        } else {
            stepView.alphaValue = 1
        }
    }

    /// Design-iteration hook for offscreen snapshots (`--render-onboarding`).
    func debugShowStep(_ index: Int) {
        guard let target = Step(rawValue: index) else { return }
        // The receipt is empty before a real install run; fake one so the
        // snapshot shows the layout it will actually have.
        if target == .ready, installSteps.isEmpty {
            installSteps = [
                .init(name: "Hook bridge", detail: "~/.local/bin/seahelm-hook", ok: true),
                .init(name: "seahelm CLI", detail: "~/.local/bin/seahelm", ok: true),
                .init(name: "Claude Code hooks", detail: "~/.claude/settings.json", ok: true),
            ]
        }
        show(target)
    }

    @objc private func backTapped() { goBack() }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        captureCurrentStep()
        show(previous)
    }

    @objc private func continueTapped() { advance() }

    private func advance() {
        captureCurrentStep()
        if step == .agent {
            // Install before leaving the step, so the receipt on the last step
            // reflects a run that has actually happened.
            installSteps = OnboardingHookInstaller.install(agents: agentStep.selectedHookAgentIds())
            config.save()
        }
        if step == .ready {
            finish()
            return
        }
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        show(next)
    }

    /// Fold whatever the visible step collected back into `config`.
    private func captureCurrentStep() {
        switch step {
        case .welcome, .ready:
            break
        case .agent:
            config.defaultAgent = agentStep.selectedDefaultAgent().rawValue
            config.agentYolo = agentStep.isYoloEnabled
            config.enabledHookAgents = agentStep.selectedHookAgentIds()
        case .appearance:
            config.themeMode = themeStep.selectedThemeMode().rawValue
            ThemeMode.applyAppearance(themeStep.selectedThemeMode())
        case .permissions:
            config.notificationSound = permissionsStep.selectedSoundPreference()
            NotificationManager.shared.soundPreference = config.notificationSound
        }
    }

    private func finish() {
        config.onboardingCompleted = true
        // Synchronous: bootstrapMainApp -> MainWindowController does its own
        // Config.load() right after this, and a debounced write would lose the race.
        config.saveNow()
        onFinished?(config)
    }
}

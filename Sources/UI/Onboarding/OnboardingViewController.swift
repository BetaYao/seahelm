import AppKit

/// Hosts the 3-step onboarding flow with progress and navigation.
final class OnboardingViewController: NSViewController {
    var onFinished: ((Config) -> Void)?

    private var config: Config
    private var stepIndex = 0

    private let logoLabel = NSTextField(labelWithString: "Seahelm")
    private let progressLabel = NSTextField(labelWithString: "1 / 3")
    private let progressTrack = NSView()
    private let progressFill = NSView()
    private var progressFillWidth: NSLayoutConstraint?

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let stepContainer = NSView()

    private let backButton = NSButton(title: "< Back", target: nil, action: nil)
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)

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
        view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 640))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
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
        logoLabel.font = .systemFont(ofSize: 18, weight: .bold)
        logoLabel.translatesAutoresizingMaskIntoConstraints = false

        progressLabel.font = .systemFont(ofSize: 12, weight: .medium)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.translatesAutoresizingMaskIntoConstraints = false

        progressTrack.wantsLayer = true
        progressTrack.layer?.cornerRadius = 2
        progressTrack.layer?.backgroundColor = NSColor.separatorColor.cgColor
        progressTrack.translatesAutoresizingMaskIntoConstraints = false

        progressFill.wantsLayer = true
        progressFill.layer?.cornerRadius = 2
        progressFill.layer?.backgroundColor = NSColor.labelColor.cgColor
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)

        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 14)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        stepContainer.translatesAutoresizingMaskIntoConstraints = false

        backButton.target = self
        backButton.action = #selector(backTapped)
        backButton.isBordered = false
        backButton.font = .systemFont(ofSize: 13, weight: .medium)
        backButton.translatesAutoresizingMaskIntoConstraints = false

        continueButton.target = self
        continueButton.action = #selector(continueTapped)
        continueButton.bezelStyle = .rounded
        if #available(macOS 14.0, *) {
            continueButton.controlSize = .large
        }
        continueButton.keyEquivalent = "\r"
        continueButton.keyEquivalentModifierMask = .command
        continueButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(logoLabel)
        view.addSubview(progressLabel)
        view.addSubview(progressTrack)
        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        view.addSubview(stepContainer)
        view.addSubview(backButton)
        view.addSubview(continueButton)

        let fillW = progressFill.widthAnchor.constraint(equalToConstant: 80)
        progressFillWidth = fillW

        NSLayoutConstraint.activate([
            logoLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            logoLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),

            progressLabel.centerYAnchor.constraint(equalTo: logoLabel.centerYAnchor),
            progressLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),

            progressTrack.topAnchor.constraint(equalTo: logoLabel.bottomAnchor, constant: 16),
            progressTrack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            progressTrack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),
            progressTrack.heightAnchor.constraint(equalToConstant: 4),

            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            fillW,

            titleLabel.topAnchor.constraint(equalTo: progressTrack.bottomAnchor, constant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            stepContainer.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 24),
            stepContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            stepContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),
            stepContainer.bottomAnchor.constraint(equalTo: continueButton.topAnchor, constant: -20),

            backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            backButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -28),

            continueButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),
            continueButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            continueButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
    }

    private func showStep(_ index: Int) {
        stepIndex = index
        currentStepView?.removeFromSuperview()
        let step: NSView
        switch index {
        case 0:
            titleLabel.stringValue = "Choose your default agent"
            subtitleLabel.stringValue = "Seahelm works with CLI agents. Pick the one you use most — you can switch anytime. Detected agents are selected for hook install by default."
            continueButton.title = "Continue ⌘↩"
            backButton.isHidden = true
            step = agentStep
        case 1:
            titleLabel.stringValue = "Make it feel like home"
            subtitleLabel.stringValue = "Choose a theme you'd like to stare at for hours."
            continueButton.title = "Continue ⌘↩"
            backButton.isHidden = false
            themeStep.configure(config: config)
            step = themeStep
        default:
            titleLabel.stringValue = "Set up notifications"
            subtitleLabel.stringValue = "Seahelm notifies you when an agent finishes or needs help."
            continueButton.title = "Get started ⌘↩"
            backButton.isHidden = false
            permissionsStep.configure(config: config)
            step = permissionsStep
        }
        progressLabel.stringValue = "\(index + 1) / 3"
        progressFillWidth?.constant = CGFloat(index + 1) / 3.0 * (720 - 72)
        step.translatesAutoresizingMaskIntoConstraints = false
        stepContainer.addSubview(step)
        NSLayoutConstraint.activate([
            step.topAnchor.constraint(equalTo: stepContainer.topAnchor),
            step.leadingAnchor.constraint(equalTo: stepContainer.leadingAnchor),
            step.trailingAnchor.constraint(equalTo: stepContainer.trailingAnchor),
            step.bottomAnchor.constraint(equalTo: stepContainer.bottomAnchor),
        ])
        currentStepView = step
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

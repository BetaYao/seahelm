import AppKit
import UserNotifications

/// Step 4: the two OS permissions Seahelm needs, each with a live status.
///
/// Both grants happen outside the app (a system prompt, or System Settings), so
/// the old static one-shot labels were routinely stale — you'd flip the switch
/// in Settings, come back, and the wizard still said "Not enabled". Each row now
/// re-checks on a timer and whenever the app regains focus, and says what breaks
/// if you skip it.
final class OnboardingPermissionsStepView: NSView {
    private let notifRow = PermissionRow(
        symbol: "bell.badge.fill",
        title: "Notifications",
        detail: "How Seahelm tells you an agent finished, stalled, or needs an answer. "
            + "Without it, you have to watch the window."
    )
    private let axRow = PermissionRow(
        symbol: "accessibility",
        title: "Accessibility",
        detail: "Lets Ctrl-double-tap summon the Island while Seahelm is in the background. "
            + "Optional — everything else works without it."
    )

    private let soundPanel = OnboardingPanel()
    private let soundLabel = OnboardingStyle.label("Alert sound", size: 13, weight: .semibold)
    private let soundSubtitle = OnboardingStyle.label(
        "Played with each desktop notification.", size: 11.5, color: OnboardingStyle.textSecondary
    )
    private let soundPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let testButton = OnboardingSecondaryButton(text: "Play a test", symbol: "speaker.wave.2.fill")

    private var pollTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { pollTimer?.invalidate() }

    func configure(config: Config) {
        selectSound(config.notificationSound)
        refreshStatuses()
    }

    func selectedSoundPreference() -> String {
        switch soundPopup.indexOfSelectedItem {
        case 1: return "defaultCritical"
        case 2: return "none"
        default: return "default"
        }
    }

    private func selectSound(_ pref: String) {
        switch pref {
        case "defaultCritical": soundPopup.selectItem(at: 1)
        case "none": soundPopup.selectItem(at: 2)
        default: soundPopup.selectItem(at: 0)
        }
    }

    // MARK: - Layout

    private func setup() {
        soundPanel.showsSelectionGlow = false

        notifRow.primary.text = "Allow notifications"
        notifRow.primary.target = self
        notifRow.primary.action = #selector(requestNotif)
        notifRow.secondary.target = self
        notifRow.secondary.action = #selector(openNotifSettings)

        axRow.primary.text = "Enable Accessibility"
        axRow.primary.target = self
        axRow.primary.action = #selector(enableAx)
        axRow.secondary.target = self
        axRow.secondary.action = #selector(openAxSettings)

        soundPopup.addItems(withTitles: ["System default", "Critical alert", "Silent"])
        soundPopup.controlSize = .regular
        soundPopup.target = self
        soundPopup.action = #selector(soundChanged)
        soundPopup.translatesAutoresizingMaskIntoConstraints = false

        testButton.target = self
        testButton.action = #selector(sendTest)

        for v in [soundLabel, soundSubtitle, soundPopup, testButton] as [NSView] {
            soundPanel.addSubview(v)
        }

        addSubview(notifRow)
        addSubview(soundPanel)
        addSubview(axRow)

        NSLayoutConstraint.activate([
            notifRow.topAnchor.constraint(equalTo: topAnchor),
            notifRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            notifRow.trailingAnchor.constraint(equalTo: trailingAnchor),

            soundPanel.topAnchor.constraint(equalTo: notifRow.bottomAnchor, constant: 12),
            soundPanel.leadingAnchor.constraint(equalTo: leadingAnchor),
            soundPanel.trailingAnchor.constraint(equalTo: trailingAnchor),

            soundLabel.topAnchor.constraint(equalTo: soundPanel.topAnchor, constant: 14),
            soundLabel.leadingAnchor.constraint(equalTo: soundPanel.leadingAnchor, constant: 16),
            soundSubtitle.topAnchor.constraint(equalTo: soundLabel.bottomAnchor, constant: 2),
            soundSubtitle.leadingAnchor.constraint(equalTo: soundLabel.leadingAnchor),
            soundPanel.bottomAnchor.constraint(equalTo: soundSubtitle.bottomAnchor, constant: 14),

            testButton.trailingAnchor.constraint(equalTo: soundPanel.trailingAnchor, constant: -16),
            testButton.centerYAnchor.constraint(equalTo: soundPanel.centerYAnchor),
            soundPopup.trailingAnchor.constraint(equalTo: testButton.leadingAnchor, constant: -10),
            soundPopup.centerYAnchor.constraint(equalTo: soundPanel.centerYAnchor),
            soundPopup.widthAnchor.constraint(equalToConstant: 160),
            soundPopup.leadingAnchor.constraint(greaterThanOrEqualTo: soundLabel.trailingAnchor, constant: 16),

            axRow.topAnchor.constraint(equalTo: soundPanel.bottomAnchor, constant: 20),
            axRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            axRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            axRow.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    // MARK: - Live status

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pollTimer?.invalidate()
        guard window != nil else { return }
        refreshStatuses()
        // Grants land while we're in the background; 1s is imperceptible cost
        // and makes the pills correct by the time the user looks back.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshStatuses()
        }
    }

    private func refreshStatuses() {
        let trusted = NotificationManager.isAccessibilityTrusted
        axRow.status.state = trusted ? .ok("Enabled") : .pending("Not enabled")
        axRow.primary.isEnabled = !trusted

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch status {
                case .authorized, .provisional, .ephemeral:
                    self.notifRow.status.state = .ok("Allowed")
                    self.notifRow.primary.isEnabled = false
                case .denied:
                    self.notifRow.status.state = .failed("Denied — turn it on in System Settings")
                    self.notifRow.primary.isEnabled = false
                default:
                    self.notifRow.status.state = .pending("Not asked yet")
                    self.notifRow.primary.isEnabled = true
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func openNotifSettings() {
        NotificationManager.openNotificationSystemSettings()
    }

    @objc private func requestNotif() {
        NotificationManager.shared.requestPermission { [weak self] _ in
            DispatchQueue.main.async { self?.refreshStatuses() }
        }
    }

    @objc private func soundChanged() {
        NotificationManager.shared.soundPreference = selectedSoundPreference()
    }

    @objc private func sendTest() {
        NotificationManager.shared.soundPreference = selectedSoundPreference()
        NotificationManager.shared.sendTestNotification()
    }

    @objc private func enableAx() {
        _ = NotificationManager.requestAccessibilityPermission()
        refreshStatuses()
    }

    @objc private func openAxSettings() {
        NotificationManager.openAccessibilitySystemSettings()
    }
}

/// One permission: icon, name + live status pill, why-you-want-it copy, and the
/// two ways to grant it (in-app prompt, or straight to System Settings).
private final class PermissionRow: NSView {
    let status = OnboardingStatusPill()
    let primary = OnboardingSecondaryButton(text: "")
    let secondary = OnboardingSecondaryButton(text: "System Settings", symbol: "arrow.up.forward.app")

    private let panel = OnboardingPanel()

    init(symbol: String, title: String, detail: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        panel.showsSelectionGlow = false

        let icon = OnboardingIconTile(symbol: symbol, side: 34, pointSize: 15)
        let titleLabel = OnboardingStyle.label(title, size: 13.5, weight: .semibold)
        let detailLabel = OnboardingStyle.wrappingLabel(detail, size: 12)

        addSubview(panel)
        for v in [icon, titleLabel, status, detailLabel, primary, secondary] as [NSView] {
            panel.addSubview(v)
        }

        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),

            icon.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: panel.topAnchor, constant: 15),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 13),
            titleLabel.topAnchor.constraint(equalTo: panel.topAnchor, constant: 15),
            status.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            status.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -16),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            detailLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),

            primary.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            primary.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 12),
            secondary.leadingAnchor.constraint(equalTo: primary.trailingAnchor, constant: 8),
            secondary.centerYAnchor.constraint(equalTo: primary.centerYAnchor),
            panel.bottomAnchor.constraint(equalTo: primary.bottomAnchor, constant: 15),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

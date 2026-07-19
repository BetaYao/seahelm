import AppKit

/// Step 3: notifications + Accessibility.
final class OnboardingPermissionsStepView: NSView {
    private let notifBox = OnboardingPanel()
    private let notifIcon = OnboardingPermissionsStepView.makeIconTile(symbol: "bell.badge.fill")
    private let notifTitle = OnboardingStyle.label("Allow Seahelm to send notifications", size: 13, weight: .semibold)
    private let notifSubtitle = OnboardingStyle.label("Click Allow in the macOS dialog.", size: 11, color: OnboardingStyle.textSecondary)
    private let openNotifButton = NSButton(title: "Open System Settings", target: nil, action: nil)
    private let requestNotifButton = NSButton(title: "Request permission", target: nil, action: nil)

    private let soundLabel = OnboardingStyle.label("Notification sound", size: 12, weight: .medium)
    private let soundPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let testButton = NSButton(title: "Send test notification", target: nil, action: nil)

    private let axBox = OnboardingPanel()
    private let axIcon = OnboardingPermissionsStepView.makeIconTile(symbol: "accessibility")
    private let axTitle = OnboardingStyle.label("Accessibility (Island hotkey)", size: 13, weight: .semibold)
    private let axSubtitle = OnboardingStyle.wrappingLabel(
        "Needed for Ctrl-double-tap to summon the Island while Seahelm is in the background.",
        size: 11
    )
    private let axStatus = NSTextField(labelWithString: "")
    private let axButton = NSButton(title: "Enable Accessibility", target: nil, action: nil)
    private let axSettingsButton = NSButton(title: "Open System Settings", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(config: Config) {
        selectSound(config.notificationSound)
        refreshAxStatus()
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

    /// Cyan-tinted rounded tile holding an SF Symbol.
    private static func makeIconTile(symbol: String) -> NSView {
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 7
        tile.layer?.backgroundColor = OnboardingStyle.accent.withAlphaComponent(0.16).cgColor
        tile.translatesAutoresizingMaskIntoConstraints = false

        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        image.contentTintColor = OnboardingStyle.accent
        image.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(image)

        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 32),
            tile.heightAnchor.constraint(equalToConstant: 32),
            image.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        return tile
    }

    private func setup() {
        openNotifButton.bezelStyle = .rounded
        openNotifButton.target = self
        openNotifButton.action = #selector(openNotifSettings)

        requestNotifButton.bezelStyle = .rounded
        requestNotifButton.target = self
        requestNotifButton.action = #selector(requestNotif)

        soundPopup.addItems(withTitles: ["System default", "Critical", "None"])
        soundPopup.target = self
        soundPopup.action = #selector(soundChanged)

        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(sendTest)

        axStatus.font = AppFont.mono(size: 11, weight: .medium)

        axButton.bezelStyle = .rounded
        axButton.target = self
        axButton.action = #selector(enableAx)

        axSettingsButton.bezelStyle = .rounded
        axSettingsButton.target = self
        axSettingsButton.action = #selector(openAxSettings)

        for v in [notifIcon, notifTitle, notifSubtitle, openNotifButton, requestNotifButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            notifBox.addSubview(v)
        }
        for v in [soundLabel, soundPopup, testButton, axBox] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        addSubview(notifBox)

        for v in [axIcon, axTitle, axSubtitle, axStatus, axButton, axSettingsButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            axBox.addSubview(v)
        }

        NSLayoutConstraint.activate([
            notifBox.topAnchor.constraint(equalTo: topAnchor),
            notifBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            notifBox.trailingAnchor.constraint(equalTo: trailingAnchor),

            notifIcon.leadingAnchor.constraint(equalTo: notifBox.leadingAnchor, constant: 14),
            notifIcon.centerYAnchor.constraint(equalTo: notifBox.centerYAnchor),

            notifTitle.topAnchor.constraint(equalTo: notifBox.topAnchor, constant: 14),
            notifTitle.leadingAnchor.constraint(equalTo: notifIcon.trailingAnchor, constant: 12),
            notifSubtitle.topAnchor.constraint(equalTo: notifTitle.bottomAnchor, constant: 3),
            notifSubtitle.leadingAnchor.constraint(equalTo: notifTitle.leadingAnchor),
            requestNotifButton.trailingAnchor.constraint(equalTo: notifBox.trailingAnchor, constant: -14),
            requestNotifButton.centerYAnchor.constraint(equalTo: notifBox.centerYAnchor),
            openNotifButton.trailingAnchor.constraint(equalTo: requestNotifButton.leadingAnchor, constant: -8),
            openNotifButton.centerYAnchor.constraint(equalTo: notifBox.centerYAnchor),
            notifBox.bottomAnchor.constraint(equalTo: notifSubtitle.bottomAnchor, constant: 14),

            soundLabel.topAnchor.constraint(equalTo: notifBox.bottomAnchor, constant: 22),
            soundLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            soundPopup.leadingAnchor.constraint(equalTo: leadingAnchor),
            soundPopup.topAnchor.constraint(equalTo: soundLabel.bottomAnchor, constant: 8),
            testButton.leadingAnchor.constraint(equalTo: soundPopup.trailingAnchor, constant: 12),
            testButton.centerYAnchor.constraint(equalTo: soundPopup.centerYAnchor),

            axBox.topAnchor.constraint(equalTo: soundPopup.bottomAnchor, constant: 22),
            axBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            axBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            axBox.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            axIcon.leadingAnchor.constraint(equalTo: axBox.leadingAnchor, constant: 14),
            axIcon.topAnchor.constraint(equalTo: axBox.topAnchor, constant: 14),

            axTitle.topAnchor.constraint(equalTo: axBox.topAnchor, constant: 14),
            axTitle.leadingAnchor.constraint(equalTo: axIcon.trailingAnchor, constant: 12),
            axSubtitle.topAnchor.constraint(equalTo: axTitle.bottomAnchor, constant: 3),
            axSubtitle.leadingAnchor.constraint(equalTo: axTitle.leadingAnchor),
            axSubtitle.trailingAnchor.constraint(equalTo: axBox.trailingAnchor, constant: -14),
            axStatus.topAnchor.constraint(equalTo: axSubtitle.bottomAnchor, constant: 8),
            axStatus.leadingAnchor.constraint(equalTo: axTitle.leadingAnchor),
            axButton.topAnchor.constraint(equalTo: axStatus.bottomAnchor, constant: 10),
            axButton.leadingAnchor.constraint(equalTo: axTitle.leadingAnchor),
            axSettingsButton.leadingAnchor.constraint(equalTo: axButton.trailingAnchor, constant: 8),
            axSettingsButton.centerYAnchor.constraint(equalTo: axButton.centerYAnchor),
            axBox.bottomAnchor.constraint(equalTo: axButton.bottomAnchor, constant: 14),
        ])
    }

    private func refreshAxStatus() {
        let trusted = NotificationManager.isAccessibilityTrusted
        axStatus.stringValue = trusted ? "● enabled" : "○ not enabled"
        axStatus.textColor = trusted ? .systemGreen : OnboardingStyle.textFaint
        axButton.isEnabled = !trusted
    }

    @objc private func openNotifSettings() {
        NotificationManager.openNotificationSystemSettings()
    }

    @objc private func requestNotif() {
        NotificationManager.shared.requestPermission { _ in }
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
        refreshAxStatus()
    }

    @objc private func openAxSettings() {
        NotificationManager.openAccessibilitySystemSettings()
    }
}

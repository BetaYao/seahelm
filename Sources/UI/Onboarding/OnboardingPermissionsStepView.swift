import AppKit

/// Step 3: notifications + Accessibility.
final class OnboardingPermissionsStepView: NSView {
    private let notifBox = NSView()
    private let notifTitle = NSTextField(labelWithString: "Allow Seahelm to send notifications")
    private let notifSubtitle = NSTextField(labelWithString: "Click Allow in the macOS dialog.")
    private let openNotifButton = NSButton(title: "Open System Settings", target: nil, action: nil)
    private let requestNotifButton = NSButton(title: "Request permission", target: nil, action: nil)

    private let soundLabel = NSTextField(labelWithString: "Notification sound")
    private let soundPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let testButton = NSButton(title: "Send test notification", target: nil, action: nil)

    private let axBox = NSView()
    private let axTitle = NSTextField(labelWithString: "Accessibility (Island hotkey)")
    private let axSubtitle = NSTextField(wrappingLabelWithString: "Needed for Ctrl-double-tap to summon the Island while Seahelm is in the background.")
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

    private func setup() {
        styleBox(notifBox)
        styleBox(axBox)

        notifTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        notifSubtitle.font = .systemFont(ofSize: 12)
        notifSubtitle.textColor = .secondaryLabelColor

        openNotifButton.bezelStyle = .rounded
        openNotifButton.target = self
        openNotifButton.action = #selector(openNotifSettings)

        requestNotifButton.bezelStyle = .rounded
        requestNotifButton.target = self
        requestNotifButton.action = #selector(requestNotif)

        soundLabel.font = .systemFont(ofSize: 13, weight: .medium)
        soundPopup.addItems(withTitles: ["System default", "Critical", "None"])
        soundPopup.target = self
        soundPopup.action = #selector(soundChanged)

        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(sendTest)

        axTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        axSubtitle.font = .systemFont(ofSize: 12)
        axSubtitle.textColor = .secondaryLabelColor
        axStatus.font = .systemFont(ofSize: 12, weight: .medium)

        axButton.bezelStyle = .rounded
        axButton.target = self
        axButton.action = #selector(enableAx)

        axSettingsButton.bezelStyle = .rounded
        axSettingsButton.target = self
        axSettingsButton.action = #selector(openAxSettings)

        for v in [notifTitle, notifSubtitle, openNotifButton, requestNotifButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            notifBox.addSubview(v)
        }
        for v in [soundLabel, soundPopup, testButton, axBox] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        notifBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(notifBox)

        for v in [axTitle, axSubtitle, axStatus, axButton, axSettingsButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            axBox.addSubview(v)
        }

        NSLayoutConstraint.activate([
            notifBox.topAnchor.constraint(equalTo: topAnchor),
            notifBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            notifBox.trailingAnchor.constraint(equalTo: trailingAnchor),

            notifTitle.topAnchor.constraint(equalTo: notifBox.topAnchor, constant: 14),
            notifTitle.leadingAnchor.constraint(equalTo: notifBox.leadingAnchor, constant: 14),
            notifSubtitle.topAnchor.constraint(equalTo: notifTitle.bottomAnchor, constant: 4),
            notifSubtitle.leadingAnchor.constraint(equalTo: notifTitle.leadingAnchor),
            requestNotifButton.trailingAnchor.constraint(equalTo: notifBox.trailingAnchor, constant: -14),
            requestNotifButton.centerYAnchor.constraint(equalTo: notifBox.centerYAnchor),
            openNotifButton.trailingAnchor.constraint(equalTo: requestNotifButton.leadingAnchor, constant: -8),
            openNotifButton.centerYAnchor.constraint(equalTo: notifBox.centerYAnchor),
            notifBox.bottomAnchor.constraint(equalTo: notifSubtitle.bottomAnchor, constant: 14),

            soundLabel.topAnchor.constraint(equalTo: notifBox.bottomAnchor, constant: 20),
            soundLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            soundPopup.leadingAnchor.constraint(equalTo: leadingAnchor),
            soundPopup.topAnchor.constraint(equalTo: soundLabel.bottomAnchor, constant: 8),
            testButton.leadingAnchor.constraint(equalTo: soundPopup.trailingAnchor, constant: 12),
            testButton.centerYAnchor.constraint(equalTo: soundPopup.centerYAnchor),

            axBox.topAnchor.constraint(equalTo: soundPopup.bottomAnchor, constant: 20),
            axBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            axBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            axBox.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            axTitle.topAnchor.constraint(equalTo: axBox.topAnchor, constant: 14),
            axTitle.leadingAnchor.constraint(equalTo: axBox.leadingAnchor, constant: 14),
            axSubtitle.topAnchor.constraint(equalTo: axTitle.bottomAnchor, constant: 4),
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

    private func styleBox(_ box: NSView) {
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    private func refreshAxStatus() {
        let trusted = NotificationManager.isAccessibilityTrusted
        axStatus.stringValue = trusted ? "● Enabled" : "○ Not enabled"
        axStatus.textColor = trusted ? .systemGreen : .secondaryLabelColor
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

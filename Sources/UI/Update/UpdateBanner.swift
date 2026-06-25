import AppKit

protocol UpdateBannerDelegate: AnyObject {
    func updateBannerDidClickInstall(_ banner: UpdateBanner)
    func updateBannerDidClickSkip(_ banner: UpdateBanner)
    func updateBannerDidClickRestart(_ banner: UpdateBanner)
    func updateBannerDidClickRetry(_ banner: UpdateBanner)
}

/// A 32px banner shown at the top of the main window when an update is available.
class UpdateBanner: NSView {
    weak var delegate: UpdateBannerDelegate?

    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let actionButton = NSButton()
    private let skipButton = NSButton()

    private(set) var version: String = ""
    private var bannerHeightConstraint: NSLayoutConstraint!

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0x0f / 255.0, green: 0x2a / 255.0, blue: 0x2e / 255.0, alpha: 1.0).cgColor
        setAccessibilityIdentifier("update.banner")

        // Status label
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = NSColor(hex: 0x22d3ee)
        statusLabel.setAccessibilityIdentifier("update.statusLabel")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        // Progress bar
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressBar)

        // Action button (更新 / 立即重启 / 重试)
        actionButton.bezelStyle = .rounded
        actionButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        actionButton.target = self
        actionButton.action = #selector(actionClicked)
        actionButton.setAccessibilityIdentifier("update.installButton")
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actionButton)

        // Skip button
        skipButton.title = "跳过"
        skipButton.bezelStyle = .recessed
        skipButton.isBordered = false
        skipButton.font = NSFont.systemFont(ofSize: 11)
        skipButton.contentTintColor = NSColor(hex: 0x22d3ee).withAlphaComponent(0.7)
        skipButton.target = self
        skipButton.action = #selector(skipClicked)
        skipButton.setAccessibilityIdentifier("update.skipButton")
        skipButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(skipButton)

        bannerHeightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            bannerHeightConstraint,

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            progressBar.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 12),
            progressBar.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressBar.widthAnchor.constraint(equalToConstant: 120),

            skipButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            skipButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            actionButton.trailingAnchor.constraint(equalTo: skipButton.leadingAnchor, constant: -8),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - State Updates

    func showNewVersion(_ ver: String) {
        version = ver
        statusLabel.stringValue = "新版本 v\(ver) 可用"
        actionButton.title = "更新"
        actionButton.setAccessibilityIdentifier("update.installButton")
        actionButton.isHidden = false
        skipButton.isHidden = false
        progressBar.isHidden = true
        setBannerVisible(true)
    }

    func dismiss() {
        setBannerVisible(false)
    }

    private func setBannerVisible(_ visible: Bool) {
        isHidden = !visible
        bannerHeightConstraint.constant = visible ? 32 : 0
    }

    func update(state: UpdateManager.State) {
        switch state {
        case .idle:
            setBannerVisible(false)

        case .downloading(let progress):
            statusLabel.stringValue = "下载中... \(Int(progress * 100))%"
            progressBar.doubleValue = progress
            progressBar.isHidden = false
            actionButton.isHidden = true
            skipButton.isHidden = true
            setBannerVisible(true)

        case .extracting:
            statusLabel.stringValue = "正在解压..."
            progressBar.isHidden = true
            actionButton.isHidden = true
            skipButton.isHidden = true

        case .verifying:
            statusLabel.stringValue = "正在验证签名..."
            progressBar.isHidden = true
            actionButton.isHidden = true
            skipButton.isHidden = true

        case .readyToInstall:
            statusLabel.stringValue = "准备就绪"
            actionButton.title = "立即重启"
            actionButton.setAccessibilityIdentifier("update.restartButton")
            actionButton.isHidden = false
            skipButton.isHidden = true
            progressBar.isHidden = true

        case .failed(let error):
            statusLabel.stringValue = "更新失败: \(error.localizedDescription)"
            actionButton.title = "重试"
            actionButton.setAccessibilityIdentifier("update.installButton")
            actionButton.isHidden = false
            skipButton.isHidden = false
            progressBar.isHidden = true
        }
    }

    // MARK: - Actions

    @objc private func actionClicked() {
        if actionButton.title == "立即重启" {
            delegate?.updateBannerDidClickRestart(self)
        } else if actionButton.title == "重试" {
            delegate?.updateBannerDidClickRetry(self)
        } else {
            delegate?.updateBannerDidClickInstall(self)
        }
    }

    @objc private func skipClicked() {
        delegate?.updateBannerDidClickSkip(self)
    }
}

import AppKit

// MARK: - Zoom Colors
/// Zoom 风格的颜色系统，支持深色/浅色模式
enum ZoomColors {
    // 背景色
    static let dialogBackground = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x1A1A1A) : NSColor(hex: 0xFFFFFF)
    }
    
    static let inputBackground = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x2D2D2D) : NSColor(hex: 0xF5F5F5)
    }
    
    // 文字颜色
    static let titleText = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0xFFFFFF) : NSColor(hex: 0x1A1A1A)
    }
    
    static let bodyText = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0xCCCCCC) : NSColor(hex: 0x333333)
    }
    
    static let secondaryText = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x999999) : NSColor(hex: 0x666666)
    }
    
    static let placeholderText = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x666666) : NSColor(hex: 0x999999)
    }
    
    // Zoom 蓝色（强调色）
    static let zoomBlue = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x0E72ED) : NSColor(hex: 0x0E72ED)
    }
    
    static let zoomBlueHover = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x2B8CF7) : NSColor(hex: 0x2B8CF7)
    }
    
    static let zoomBluePressed = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x0959C9) : NSColor(hex: 0x0959C9)
    }
    
    // 边框颜色
    static let borderDefault = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x3D3D3D) : NSColor(hex: 0xE0E0E0)
    }
    
    static let borderFocus = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x0E72ED) : NSColor(hex: 0x0E72ED)
    }
    
    // 按钮颜色
    static let secondaryButtonBg = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x3D3D3D) : NSColor(hex: 0xF0F0F0)
    }
    
    static let secondaryButtonHover = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x4D4D4D) : NSColor(hex: 0xE0E0E0)
    }
    
    // 错误颜色
    static let errorText = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0xFF6B6B) : NSColor(hex: 0xDC2626)
    }
    
    // 阴影
    static let shadowColor = NSColor.black.withAlphaComponent(0.4)
}

// MARK: - Typography
enum ZoomTypography {
    static let title = NSFont.systemFont(ofSize: 18, weight: .semibold)
    static let body = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let label = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let button = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let caption = NSFont.systemFont(ofSize: 11, weight: .regular)
}

protocol NewBranchDialogDelegate: AnyObject {
    func newBranchDialog(_ dialog: NewBranchDialog, didCreateWorktree info: WorktreeInfo, inRepo repoPath: String)
}

/// Zoom 风格的新分支弹窗
class NewBranchDialog: NSViewController {
    enum Layout {
        static let actionButtonsFillEqually = true
        static let actionButtonHeight: CGFloat = 40
    }

    weak var dialogDelegate: NewBranchDialogDelegate?
    
    private let repoPopup = NSPopUpButton()
    private let branchField = NSTextField()
    private let baseBranchPopup = NSPopUpButton()
    private let createButton = NSButton()
    private let cancelButton = NSButton()
    private let createLoadingIndicator = NSProgressIndicator()
    private let errorLabel = NSTextField(labelWithString: "")
    
    private var repoPaths: [String] = []
    
    init(repoPaths: [String]) {
        self.repoPaths = repoPaths
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }
    
    override func loadView() {
        // 创建圆角卡片容器
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 280))
        container.wantsLayer = true
        container.layer?.backgroundColor = SemanticColors.panel.cgColor
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = false
        
        // 添加阴影
        container.layer?.shadowColor = NSColor.black.withAlphaComponent(0.4).cgColor
        container.layer?.shadowOpacity = 0.5
        container.layer?.shadowRadius = 20
        container.layer?.shadowOffset = CGSize(width: 0, height: 8)
        
        container.setAccessibilityIdentifier("dialog.newBranch")
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        self.view = container
        
        // 标题
        let titleLabel = NSTextField(labelWithString: "New Thread")
        titleLabel.font = ZoomTypography.title
        titleLabel.textColor = SemanticColors.text
        titleLabel.alignment = .center
        
        // Repository 选择
        let repoLabel = createLabel("Repository")
        setupRepoPopup()
        
        // Branch name 输入
        let branchLabel = createLabel("Thread name")
        setupBranchField()
        
        // Base branch 选择
        let baseLabel = createLabel("Based on")
        setupBaseBranchPopup()
        
        // 错误提示
        errorLabel.textColor = SemanticColors.danger
        errorLabel.font = ZoomTypography.caption
        errorLabel.isHidden = true
        errorLabel.maximumNumberOfLines = 2
        
        // 按钮
        setupButtons()
        
        // 布局
        let formStack = NSStackView(views: [
            createFormRow(repoLabel, repoPopup),
            createFormRow(branchLabel, branchField),
            createFormRow(baseLabel, baseBranchPopup),
        ])
        formStack.orientation = .vertical
        formStack.spacing = 16
        formStack.alignment = .leading
        
        let buttonStack = NSStackView(views: [cancelButton, createButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 12
        buttonStack.alignment = .centerY
        if Layout.actionButtonsFillEqually {
            buttonStack.distribution = .fillEqually
        }
        
        let mainStack = NSStackView(views: [
            titleLabel,
            formStack,
            errorLabel,
            buttonStack
        ])
        mainStack.orientation = .vertical
        mainStack.spacing = 20
        mainStack.alignment = .centerX
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 28, right: 32)
        container.addSubview(mainStack)
        
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            
            titleLabel.widthAnchor.constraint(equalTo: mainStack.widthAnchor, constant: -64),
            
            repoPopup.widthAnchor.constraint(equalToConstant: 280),
            branchField.widthAnchor.constraint(equalToConstant: 280),
            baseBranchPopup.widthAnchor.constraint(equalToConstant: 280),
            
            buttonStack.widthAnchor.constraint(equalToConstant: 292),
            createButton.heightAnchor.constraint(equalToConstant: Layout.actionButtonHeight),
            cancelButton.heightAnchor.constraint(equalToConstant: Layout.actionButtonHeight),
        ])
        
        // 加载第一个 repo 的分支
        if !repoPaths.isEmpty {
            loadBranches(for: repoPaths[0])
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.initialFirstResponder = branchField
        view.window?.makeFirstResponder(branchField)
        view.window?.recalculateKeyViewLoop()
    }

    private func createLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = ZoomTypography.label
        label.textColor = SemanticColors.text
        return label
    }
    
    private func createFormRow(_ label: NSTextField, _ control: NSView) -> NSStackView {
        let row = NSStackView(views: [label, control])
        row.orientation = .vertical
        row.spacing = 6
        row.alignment = .leading
        return row
    }
    
    private func setupRepoPopup() {
        repoPopup.removeAllItems()
        for path in repoPaths {
            repoPopup.addItem(withTitle: URL(fileURLWithPath: path).lastPathComponent)
        }
        repoPopup.target = self
        repoPopup.action = #selector(repoChanged)
        stylePopup(repoPopup)
    }
    
    private func setupBranchField() {
        branchField.placeholderString = "e.g., feature/new-thread"
        branchField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        branchField.setAccessibilityIdentifier("dialog.newBranch.nameField")
        styleTextField(branchField)
    }
    
    private func setupBaseBranchPopup() {
        baseBranchPopup.removeAllItems()
        stylePopup(baseBranchPopup)
    }
    
    private func styleTextField(_ textField: NSTextField) {
        textField.wantsLayer = true
        textField.layer?.backgroundColor = SemanticColors.tileBg.cgColor
        textField.layer?.cornerRadius = 8
        textField.layer?.borderWidth = 1
        textField.layer?.borderColor = SemanticColors.line.cgColor
        textField.textColor = SemanticColors.text
        textField.placeholderAttributedString = NSAttributedString(
            string: textField.placeholderString ?? "",
            attributes: [
                .foregroundColor: SemanticColors.muted,
                .font: NSFont.systemFont(ofSize: 13)
            ]
        )
        
        // 添加内边距
        textField.cell?.focusRingType = .none
        
        // 监听聚焦状态改变边框颜色
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textFieldDidBeginEditing),
            name: NSControl.textDidBeginEditingNotification,
            object: textField
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textFieldDidEndEditing),
            name: NSControl.textDidEndEditingNotification,
            object: textField
        )
    }
    
    private func stylePopup(_ popup: NSPopUpButton) {
        popup.wantsLayer = true
        popup.layer?.backgroundColor = SemanticColors.tileBg.cgColor
        popup.layer?.cornerRadius = 8
        popup.layer?.borderWidth = 1
        popup.layer?.borderColor = SemanticColors.line.cgColor
        
        // 设置文字颜色通过 attributedTitle
        for item in popup.itemArray {
            let attributedTitle = NSAttributedString(
                string: item.title,
                attributes: [
                    .foregroundColor: SemanticColors.text,
                    .font: NSFont.systemFont(ofSize: 13)
                ]
            )
            item.attributedTitle = attributedTitle
        }
    }
    
    @objc private func textFieldDidBeginEditing(_ notification: Notification) {
        if let textField = notification.object as? NSTextField {
            textField.layer?.borderColor = SemanticColors.accent.cgColor
            textField.layer?.borderWidth = 2
        }
    }
    
    @objc private func textFieldDidEndEditing(_ notification: Notification) {
        if let textField = notification.object as? NSTextField {
            textField.layer?.borderColor = SemanticColors.line.cgColor
            textField.layer?.borderWidth = 1
        }
    }
    
    private func setupButtons() {
        createButton.title = "Create"
        createButton.bezelStyle = .rounded
        createButton.isBordered = true
        createButton.target = self
        createButton.action = #selector(createClicked)
        createButton.keyEquivalent = "\r"   // Return triggers Create
        createButton.setAccessibilityIdentifier("dialog.newBranch.createButton")

        createLoadingIndicator.style = .spinning
        createLoadingIndicator.controlSize = .small
        createLoadingIndicator.isDisplayedWhenStopped = false
        createLoadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        createButton.addSubview(createLoadingIndicator)
        NSLayoutConstraint.activate([
            createLoadingIndicator.centerXAnchor.constraint(equalTo: createButton.centerXAnchor),
            createLoadingIndicator.centerYAnchor.constraint(equalTo: createButton.centerYAnchor),
        ])

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.isBordered = true
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}" // Escape key
    }
    
    @objc private func repoChanged() {
        let index = repoPopup.indexOfSelectedItem
        guard index >= 0, index < repoPaths.count else { return }
        loadBranches(for: repoPaths[index])
    }
    
    private func loadBranches(for repoPath: String) {
        let branches = WorktreeCreator.listBranches(repoPath: repoPath)
        baseBranchPopup.removeAllItems()
        baseBranchPopup.addItems(withTitles: branches)
        // Select "main" if available
        if let mainIndex = branches.firstIndex(of: "main") {
            baseBranchPopup.selectItem(at: mainIndex)
        } else if let masterIndex = branches.firstIndex(of: "master") {
            baseBranchPopup.selectItem(at: masterIndex)
        }
    }
    
    @objc private func createClicked() {
        let branchName = branchField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !branchName.isEmpty else {
            showError("Thread name cannot be empty")
            return
        }
        // Validate branch name (no spaces, basic check)
        if branchName.contains(" ") {
            showError("Thread name cannot contain spaces")
            return
        }
        
        let repoIndex = repoPopup.indexOfSelectedItem
        guard repoIndex >= 0, repoIndex < repoPaths.count else { return }
        let repoPath = repoPaths[repoIndex]
        let baseBranch = baseBranchPopup.titleOfSelectedItem ?? "main"

        setCreateButtonLoading(true)
        
        DispatchQueue.global().async { [weak self] in
            do {
                let info = try WorktreeCreator.createWorktree(
                    repoPath: repoPath,
                    branchName: branchName,
                    baseBranch: baseBranch
                )
                DispatchQueue.main.async {
                    self?.dismiss(nil)
                    self?.dialogDelegate?.newBranchDialog(self!, didCreateWorktree: info, inRepo: repoPath)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.showError(error.localizedDescription)
                    self?.setCreateButtonLoading(false)
                }
            }
        }
    }

    private func setCreateButtonLoading(_ loading: Bool) {
        createButton.isEnabled = !loading
        createButton.title = loading ? "" : "Create"
        if loading {
            createLoadingIndicator.startAnimation(nil)
        } else {
            createLoadingIndicator.stopAnimation(nil)
        }
    }
    
    @objc private func cancelClicked() {
        dismiss(nil)
    }
    
    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        
        // 震动动画
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            self.view.animator().layer?.transform = CATransform3DMakeTranslation(-5, 0, 0)
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                self.view.animator().layer?.transform = CATransform3DMakeTranslation(5, 0, 0)
            } completionHandler: {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.1
                    self.view.animator().layer?.transform = CATransform3DIdentity
                }
            }
        }
    }
}

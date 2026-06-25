import AppKit

private final class DiffReviewFileTreeNode {
    let name: String
    let fullPath: String
    var status: String?
    var children: [DiffReviewFileTreeNode] = []
    var isDirectory: Bool { status == nil }

    init(name: String, fullPath: String, status: String? = nil) {
        self.name = name
        self.fullPath = fullPath
        self.status = status
    }
}

final class DiffReviewView: NSView {
    private let splitView = NSSplitView()
    private let outlineView = NSOutlineView()
    private let fileScrollView = NSScrollView()
    private let diffTextView = NSTextView()
    private let diffScrollView = NSScrollView()
    private let headerLabel = NSTextField(labelWithString: "")

    private let loadSnapshot: () -> GitDiffSnapshot
    private var files: [DiffFile] = []
    private var treeNodes: [DiffReviewFileTreeNode] = []
    private var hasLoaded = false

    var renderedTextForTesting: String {
        diffTextView.string
    }

    init(worktreePath: String, loadSnapshot: (() -> GitDiffSnapshot)? = nil) {
        self.loadSnapshot = loadSnapshot ?? { GitDiff.snapshot(worktreePath: worktreePath) }
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layout() {
        super.layout()
        guard splitView.subviews.count > 1 else { return }
        splitView.setPosition(min(260, bounds.width * 0.45), ofDividerAt: 0)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && !hasLoaded {
            loadDiff()
        }
    }

    func loadDiff() {
        hasLoaded = true
        let loader = loadSnapshot
        DispatchQueue.global().async { [weak self] in
            let snapshot = loader()
            DispatchQueue.main.async {
                self?.applySnapshot(snapshot)
            }
        }
    }

    func loadDiffForTesting() {
        hasLoaded = true
        applySnapshot(loadSnapshot())
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        setAccessibilityIdentifier("diffReview")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        headerLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        headerLabel.textColor = Theme.textPrimary
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLabel)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(splitView)

        fileScrollView.hasVerticalScroller = true
        fileScrollView.drawsBackground = false
        fileScrollView.borderType = .noBorder
        fileScrollView.translatesAutoresizingMaskIntoConstraints = true

        outlineView.setAccessibilityIdentifier("diffReview.fileTree")
        outlineView.backgroundColor = .clear
        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 16
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.selectionHighlightStyle = .regular

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        fileScrollView.documentView = outlineView

        diffScrollView.hasVerticalScroller = true
        diffScrollView.hasHorizontalScroller = true
        diffScrollView.drawsBackground = false
        diffScrollView.borderType = .noBorder
        diffScrollView.translatesAutoresizingMaskIntoConstraints = true

        diffTextView.setAccessibilityIdentifier("diffReview.text")
        diffTextView.isEditable = false
        diffTextView.isSelectable = true
        diffTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        diffTextView.backgroundColor = Theme.background
        diffTextView.textColor = Theme.textPrimary
        diffTextView.textContainerInset = NSSize(width: 8, height: 8)
        diffTextView.isHorizontallyResizable = true
        diffTextView.textContainer?.widthTracksTextView = false
        diffTextView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        diffScrollView.documentView = diffTextView

        splitView.addSubview(fileScrollView)
        splitView.addSubview(diffScrollView)
        splitView.adjustSubviews()

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -96),

            splitView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func applySnapshot(_ snapshot: GitDiffSnapshot) {
        files = snapshot.files
        let changedFiles = snapshot.changedFiles.isEmpty
            ? snapshot.files.map {
                GitChangedFile(
                    path: $0.path,
                    oldPath: $0.oldPath,
                    status: $0.status,
                    stage: $0.stage
                )
            }
            : snapshot.changedFiles
        treeNodes = buildFileTree(from: changedFiles)

        let totalAdd = files.reduce(0) { $0 + $1.additions }
        let totalDel = files.reduce(0) { $0 + $1.deletions }
        let uniqueFileCount = Set(changedFiles.map(\.path)).count
        headerLabel.stringValue = "Changes: \(uniqueFileCount) files  +\(totalAdd) -\(totalDel)"
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        showAllDiffs()
    }

    private func showAllDiffs() {
        render(files)
    }

    private func showDiffForFile(path: String) {
        let matchingFiles = files.filter { $0.path == path }
        guard !matchingFiles.isEmpty else {
            showAllDiffs()
            return
        }
        render(matchingFiles)
    }

    private func showDiffsForPaths(_ paths: [String]) {
        let pathSet = Set(paths)
        let matchingFiles = files.filter { pathSet.contains($0.path) }
        guard !matchingFiles.isEmpty else {
            showAllDiffs()
            return
        }
        render(matchingFiles)
    }

    private func render(_ filesToRender: [DiffFile]) {
        let attributed = NSMutableAttributedString()
        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        for file in filesToRender {
            let fileHeader = "\n━━━ \(file.path) (+\(file.additions) -\(file.deletions)) ━━━\n\n"
            attributed.append(NSAttributedString(string: fileHeader, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                .foregroundColor: Theme.accent,
            ]))

            for hunk in file.hunks {
                attributed.append(NSAttributedString(string: hunk.header + "\n", attributes: [
                    .font: monoFont,
                    .foregroundColor: NSColor.systemCyan,
                ]))

                for line in hunk.lines {
                    let prefix: String
                    let color: NSColor
                    switch line.type {
                    case .addition: prefix = "+"; color = NSColor.systemGreen
                    case .deletion: prefix = "-"; color = NSColor.systemRed
                    case .context: prefix = " "; color = Theme.textSecondary
                    }
                    attributed.append(NSAttributedString(string: prefix, attributes: [
                        .font: monoFont,
                        .foregroundColor: color,
                    ]))
                    attributed.append(DiffSyntaxHighlighter.attributedString(
                        for: line.content,
                        filePath: file.path,
                        font: monoFont,
                        baseColor: color
                    ))
                    attributed.append(NSAttributedString(string: "\n", attributes: [
                        .font: monoFont,
                        .foregroundColor: color,
                    ]))
                }
            }
        }

        if filesToRender.isEmpty {
            attributed.append(NSAttributedString(string: "No changes", attributes: [
                .font: monoFont,
                .foregroundColor: Theme.textSecondary,
            ]))
        }

        diffTextView.textStorage?.setAttributedString(attributed)
    }

    private func statusColor(_ status: String) -> NSColor {
        switch status {
        case "A", "??": return NSColor.systemGreen
        case "M": return NSColor.systemYellow
        case "D": return NSColor.systemRed
        case "R": return NSColor.systemCyan
        default: return Theme.textSecondary
        }
    }

    private func buildFileTree(from changedFiles: [GitChangedFile]) -> [DiffReviewFileTreeNode] {
        let root = DiffReviewFileTreeNode(name: "", fullPath: "")
        var seenPaths = Set<String>()

        for file in changedFiles where seenPaths.insert(file.path).inserted {
            let components = file.path.components(separatedBy: "/")
            var current = root

            for (index, component) in components.enumerated() {
                let isLast = index == components.count - 1
                let partialPath = components[0...index].joined(separator: "/")

                if isLast {
                    let leaf = DiffReviewFileTreeNode(
                        name: component,
                        fullPath: partialPath,
                        status: file.status.rawValue
                    )
                    current.children.append(leaf)
                } else if let existing = current.children.first(where: { $0.isDirectory && $0.name == component }) {
                    current = existing
                } else {
                    let directory = DiffReviewFileTreeNode(name: component, fullPath: partialPath)
                    current.children.append(directory)
                    current = directory
                }
            }
        }

        collapseChains(root)
        return root.children
    }

    private func collapseChains(_ node: DiffReviewFileTreeNode) {
        for child in node.children {
            collapseChains(child)
        }

        var collapsed = true
        while collapsed {
            collapsed = false
            for (index, child) in node.children.enumerated()
            where child.isDirectory && child.children.count == 1 && child.children[0].isDirectory {
                let grandchild = child.children[0]
                let merged = DiffReviewFileTreeNode(
                    name: child.name + "/" + grandchild.name,
                    fullPath: grandchild.fullPath
                )
                merged.children = grandchild.children
                node.children[index] = merged
                collapsed = true
                break
            }
        }
    }
}

extension DiffReviewView: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? DiffReviewFileTreeNode {
            return node.children.count
        }
        return treeNodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? DiffReviewFileTreeNode {
            return node.children[index]
        }
        return treeNodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? DiffReviewFileTreeNode else { return false }
        return node.isDirectory
    }
}

extension DiffReviewView: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DiffReviewFileTreeNode else { return nil }

        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("FileTreeCell")

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        cell.addSubview(imageView)

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = NSFont.systemFont(ofSize: 12)
        textField.lineBreakMode = .byTruncatingMiddle
        textField.drawsBackground = false
        textField.isBezeled = false
        textField.isEditable = false
        cell.addSubview(textField)
        cell.textField = textField

        if node.isDirectory {
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            imageView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig)
            imageView.contentTintColor = NSColor.systemBlue
            textField.stringValue = node.name
            textField.textColor = Theme.textPrimary
        } else {
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            imageView.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig)
            imageView.contentTintColor = statusColor(node.status ?? "")
            textField.stringValue = node.name
            textField.textColor = Theme.textPrimary
        }

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? DiffReviewFileTreeNode else {
            showAllDiffs()
            return
        }

        if node.isDirectory {
            showDiffsForPaths(collectFilePaths(under: node))
        } else {
            showDiffForFile(path: node.fullPath)
        }
    }

    private func collectFilePaths(under node: DiffReviewFileTreeNode) -> [String] {
        if !node.isDirectory {
            return [node.fullPath]
        }
        return node.children.flatMap { collectFilePaths(under: $0) }
    }
}

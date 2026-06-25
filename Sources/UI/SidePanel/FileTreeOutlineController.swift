import AppKit

// MARK: - FileTreeNode

final class FileTreeNode {
    let url: URL
    let isDirectory: Bool
    var children: [FileTreeNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }
}

// MARK: - FileTreeOutlineController

final class FileTreeOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let outlineView: NSOutlineView
    var onSelectFile: ((String) -> Void)?

    private var rootPath: String?
    private var rootNodes: [FileTreeNode] = []

    /// When true, dotfiles are listed. Toggled from the side panel / context menu.
    var showHidden: Bool = false {
        didSet { guard showHidden != oldValue else { return }; reload() }
    }

    /// Case-insensitive name filter. Empty shows the full tree.
    var filterText: String = "" {
        didSet {
            let trimmed = filterText.trimmingCharacters(in: .whitespaces)
            guard trimmed != oldValue.trimmingCharacters(in: .whitespaces) else { return }
            reload()
        }
    }

    init(rootPath: String) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileColumn"))
        column.title = "Name"
        let ov = FileOutlineView()
        ov.addTableColumn(column)
        ov.outlineTableColumn = column
        ov.headerView = nil
        ov.rowHeight = 20
        self.outlineView = ov
        super.init()
        ov.dataSource = self
        ov.delegate = self
        // Single click opens files / toggles folders. Arrow keys navigate
        // (built-in); Return opens; Cmd+Delete trashes — see handleKeyDown.
        ov.target = self
        ov.action = #selector(handleActivate)
        ov.onKeyDown = { [weak self] event in self?.handleKeyDown(event) ?? false }

        let menu = NSMenu()
        menu.delegate = self
        ov.menu = menu

        setRoot(rootPath)
    }

    func setRoot(_ path: String?) {
        rootPath = path
        reload()
    }

    private func reload() {
        guard let path = rootPath else {
            rootNodes = []
            outlineView.reloadData()
            return
        }
        let url = URL(fileURLWithPath: path)
        rootNodes = childNodesFiltered(of: url)
        outlineView.reloadData()
        if isFiltering {
            outlineView.expandItem(nil, expandChildren: true)
        }
    }

    private var isFiltering: Bool {
        !filterText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Expansion state (persisted per worktree)

    /// Absolute paths of all currently-expanded directories.
    func currentExpandedPaths() -> Set<String> {
        var set = Set<String>()
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? FileTreeNode,
               node.isDirectory, outlineView.isItemExpanded(node) {
                set.insert(node.url.standardizedFileURL.path)
            }
        }
        return set
    }

    /// Re-expand directories whose paths are in `paths`. Iterates until stable so
    /// nested folders (revealed only after their parent expands) are restored too.
    func restoreExpansion(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        var changed = true
        while changed {
            changed = false
            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? FileTreeNode,
                      node.isDirectory,
                      !outlineView.isItemExpanded(node),
                      paths.contains(node.url.standardizedFileURL.path) else { continue }
                outlineView.expandItem(node)
                changed = true
            }
        }
    }

    // MARK: - Listing / filtering

    /// Children of `directory` honouring `showHidden` and the current filter.
    /// When filtering, directories are kept only if a descendant matches.
    private func childNodesFiltered(of directory: URL) -> [FileTreeNode] {
        let all = FileTreeOutlineController.childNodes(of: directory, showHidden: showHidden)
        let needle = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }

        var result: [FileTreeNode] = []
        for node in all {
            let nameMatches = node.url.lastPathComponent.lowercased().contains(needle)
            if node.isDirectory {
                let kids = childNodesFiltered(of: node.url)
                if nameMatches || !kids.isEmpty {
                    node.children = kids
                    result.append(node)
                }
            } else if nameMatches {
                result.append(node)
            }
        }
        return result
    }

    /// Lists the contents of `directory`, with directories first and each group
    /// sorted alphabetically by lastPathComponent. Dotfiles hidden unless `showHidden`.
    static func childNodes(of directory: URL, showHidden: Bool = false) -> [FileTreeNode] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        var dirs: [FileTreeNode] = []
        var files: [FileTreeNode] = []

        for item in items {
            let name = item.lastPathComponent
            if !showHidden, name.hasPrefix(".") { continue }
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let node = FileTreeNode(url: item, isDirectory: isDir)
            if isDir {
                dirs.append(node)
            } else {
                files.append(node)
            }
        }

        dirs.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        files.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        return dirs + files
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return rootNodes.count
        }
        guard let node = item as? FileTreeNode, node.isDirectory else { return 0 }
        if node.children == nil {
            node.children = childNodesFiltered(of: node.url)
        }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return rootNodes[index]
        }
        let node = item as! FileTreeNode
        if node.children == nil {
            node.children = childNodesFiltered(of: node.url)
        }
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileTreeNode)?.isDirectory ?? false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileTreeNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("FileCell")
        let cellView: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cellView = reused
        } else {
            cellView = NSTableCellView()
            cellView.identifier = id

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            cellView.addSubview(imageView)
            cellView.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(textField)
            cellView.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 14),
                imageView.heightAnchor.constraint(equalToConstant: 14),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        let (symbolName, tint) = Self.icon(for: node)
        cellView.imageView?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        cellView.imageView?.contentTintColor = tint
        // Dim dotfiles so hidden items read as secondary.
        let isDotfile = node.url.lastPathComponent.hasPrefix(".")
        cellView.textField?.textColor = isDotfile ? .secondaryLabelColor : .labelColor
        cellView.textField?.stringValue = node.url.lastPathComponent
        return cellView
    }

    // MARK: - Icons

    /// SF Symbol + tint for a node, chosen by directory / file extension so
    /// different file types are visually distinct.
    static func icon(for node: FileTreeNode) -> (String, NSColor) {
        if node.isDirectory { return ("folder.fill", .systemBlue) }

        let name = node.url.lastPathComponent.lowercased()
        switch name {
        case "dockerfile": return ("shippingbox.fill", .systemBlue)
        case "makefile": return ("hammer.fill", .systemGray)
        case "package.swift": return ("shippingbox.fill", .systemOrange)
        case ".gitignore", ".gitattributes": return ("arrow.triangle.branch", .systemOrange)
        default: break
        }
        if name.hasPrefix("readme") { return ("book.fill", .systemGray) }

        switch node.url.pathExtension.lowercased() {
        case "swift": return ("swift", .systemOrange)
        case "json", "yaml", "yml", "toml", "plist", "ini", "conf", "env":
            return ("curlybraces", .systemPurple)
        case "md", "markdown", "txt", "rtf", "log":
            return ("doc.text.fill", .systemGray)
        case "js", "jsx", "ts", "tsx", "py", "rb", "go", "rs", "c", "h",
             "cpp", "cc", "hpp", "m", "mm", "java", "kt", "sh", "bash", "zsh",
             "php", "lua", "dart", "scala", "pl":
            return ("chevron.left.forwardslash.chevron.right", .systemGreen)
        case "html", "htm", "xml", "vue", "svelte":
            return ("chevron.left.forwardslash.chevron.right", .systemOrange)
        case "css", "scss", "sass", "less":
            return ("paintbrush.fill", .systemPink)
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "bmp", "tiff", "ico":
            return ("photo.fill", .systemTeal)
        case "pdf": return ("doc.richtext.fill", .systemRed)
        case "zip", "tar", "gz", "tgz", "bz2", "7z", "rar":
            return ("doc.zipper", .systemBrown)
        case "mp3", "wav", "aac", "flac", "m4a", "ogg":
            return ("music.note", .systemPink)
        case "mp4", "mov", "avi", "mkv", "webm":
            return ("film.fill", .systemIndigo)
        case "lock": return ("lock.fill", .systemGray)
        case "ttf", "otf", "woff", "woff2": return ("textformat", .systemGray)
        default: return ("doc", .secondaryLabelColor)
        }
    }

    // MARK: - Activation (click / Return)

    func outlineViewSelectionDidChange(_ notification: Notification) {}

    /// Single click or Return: open files, toggle folders.
    @objc func handleActivate() {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        activateRow(row)
    }

    private func activateRow(_ row: Int) {
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileTreeNode else { return }
        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else {
            onSelectFile?(node.url.path)
        }
    }

    /// Handle keys not covered by NSOutlineView's built-in arrow navigation.
    /// Returns true if consumed.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let row = outlineView.selectedRow
        switch event.keyCode {
        case 36, 76: // Return / keypad Enter → open file or toggle folder
            activateRow(row)
            return true
        case 51, 117: // Cmd+Delete → move to trash
            guard event.modifierFlags.contains(.command),
                  row >= 0, outlineView.item(atRow: row) is FileTreeNode else { return false }
            trashSelectedRow(row)
            return true
        default:
            return false
        }
    }

    private func trashSelectedRow(_ row: Int) {
        guard let node = outlineView.item(atRow: row) as? FileTreeNode else { return }
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            refreshDirectory(node.url.deletingLastPathComponent())
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Context menu

    /// The node the menu currently targets, or nil for the root (empty-area click).
    private func contextNode() -> FileTreeNode? {
        let row = outlineView.clickedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? FileTreeNode
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let node = contextNode()

        // The directory new items are created in: the clicked dir, the clicked
        // file's parent, or the tree root.
        if node?.isDirectory ?? true {
            menu.addItem(makeItem("New File", #selector(newFileAction)))
            menu.addItem(makeItem("New Folder", #selector(newFolderAction)))
        } else {
            menu.addItem(makeItem("New File", #selector(newFileAction)))
            menu.addItem(makeItem("New Folder", #selector(newFolderAction)))
        }

        if node != nil {
            menu.addItem(.separator())
            menu.addItem(makeItem("Rename", #selector(renameAction)))
            menu.addItem(makeItem("Duplicate", #selector(duplicateAction)))
            menu.addItem(makeItem("Move to Trash", #selector(trashAction)))
            menu.addItem(.separator())
            menu.addItem(makeItem("Reveal in Finder", #selector(revealAction)))
            menu.addItem(makeItem("Copy Path", #selector(copyPathAction)))
            menu.addItem(makeItem("Copy Relative Path", #selector(copyRelativePathAction)))
        }

        menu.addItem(.separator())
        let hiddenItem = makeItem(showHidden ? "Hide Hidden Files" : "Show Hidden Files", #selector(toggleHiddenAction))
        menu.addItem(hiddenItem)
        menu.addItem(makeItem("Refresh", #selector(refreshAction)))
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Directory that new entries should be created in for the current context.
    private func targetDirectoryURL() -> URL? {
        if let node = contextNode() {
            return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        }
        return rootPath.map { URL(fileURLWithPath: $0) }
    }

    @objc private func newFileAction() {
        guard let dir = targetDirectoryURL() else { return }
        guard let name = promptForName(title: "New File", placeholder: "untitled.txt") else { return }
        let dest = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            presentError("“\(name)” already exists.")
            return
        }
        do {
            try Data().write(to: dest)
            refreshDirectory(dir)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    @objc private func newFolderAction() {
        guard let dir = targetDirectoryURL() else { return }
        guard let name = promptForName(title: "New Folder", placeholder: "untitled folder") else { return }
        let dest = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            refreshDirectory(dir)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    @objc private func renameAction() {
        guard let node = contextNode() else { return }
        let current = node.url.lastPathComponent
        guard let name = promptForName(title: "Rename", placeholder: current, initial: current),
              name != current else { return }
        let dest = node.url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: node.url, to: dest)
            refreshDirectory(node.url.deletingLastPathComponent())
        } catch {
            presentError(error.localizedDescription)
        }
    }

    @objc private func duplicateAction() {
        guard let node = contextNode() else { return }
        let dir = node.url.deletingLastPathComponent()
        let dest = uniqueCopyURL(for: node.url)
        do {
            try FileManager.default.copyItem(at: node.url, to: dest)
            refreshDirectory(dir)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    @objc private func trashAction() {
        guard let node = contextNode() else { return }
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            refreshDirectory(node.url.deletingLastPathComponent())
        } catch {
            presentError(error.localizedDescription)
        }
    }

    @objc private func revealAction() {
        guard let node = contextNode() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc private func copyPathAction() {
        guard let node = contextNode() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }

    @objc private func copyRelativePathAction() {
        guard let node = contextNode() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.relativePath(of: node.url, from: rootPath), forType: .string)
    }

    /// Path of `url` relative to the worktree `root` (no leading slash). Falls
    /// back to the last path component when `url` is outside `root`.
    static func relativePath(of url: URL, from root: String?) -> String {
        guard let root else { return url.lastPathComponent }
        let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
        let full = url.standardizedFileURL.path
        if full == rootPath { return "." }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if full.hasPrefix(prefix) { return String(full.dropFirst(prefix.count)) }
        return url.lastPathComponent
    }

    @objc private func toggleHiddenAction() {
        showHidden.toggle()
    }

    @objc private func refreshAction() {
        // Drop cached children so the whole visible tree re-reads from disk.
        for node in rootNodes { node.children = nil }
        reload()
    }

    // MARK: - Refresh helpers

    /// Re-read `dir` from disk and reload the matching row (or the whole tree
    /// when `dir` is the root), keeping it expanded.
    private func refreshDirectory(_ dir: URL) {
        if dir.standardizedFileURL.path == (rootPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }) {
            for node in rootNodes { node.children = nil }
            reload()
            return
        }
        if let node = findNode(for: dir) {
            node.children = nil
            outlineView.reloadItem(node, reloadChildren: true)
            outlineView.expandItem(node)
        } else {
            reload()
        }
    }

    private func findNode(for url: URL, in nodes: [FileTreeNode]? = nil) -> FileTreeNode? {
        let target = url.standardizedFileURL.path
        let list = nodes ?? rootNodes
        for node in list {
            if node.url.standardizedFileURL.path == target { return node }
            if let kids = node.children, let found = findNode(for: url, in: kids) {
                return found
            }
        }
        return nil
    }

    private func uniqueCopyURL(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var index = 2
        var candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)")
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) copy \(index)" : "\(base) copy \(index).\(ext)")
            index += 1
        }
        return candidate
    }

    // MARK: - Prompts

    private func promptForName(title: String, placeholder: String, initial: String? = nil) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Operation failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - FileOutlineView

/// Outline view that forwards key presses to the controller (Return, Cmd+Delete)
/// while preserving NSOutlineView's built-in arrow-key navigation.
final class FileOutlineView: NSOutlineView {
    /// Return true to consume the event; false to fall through to default handling.
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

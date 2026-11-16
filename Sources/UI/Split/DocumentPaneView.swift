import AppKit

/// The worktree's document pane (`SplitNode.document`): the files and changes
/// opened from the side panel's Files / Changes tabs or a terminal's Preview,
/// one tab each, in a pane of the split tree rather than an overlay over it.
/// Split from the focused pane the way ⌘D splits one; one per worktree, so a
/// later open adds a tab here instead of splitting again.
///
/// Each tab's content keeps the overlay's toolbar (Close / Save / Preview) in
/// its embedded form (`CenterOverlayView(embedded:)`): no Esc, and ⌘S only
/// while the keyboard is in this pane, so neither is taken from a terminal.
final class DocumentPaneView: NSView {

    enum Item: Equatable {
        case file(path: String)
        case change(worktreePath: String, path: String)

        var key: String {
            switch self {
            case .file(let path): return "file:\(path)"
            case .change(_, let path): return "change:\(path)"
            }
        }

        var title: String {
            switch self {
            case .file(let path):
                return URL(fileURLWithPath: path).lastPathComponent
            case .change(_, let path):
                let name = URL(fileURLWithPath: path).lastPathComponent
                return name.isEmpty ? "Changes" : "Δ \(name)"
            }
        }
    }

    private struct Tab {
        let item: Item
        var content: NSView
    }

    /// A click anywhere in the pane: it becomes the focused pane.
    var onFocusAcquired: (() -> Void)?
    /// The last tab closed: the pane should leave the tree.
    var onEmpty: (() -> Void)?
    /// Tabs opened, closed or switched (the compact pane tabs show the title).
    var onTabsChange: (() -> Void)?

    private let strip = EditTabStripView()
    private let host = NSView()
    private var tabs: [Tab] = []
    private var activeKey: String?
    private var clickMonitor: Any?

    /// The tab on screen's title.
    var title: String {
        tabs.first(where: { $0.item.key == activeKey })?.item.title ?? "Files"
    }

    var itemsForTesting: [Item] { tabs.map(\.item) }
    var activeItemForTesting: Item? { tabs.first(where: { $0.item.key == activeKey })?.item }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Documents")

        strip.translatesAutoresizingMaskIntoConstraints = false
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)
        addSubview(host)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: EditTabStripView.stripHeight),
            host.topAnchor.constraint(equalTo: strip.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        strip.onSelect = { [weak self] key in self?.select(key) }
        strip.onClose = { [weak self] key in self?.close(key) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    // MARK: Tabs

    /// Show `item`, opening a tab for it unless it has one. A change is read
    /// again when reopened (the diff moves on); a file keeps its editor, and
    /// with it unsaved edits.
    func open(_ item: Item) {
        if let i = tabs.firstIndex(where: { $0.item.key == item.key }) {
            if case .change = item {
                let old = tabs[i].content
                tabs[i].content = makeContent(item)
                retire(old)
            }
        } else {
            tabs.append(Tab(item: item, content: makeContent(item)))
        }
        select(item.key)
    }

    func select(_ key: String) {
        guard tabs.contains(where: { $0.item.key == key }) else { return }
        activeKey = key
        showActive()
        onTabsChange?()
    }

    /// Close a tab. The one on screen stays on screen; closing it shows its
    /// left neighbour. The last one empties the pane (`onEmpty`).
    func close(_ key: String) {
        guard let i = tabs.firstIndex(where: { $0.item.key == key }) else { return }
        let closed = tabs.remove(at: i)
        retire(closed.content)
        guard !tabs.isEmpty else {
            activeKey = nil
            onEmpty?()
            return
        }
        if activeKey == key {
            activeKey = tabs[max(0, i - 1)].item.key
        }
        showActive()
        onTabsChange?()
    }

    func closeActive() {
        if let activeKey { close(activeKey) }
    }

    /// Hand the keyboard to the tab on screen: its text view when it has one.
    func focusContent() {
        guard let content = tabs.first(where: { $0.item.key == activeKey })?.content,
              let window else { return }
        let target = Self.firstTextView(in: content) ?? content
        if window.firstResponder !== target { window.makeFirstResponder(target) }
    }

    // MARK: Click → focus

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        guard window != nil else { return }
        // The editor and the diff take their own clicks, so the pane would never
        // see them in mouseDown; watch them instead, and leave them be.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor else { return event }
            if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                self.onFocusAcquired?()
            }
            return event
        }
    }

    // MARK: Private

    private func showActive() {
        guard let tab = tabs.first(where: { $0.item.key == activeKey }) else { return }
        for sub in host.subviews where sub !== tab.content { sub.isHidden = true }
        if tab.content.superview !== host {
            tab.content.removeFromSuperview()
            tab.content.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(tab.content)
            NSLayoutConstraint.activate([
                tab.content.topAnchor.constraint(equalTo: host.topAnchor),
                tab.content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                tab.content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                tab.content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
        tab.content.isHidden = false
        strip.apply(items: tabs.map { EditTabStripView.Item(id: $0.item.key, title: $0.item.title, closable: true) },
                    selectedId: activeKey)
    }

    /// Out of the hierarchy now; CodeEdit teardown on the next turn so a close
    /// is not held up by it.
    private func retire(_ view: NSView) {
        view.removeFromSuperview()
        DispatchQueue.main.async { _ = view }
    }

    private func makeContent(_ item: Item) -> NSView {
        let key = item.key
        let onClose: () -> Void = { [weak self] in self?.close(key) }
        switch item {
        case .change(let worktreePath, let path):
            return CenterOverlayView(content: DiffReviewView(worktreePath: worktreePath, selectedPath: path),
                                     embedded: true, onClose: onClose)
        case .file(let path):
            if let media = MediaPreviewView.make(path: path) {
                return CenterOverlayView(content: media, embedded: true, onClose: onClose)
            }
            // A spinner first; bytes are read off-main, then the editor takes its place.
            let loading = CenterOverlayView(content: EditorLoadingView(), embedded: true, onClose: onClose)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let text = FileContentView.readContent(at: path)
                DispatchQueue.main.async {
                    guard let self,
                          let i = self.tabs.firstIndex(where: { $0.item.key == key }),
                          self.tabs[i].content === loading else { return }
                    self.tabs[i].content = Self.fileView(path: path, text: text, onClose: onClose)
                    self.retire(loading)
                    if self.activeKey == key {
                        self.showActive()
                        if self.window?.firstResponder === loading { self.focusContent() }
                    }
                }
            }
            return loading
        }
    }

    /// The editor (with Save / Preview) for text, else a read-only fallback.
    private static func fileView(path: String, text: String?, onClose: @escaping () -> Void) -> NSView {
        guard let text else {
            let fallback = MediaPreviewView.fallback(path: path) ?? FileContentView(path: path)
            return CenterOverlayView(content: fallback, embedded: true, onClose: onClose)
        }
        let editor = CodeEditorView(fileURL: URL(fileURLWithPath: path), text: text)
        weak var overlayRef: CenterOverlayView?
        let overlay = CenterOverlayView(
            content: editor,
            onSave: { [weak editor] in _ = editor?.save() },
            onPreview: editor.isPreviewable ? { [weak editor] in
                guard let editor else { return }
                overlayRef?.setPreviewing(editor.togglePreview())
            } : nil,
            embedded: true,
            onClose: onClose
        )
        overlayRef = overlay
        editor.onDirtyChange = { [weak overlay] dirty in overlay?.setDirty(dirty) }
        return overlay
    }

    private static func firstTextView(in view: NSView) -> NSView? {
        if let text = view as? NSTextView, text.acceptsFirstResponder { return text }
        for sub in view.subviews where !sub.isHidden {
            if let found = firstTextView(in: sub) { return found }
        }
        return nil
    }
}

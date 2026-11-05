import AppKit
import SwiftUI
import CodeEditSourceEditor
import CodeEditLanguages
import Combine

// MARK: - Model

/// Shared editor state between the AppKit host and the SwiftUI `SourceEditor`.
final class CodeEditorModel: ObservableObject {
    @Published var text: String
    @Published var editorState = SourceEditorState()
    /// Last text persisted to disk — drives the dirty indicator.
    @Published var savedText: String

    let fileURL: URL
    let language: CodeLanguage
    let scrollCoordinator = CodeEditorScrollCoordinator()

    var isDirty: Bool { text != savedText }

    init(fileURL: URL, text: String) {
        self.fileURL = fileURL
        self.text = text
        self.savedText = text
        self.language = CodeLanguage.detectLanguageFrom(url: fileURL)
    }
}

// MARK: - SwiftUI bridge

private struct CodeEditorSwiftUIView: View {
    @ObservedObject var model: CodeEditorModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SourceEditor(
            $model.text,
            language: model.language,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: colorScheme == .dark ? .seahelmDark : .seahelmLight,
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    wrapLines: false
                ),
                behavior: .init(isEditable: true),
                // Minimap + folding ribbon are on by upstream default and dominate
                // open/scroll cost for a side-panel viewer. Keep the gutter only.
                peripherals: .init(
                    showGutter: true,
                    showMinimap: false,
                    showFoldingRibbon: false
                )
            ),
            state: $model.editorState,
            coordinators: [model.scrollCoordinator]
        )
    }
}

/// CodeEditSourceEditor enables horizontal scrolling when wrapping is off, but
/// its overlay scrollers inherit macOS's auto-hide behavior. Keep the horizontal
/// thumb visible so long configuration lines remain discoverable and draggable.
final class CodeEditorScrollCoordinator: TextViewCoordinator {
    /// The editor's controller, for replacing its text from outside: the
    /// `SourceEditor` string binding only flows up, from the view.
    private(set) weak var controller: TextViewController?

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
    }

    func controllerDidAppear(controller: TextViewController) {
        self.controller = controller
        Self.configure(controller.scrollView)
    }

    /// Replace the whole text, keeping the scroll offset. Returns false while
    /// the editor has not been built yet.
    @discardableResult
    func replaceText(_ text: String) -> Bool {
        guard let controller else { return false }
        let clip = controller.scrollView.contentView
        let origin = clip.bounds.origin
        controller.textView.setText(text)
        // setText lays out on its own schedule; restore once it has.
        DispatchQueue.main.async {
            let maxY = max(0, (controller.scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            clip.scroll(to: NSPoint(x: origin.x, y: min(origin.y, maxY)))
            controller.scrollView.reflectScrolledClipView(clip)
        }
        return true
    }

    static func configure(_ scrollView: NSScrollView) {
        scrollView.hasHorizontalScroller = true
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .overlay
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

// MARK: - AppKit host

/// Editable, syntax-highlighted code editor (CodeEditSourceEditor) wrapped for
/// use inside the AppKit center overlay. Construct from already-loaded UTF-8
/// text so file I/O can stay off the main thread at the call site.
final class CodeEditorView: NSView {
    private let model: CodeEditorModel
    private var hosting: NSHostingView<CodeEditorSwiftUIView>!
    private var previewView: PreviewWebView?
    private(set) var isPreviewing = false
    private var watcher: FileChangeWatcher?
    private var conflictBanner: ExternalChangeBanner?

    /// Invoked whenever the dirty state changes, so the host chrome can update.
    var onDirtyChange: ((Bool) -> Void)?

    var isDirty: Bool { model.isDirty }

    private var fileExtension: String { model.fileURL.pathExtension.lowercased() }
    private var isMarkdown: Bool { ["md", "markdown"].contains(fileExtension) }
    private var isHTML: Bool { ["html", "htm"].contains(fileExtension) }

    /// Markdown and HTML files get a preview toggle in the overlay header.
    var isPreviewable: Bool { isMarkdown || isHTML }

    init(fileURL: URL, text: String) {
        self.model = CodeEditorModel(fileURL: fileURL, text: text)
        super.init(frame: .zero)

        let hosting = NSHostingView(rootView: CodeEditorSwiftUIView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // Keep SwiftUI content within our frame — otherwise it expands into the
        // window safe area and the gutter draws up over the overlay header.
        hosting.safeAreaRegions = []
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.hosting = hosting

        observeDirty()
        watcher = FileChangeWatcher(path: fileURL.path) { [weak self] in self?.fileChangedOnDisk() }

        // WebKit process launch used to sit on the open path via prewarm().
        // Defer until after the first frame so the editor can paint first.
        if isPreviewable {
            DispatchQueue.main.async { [weak self] in
                self?.makePreviewView().prewarm()
            }
        }
    }

    /// Creates (once) the hidden preview view layered over the editor.
    @discardableResult
    private func makePreviewView() -> PreviewWebView {
        if let previewView { return previewView }
        let view = PreviewWebView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        previewView = view
        return view
    }

    /// Toggle between the editor and a rendered Markdown preview. Returns the
    /// new previewing state.
    @discardableResult
    func togglePreview() -> Bool {
        isPreviewing.toggle()
        if isPreviewing {
            let preview = makePreviewView()
            renderPreview(preview, keepScroll: false)
            preview.isHidden = false
            hosting.isHidden = true
        } else {
            previewView?.isHidden = true
            hosting.isHidden = false
        }
        return isPreviewing
    }

    private func renderPreview(_ preview: PreviewWebView, keepScroll: Bool) {
        let directory = model.fileURL.deletingLastPathComponent()
        if isHTML {
            preview.renderHTML(model.text, baseURL: directory, keepScroll: keepScroll)
        } else {
            preview.render(markdown: model.text, baseDirectory: directory, keepScroll: keepScroll)
        }
    }

    // MARK: - Changes on disk

    /// The file changed on disk (an agent writing it, `git checkout`). Read it
    /// off main, then follow `ExternalChange`: show it when the buffer holds
    /// no edits, keeping the editor's and the preview's scroll offsets; ask
    /// when it does.
    private func fileChangedOnDisk() {
        let path = model.fileURL.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let disk = FileContentView.readContent(at: path)
            DispatchQueue.main.async { self?.apply(disk: disk) }
        }
    }

    private func apply(disk: String?) {
        switch ExternalChange.decide(disk: disk, buffer: model.text, saved: model.savedText) {
        case .ignore:
            break
        case .adopt:
            model.savedText = model.text
            onDirtyChange?(false)
            hideConflictBanner()
        case .reload:
            if let disk { showDiskText(disk) }
        case .conflict:
            showConflictBanner()
        }
    }

    /// Put `disk` in the editor (and the preview, if it is showing) as the saved
    /// text, keeping both scroll offsets.
    private func showDiskText(_ disk: String) {
        model.savedText = disk
        model.text = disk
        model.scrollCoordinator.replaceText(disk)
        onDirtyChange?(false)
        hideConflictBanner()
        if isPreviewing, let previewView { renderPreview(previewView, keepScroll: true) }
    }

    private func showConflictBanner() {
        guard conflictBanner == nil else { return }
        let banner = ExternalChangeBanner(
            onReload: { [weak self] in
                guard let self else { return }
                let path = self.model.fileURL.path
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let disk = FileContentView.readContent(at: path)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let disk { self.showDiskText(disk) } else { self.hideConflictBanner() }
                    }
                }
            },
            onKeep: { [weak self] in self?.hideConflictBanner() })
        banner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(banner, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: topAnchor),
            banner.leadingAnchor.constraint(equalTo: leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        conflictBanner = banner
    }

    private func hideConflictBanner() {
        conflictBanner?.removeFromSuperview()
        conflictBanner = nil
    }

    var isShowingConflictBannerForTesting: Bool { conflictBanner != nil }
    func applyDiskTextForTesting(_ disk: String?) { apply(disk: disk) }
    var bufferTextForTesting: String { model.text }
    func typeForTesting(_ text: String) { model.text = text }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        cancellable?.cancel()
        watcher?.stop()
    }

    private var cancellable: AnyCancellableBox?

    private func observeDirty() {
        // Lightweight Combine sink on the @Published text to report dirty state.
        cancellable = AnyCancellableBox(model.$text.sink { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.onDirtyChange?(self.model.isDirty) }
        })
    }

    /// Persist the buffer to disk. Returns false (and shows an alert) on failure.
    @discardableResult
    func save() -> Bool {
        do {
            try model.text.write(to: model.fileURL, atomically: true, encoding: .utf8)
            model.savedText = model.text
            onDirtyChange?(false)
            return true
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not save file"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
    }
}

// MARK: - Changed-on-disk banner

/// Across the top of an editor whose file changed on disk while it held
/// unsaved edits: reload the disk's version, or keep editing (a save then
/// overwrites the disk).
final class ExternalChangeBanner: NSView {
    private let onReload: () -> Void
    private let onKeep: () -> Void

    init(onReload: @escaping () -> Void, onKeep: @escaping () -> Void) {
        self.onReload = onReload
        self.onKeep = onKeep
        super.init(frame: .zero)
        wantsLayer = true

        let label = NSTextField(labelWithString: "This file changed on disk.")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadTapped))
        let keep = NSButton(title: "Keep My Edits", target: self, action: #selector(keepTapped))
        for button in [reload, keep] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }
        let stack = NSStackView(views: [label, NSView(), keep, reload])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setAccessibilityIdentifier("editor.external-change-banner")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = SemanticColors.attention.withAlphaComponent(0.18).cgColor
        }
    }

    @objc private func reloadTapped() { onReload() }
    @objc private func keepTapped() { onKeep() }
}

// MARK: - Loading placeholder

/// Lightweight stand-in shown while file bytes are read off the main thread.
final class EditorLoadingView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = SemanticColors.panel.cgColor
        }

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

// MARK: - Combine box

/// Tiny wrapper so we can hold an AnyCancellable without importing Combine into
/// the view's public surface.
private final class AnyCancellableBox {
    private let cancellable: AnyCancellable
    init(_ cancellable: AnyCancellable) { self.cancellable = cancellable }
    func cancel() { cancellable.cancel() }
}

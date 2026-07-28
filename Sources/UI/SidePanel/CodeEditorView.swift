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
            state: $model.editorState
        )
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
            let directory = model.fileURL.deletingLastPathComponent()
            if isHTML {
                preview.renderHTML(model.text, baseURL: directory)
            } else {
                preview.render(markdown: model.text, baseDirectory: directory)
            }
            preview.isHidden = false
            hosting.isHidden = true
        } else {
            previewView?.isHidden = true
            hosting.isHidden = false
        }
        return isPreviewing
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        cancellable?.cancel()
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

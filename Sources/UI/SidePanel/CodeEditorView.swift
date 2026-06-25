import AppKit
import SwiftUI
import CodeEditSourceEditor
import CodeEditLanguages

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
                behavior: .init(isEditable: true)
            ),
            state: $model.editorState
        )
    }
}

// MARK: - AppKit host

/// Editable, syntax-highlighted code editor (CodeEditSourceEditor) wrapped for
/// use inside the AppKit center overlay. Returns nil for files that can't be
/// read as UTF-8 text so callers can fall back to a placeholder.
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

    init?(path: String) {
        guard let text = FileContentView.readContent(at: path) else { return nil }
        self.model = CodeEditorModel(fileURL: URL(fileURLWithPath: path), text: text)
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
    }

    /// Toggle between the editor and a rendered Markdown preview. Returns the
    /// new previewing state.
    @discardableResult
    func togglePreview() -> Bool {
        isPreviewing.toggle()
        if isPreviewing {
            let preview = previewView ?? {
                let v = PreviewWebView()
                v.translatesAutoresizingMaskIntoConstraints = false
                addSubview(v)
                NSLayoutConstraint.activate([
                    v.topAnchor.constraint(equalTo: topAnchor),
                    v.leadingAnchor.constraint(equalTo: leadingAnchor),
                    v.trailingAnchor.constraint(equalTo: trailingAnchor),
                    v.bottomAnchor.constraint(equalTo: bottomAnchor),
                ])
                previewView = v
                return v
            }()
            if isHTML {
                preview.renderHTML(model.text, baseURL: model.fileURL.deletingLastPathComponent())
            } else {
                preview.render(markdown: model.text)
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

// MARK: - Combine box

import Combine

/// Tiny wrapper so we can hold an AnyCancellable without importing Combine into
/// the view's public surface.
private final class AnyCancellableBox {
    private let cancellable: AnyCancellable
    init(_ cancellable: AnyCancellable) { self.cancellable = cancellable }
    func cancel() { cancellable.cancel() }
}

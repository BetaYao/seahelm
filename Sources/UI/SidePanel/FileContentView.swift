import AppKit

final class FileContentView: NSView {

    // MARK: - Static read helper

    /// Returns the file's text if it is valid UTF-8 and its byte size is ≤ maxBytes; otherwise nil.
    /// Checks file size via FileManager before reading to avoid loading oversized files.
    static func readContent(at path: String, maxBytes: Int = 1_048_576) -> String? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? Int,
              fileSize <= maxBytes else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - Init

    init(path: String) {
        super.init(frame: .zero)
        let content = FileContentView.readContent(at: path)
        if let text = content {
            setupTextView(text: text)
        } else {
            setupPlaceholder()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Private setup

    private func setupTextView(text: String) {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = SemanticColors.panel

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = SemanticColors.panel
        textView.textColor = SemanticColors.text
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.string = text
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false

        scrollView.documentView = textView

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func setupPlaceholder() {
        let label = NSTextField(labelWithString: "Cannot preview this file")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = SemanticColors.muted
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

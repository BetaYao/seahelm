import AppKit

struct ModalConfig {
    let title: String
    let subtitle: String
    var placeholder: String = ""
    var initialValue: String = ""
    var confirmText: String = "Confirm"
    var isMultiline: Bool = false
}

final class UnifiedModalView: NSView {
    private let confirmButton = NSButton()
    private let cancelButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        confirmButton.title = "Confirm"
        confirmButton.bezelStyle = .rounded
        confirmButton.isBordered = true
        confirmButton.setAccessibilityIdentifier("modal.confirm")
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(confirmButton)

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.isBordered = true
        cancelButton.setAccessibilityIdentifier("modal.cancel")
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cancelButton)

        NSLayoutConstraint.activate([
            cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            cancelButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            confirmButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
            confirmButton.bottomAnchor.constraint(equalTo: cancelButton.bottomAnchor),
        ])
    }

    func show(config: ModalConfig) {
        confirmButton.title = config.confirmText
        isHidden = false
    }
}

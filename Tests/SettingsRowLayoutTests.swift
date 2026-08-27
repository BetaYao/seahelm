import XCTest
import AppKit
@testable import seahelm

/// Layout regression tests for the settings row builder.
///
/// A row whose title silently fails to appear looks like a missing feature, not
/// a layout bug, so the geometry is asserted rather than eyeballed.
final class SettingsRowLayoutTests: XCTestCase {

    private func laidOut(_ row: NSView, width: CGFloat = 600) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        return row
    }

    private func labels(in row: NSView) -> [NSTextField] {
        row.subviews.compactMap { $0 as? NSTextField }
    }

    func testTitleIsVisibleOnAPlainRow() {
        let row = laidOut(SettingsRow.make("Name", control: SettingsTextField()))
        let title = labels(in: row).first { $0.stringValue == "Name" }

        XCTAssertNotNil(title, "the title label must exist")
        XCTAssertGreaterThan(title?.frame.width ?? 0, 0, "title collapsed to zero width")
        XCTAssertGreaterThan(title?.frame.height ?? 0, 0, "title collapsed to zero height")
    }

    /// The regression: rows carrying a subtitle rendered as a bare control, with
    /// both the title and the hint invisible.
    func testTitleAndHintAreVisibleOnASubtitledRow() {
        let row = laidOut(SettingsRow.make("Sender matches",
                                           subtitle: "Regex over the sender handle.",
                                           control: SettingsTextField()))
        let title = labels(in: row).first { $0.stringValue == "Sender matches" }
        let hint = labels(in: row).first { $0.stringValue.hasPrefix("Regex over") }

        XCTAssertNotNil(title, "the title label must exist")
        XCTAssertNotNil(hint, "the hint label must exist")
        XCTAssertGreaterThan(title?.frame.width ?? 0, 0, "title collapsed to zero width")
        XCTAssertGreaterThan(title?.frame.height ?? 0, 0, "title collapsed to zero height")
        XCTAssertGreaterThan(hint?.frame.height ?? 0, 0, "hint collapsed to zero height")
    }

    /// The title sits above the hint, and neither overlaps the control column.
    /// `NSView` is not flipped, so "above" means a *larger* y.
    func testSubtitledRowStacksTitleAboveHint() {
        let field = SettingsTextField()
        let row = laidOut(SettingsRow.make("Body matches",
                                           subtitle: "Regex over the message text.",
                                           control: field))
        guard let title = labels(in: row).first(where: { $0.stringValue == "Body matches" }),
              let hint = labels(in: row).first(where: { $0.stringValue.hasPrefix("Regex over") })
        else { return XCTFail("labels missing") }

        XCTAssertGreaterThan(title.frame.minY, hint.frame.minY, "hint should sit below the title")
        XCTAssertLessThan(title.frame.maxX, field.frame.minX, "title must not run under the control")
        XCTAssertGreaterThan(row.frame.height, 40, "row must grow to fit both labels")
    }

    // MARK: - Rules card

    /// Regression: the rules card pinned both the form stack and the "nothing
    /// selected" hint to all four of its edges. Two competing height equalities
    /// left Auto Layout squeezing the form, and the squeeze fell on the labels —
    /// the fixed-height fields survived, so the form rendered as bare inputs
    /// with no titles at all.
    func testRuleFormRowsKeepTheirLabelsWhenARuleIsSelected() {
        let view = IMessageRulesView(rules: [
            IMessageRule(name: "aliyun", prompt: "{{text}}",
                         target: .init(kind: .worktree, value: "/work/ops")),
        ])
        view.selectRule(at: 0)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        let titles = allLabels(in: view).map(\.stringValue)
        for expected in ["Enabled", "Name", "Sender matches", "Body matches", "Prompt"] {
            XCTAssertTrue(titles.contains(expected), "form is missing the \(expected) label")
        }

        for label in allLabels(in: view) where label.stringValue == "Sender matches" {
            XCTAssertGreaterThan(label.frame.height, 0, "label squeezed to nothing")
            XCTAssertGreaterThan(label.frame.width, 0, "label squeezed to nothing")
        }
    }

    // MARK: - Action row with a leading status

    /// The Host Gateway page is the first caller to pass `leading:`, and it puts
    /// a status line there whose text is a URL — long enough to shove the button
    /// off the row if the label refuses to compress.
    func testActionRowKeepsItsLeadingStatusBesideTheButton() {
        let status = NSTextField(labelWithString:
            "Serving https://a-rather-long-tunnel-hostname.example.dev/")
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let button = SettingsControls.button("Open web client", target: self, action: #selector(noop))
        let row = laidOut(SettingsRow.actions([button], leading: [status]))

        // Both sit inside their own stack view, so compare in the row's space.
        let statusFrame = status.convert(status.bounds, to: row)
        let buttonFrame = button.convert(button.bounds, to: row)

        XCTAssertGreaterThan(statusFrame.width, 0, "status collapsed to zero width")
        XCTAssertGreaterThan(statusFrame.height, 0, "status collapsed to zero height")
        XCTAssertGreaterThan(buttonFrame.width, 0, "button collapsed to zero width")
        XCTAssertLessThanOrEqual(statusFrame.maxX, buttonFrame.minX,
                                 "status must not run under the button")
        XCTAssertLessThanOrEqual(buttonFrame.maxX, row.frame.width,
                                 "button pushed outside the row")
    }

    @objc private func noop() {}

    private func allLabels(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { child -> [NSTextField] in
            let here = (child as? NSTextField).map { [$0] } ?? []
            return here + allLabels(in: child)
        }
    }

}

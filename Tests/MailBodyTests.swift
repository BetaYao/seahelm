import XCTest
@testable import seahelm

final class MailBodyTests: XCTestCase {
    // MARK: - Quoted history

    func testKeepsAPlainBody() {
        XCTAssertEqual(MailBody.newContent(of: "ship it"), "ship it")
    }

    func testStripsGmailQuoteBlock() {
        let body = """
        /pane 2

        On Wed, Aug 5, 2026 at 1:23 PM Matt Chow <m@example.com> wrote:
        > **Panes** - 3
        > 1. Claude
        """
        XCTAssertEqual(MailBody.newContent(of: body), "/pane 2")
    }

    /// Gmail wraps the attribution at arbitrary widths, so "wrote:" is regularly
    /// pushed onto its own line — where a naive suffix check misses it.
    func testStripsAttributionWrappedOntoTheNextLine() {
        let body = """
        looks good

        On Wed, Aug 5, 2026 at 1:23 PM A Very Long Display Name <m@example.com>
        wrote:
        > previous
        """
        XCTAssertEqual(MailBody.newContent(of: body), "looks good")
    }

    /// Gmail's Chinese attribution opens with the sender's own name, not with
    /// "在", so a prefix test misses it and the entire quote reaches the agent —
    /// which is exactly what happened in the field.
    func testStripsChineseAttributionThatStartsWithTheSenderName() {
        let body = """
        你在干什么？

        亮亮(Leon) zhoujinliang@gmail.com 于 2026年8月5日周三 17:27写道：
        > **Panes** — 21
        """
        XCTAssertEqual(MailBody.newContent(of: body), "你在干什么？")
    }

    func testStripsEnglishAttributionThatStartsWithTheSenderName() {
        let body = "ok\n\nLeon <a@b.com> wrote:\n> quoted"
        XCTAssertEqual(MailBody.newContent(of: body), "ok")
    }

    /// The marker is how the line ends, so ordinary prose that merely mentions
    /// writing must survive.
    func testKeepsProseThatIsNotAnAttribution() {
        XCTAssertEqual(MailBody.newContent(of: "tell me what he wrote about it"),
                       "tell me what he wrote about it")
    }

    func testStripsChineseAttribution() {
        let body = """
        继续

        在 2026年8月5日 星期三 Matt <m@example.com> 写道：
        > 上一封
        """
        XCTAssertEqual(MailBody.newContent(of: body), "继续")
    }

    func testStripsOutlookDividerAndForwardHeader() {
        XCTAssertEqual(MailBody.newContent(of: "yes\n________________________________\nFrom: someone"), "yes")
        XCTAssertEqual(MailBody.newContent(of: "yes\nFrom: someone\nSent: today"), "yes")
    }

    func testStripsSignature() {
        XCTAssertEqual(MailBody.newContent(of: "run the tests\n--\nSent from my phone"), "run the tests")
    }

    func testKeepsBodyWhenNothingIsQuoted() {
        let body = "line one\nline two\n\nline four"
        XCTAssertEqual(MailBody.newContent(of: body), body)
    }

    func testHandlesCRLFLineEndings() {
        XCTAssertEqual(MailBody.newContent(of: "/pane\r\n\r\n> quoted\r\n"), "/pane")
    }

    /// A quote marker inside the new text still ends it — mail gives us no way
    /// to tell an intentional ">" from the client's own quoting.
    func testTreatsAnyLeadingQuoteMarkerAsTheBoundary() {
        XCTAssertEqual(MailBody.newContent(of: "hi\n> not really a quote"), "hi")
    }

    // MARK: - Signature round-trip

    /// The whole reason the cheatsheet sits under `-- `: when the user replies
    /// and their client quotes it back, stripping must return the new text only.
    func testSignatureSurvivesARoundTrip() {
        let sent = MailSignature.appended(to: "Pane is waiting for you.")
        XCTAssertTrue(sent.contains("/pane"), "the command list should ship with every mail")

        let quoted = sent.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        let reply = "/pane 2\n\nOn Wed, Aug 5, 2026 at 1:23 PM Seahelm <s@example.com> wrote:\n\(quoted)"

        XCTAssertEqual(MailBody.newContent(of: reply), "/pane 2")
    }

    /// Our own signature is stripped even when the client drops the attribution
    /// line and simply appends the previous body.
    func testOwnSignatureIsStrippedWithoutAnAttributionLine() {
        XCTAssertEqual(MailBody.newContent(of: MailSignature.appended(to: "/pane")), "/pane")
    }
}

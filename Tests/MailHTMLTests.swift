import XCTest
@testable import seahelm

final class MailHTMLTests: XCTestCase {
    // MARK: - Rendering

    func testRendersBoldAndCode() {
        let html = MailHTML.render(markdown: "**Panes** — `/pane 2`")
        XCTAssertTrue(html.contains("<strong>Panes</strong>"), html)
        XCTAssertTrue(html.contains("/pane 2</code>"), html)
    }

    /// Agent output is arbitrary text. Escaping has to run before the markdown
    /// pass or a pane title could inject markup into the mail.
    func testEscapesMarkupBeforeRenderingMarkdown() {
        let html = MailHTML.render(markdown: "<script>alert(1)</script>")
        XCTAssertFalse(html.contains("<script>"), html)
        XCTAssertTrue(html.contains("&lt;script&gt;"), html)
    }

    func testEscapesAmpersandsAndAngleBracketsInPlaceholders() {
        XCTAssertEqual(MailHTML.escape("a & b <n>"), "a &amp; b &lt;n&gt;")
    }

    /// Terminal output is full of stray backticks and asterisks; one unpaired
    /// marker must not swallow the rest of the mail into a code span.
    func testLeavesUnpairedMarkersAsText() {
        let html = MailHTML.render(markdown: "cost is 50% * 2 and a stray ` here")
        XCTAssertTrue(html.contains("stray ` here"), html)
        XCTAssertFalse(html.contains("<code"), html)
    }

    func testDocumentCarriesTheCommandListAndTheContent() {
        let html = MailHTML.document(body: "**Panes** — 1")
        XCTAssertTrue(html.contains("<strong>Panes</strong>"), "content is rendered")
        for entry in MailSignature.entries {
            XCTAssertTrue(html.contains(MailHTML.escape(entry.command)), "missing \(entry.command)")
        }
    }

    func testDocumentPreservesTreeAlignment() {
        // The listings are aligned trees; a proportional font would lose the
        // alignment the reply's numbering depends on.
        XCTAssertTrue(MailHTML.document(body: "x").contains("white-space:pre-wrap"))
    }

    // MARK: - MIME

    private func mime(body: String) -> String {
        let intent = OutboundMailIntent(id: "i", threadID: "t", paneSessionKey: "k", sequence: 1,
                                        kind: .reply, subject: "[seahelm:demo]", body: body, state: "pending")
        let raw = GmailRESTMailSender.rawMessage(intent: intent, to: "user@example.com",
                                                 replyToAccount: "me@example.com", boundary: "BOUND")
        var padded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        let data = Data(base64Encoded: padded, options: .ignoreUnknownCharacters)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private func part(_ message: String, contentType: String) -> String {
        let sections = message.components(separatedBy: "--BOUND")
        guard let section = sections.first(where: { $0.contains(contentType) }),
              let range = section.range(of: "\r\n\r\n") else { return "" }
        let encoded = String(section[range.upperBound...])
        return Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Seahelm's own mail is From the plain account, so pressing Reply produces
    /// mail addressed there — which the recipient gate refuses. Without this a
    /// conversation could never reach its second round.
    func testRepliesAreDirectedBackToTheAlias() {
        XCTAssertTrue(mime(body: "x").contains("Reply-To: me+seahelm@example.com"))
    }

    /// The blank lines in the MIME body are structural: they end the header
    /// block and each part's headers.
    func testStructuralBlankLinesSurvive() {
        let message = mime(body: "x")
        XCTAssertTrue(message.contains("boundary=\"BOUND\"\r\n\r\n--BOUND"), "header block must end")
        XCTAssertTrue(message.contains("Content-Transfer-Encoding: base64\r\n\r\n"), "part headers must end")
    }

    func testSendsBothAlternatives() {
        let message = mime(body: "**Panes** — 1")
        XCTAssertTrue(message.contains("Content-Type: multipart/alternative; boundary=\"BOUND\""), message)
        XCTAssertTrue(message.contains("Content-Type: text/plain; charset=utf-8"), message)
        XCTAssertTrue(message.contains("Content-Type: text/html; charset=utf-8"), message)
        XCTAssertTrue(message.hasSuffix("--BOUND--"), "closing delimiter")
    }

    func testHtmlPartIsTheRenderedDocument() {
        let html = part(mime(body: "**Panes** — 1"), contentType: "text/html")
        XCTAssertTrue(html.contains("<strong>Panes</strong>"), html)
    }

    /// The plain part is not a fallback: the reader parses `text/plain` on the
    /// way back, so a reply quoting this must still yield just the new text.
    func testPlainPartSurvivesAReplyRoundTrip() {
        let plain = part(mime(body: "Pane is waiting for you."), contentType: "text/plain")
        XCTAssertTrue(plain.contains("Pane is waiting for you."), plain)
        XCTAssertTrue(plain.contains("/pane"), "command list rides along")

        let quoted = plain.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }.joined(separator: "\n")
        let reply = "/pane 2\n\nOn Wed, Aug 5, 2026 at 1:23 PM Seahelm <s@example.com> wrote:\n\(quoted)"
        XCTAssertEqual(MailBody.newContent(of: reply), "/pane 2")
    }

    /// RFC 5322 caps a line at 998 characters and agent output runs past that,
    /// so the parts are base64 with wrapping rather than raw UTF-8.
    func testLongOutputStaysWithinLineLimits() {
        let message = mime(body: String(repeating: "x", count: 5_000))
        for line in message.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.count, 998, "over-long line")
        }
    }

    func testNonASCIIContentSurvives() {
        let plain = part(mime(body: "状态：● 运行中 ✕"), contentType: "text/plain")
        XCTAssertTrue(plain.contains("状态：● 运行中 ✕"), plain)
    }
}

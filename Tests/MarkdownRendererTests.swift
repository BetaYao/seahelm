import XCTest
@testable import seahelm

final class MarkdownRendererTests: XCTestCase {

    // MARK: Tables

    func testTableRendersHeaderAndRows() {
        let md = """
        | Name | Count |
        | --- | --- |
        | apple | 3 |
        | pear | 4 |
        """
        let html = MarkdownHTMLRenderer.html(from: md)
        XCTAssertTrue(html.contains("<table>"), html)
        XCTAssertTrue(html.contains(">Name</th>"), html)
        XCTAssertTrue(html.contains(">apple</td>"), html)
        XCTAssertTrue(html.contains(">4</td>"), html)
    }

    func testTableAlignments() {
        let md = """
        | L | C | R |
        | :--- | :---: | ---: |
        | a | b | c |
        """
        let html = MarkdownHTMLRenderer.html(from: md)
        XCTAssertTrue(html.contains("text-align:left"), html)
        XCTAssertTrue(html.contains("text-align:center"), html)
        XCTAssertTrue(html.contains("text-align:right"), html)
    }

    func testRaggedRowIsPadded() {
        let md = """
        | A | B |
        | --- | --- |
        | only |
        """
        let html = MarkdownHTMLRenderer.html(from: md)
        // Two header cells means every body row must emit two cells.
        XCTAssertEqual(html.components(separatedBy: "<td").count - 1, 2, html)
    }

    func testDelimiterRowIsNotTreatedAsHorizontalRule() {
        let md = """
        | A |
        | --- |
        | x |
        """
        XCTAssertFalse(MarkdownHTMLRenderer.html(from: md).contains("<hr>"))
    }

    func testStandaloneHorizontalRuleStillWorks() {
        XCTAssertTrue(MarkdownHTMLRenderer.html(from: "---").contains("<hr>"))
    }

    func testPipeInProseIsNotATable() {
        // No delimiter row, so this must stay a paragraph.
        let html = MarkdownHTMLRenderer.html(from: "use a | b to pipe")
        XCTAssertFalse(html.contains("<table>"), html)
        XCTAssertTrue(html.contains("<p>"), html)
    }

    // MARK: Images

    func testRelativeImageResolvesToLocalScheme() {
        let base = URL(fileURLWithPath: "/tmp/docs")
        let html = MarkdownHTMLRenderer.html(from: "![cat](img/cat.png)", baseDirectory: base)
        XCTAssertTrue(html.contains("src=\"\(PreviewWebView.localScheme)://local/tmp/docs/img/cat.png\""), html)
    }

    func testRemoteImageIsLeftAlone() {
        let html = MarkdownHTMLRenderer.html(from: "![x](https://example.com/a.png)",
                                             baseDirectory: URL(fileURLWithPath: "/tmp"))
        XCTAssertTrue(html.contains("src=\"https://example.com/a.png\""), html)
    }

    func testImageTitleIsStrippedFromPath() {
        let base = URL(fileURLWithPath: "/tmp")
        let html = MarkdownHTMLRenderer.html(from: "![x](a.png \"A title\")", baseDirectory: base)
        XCTAssertTrue(html.contains("/tmp/a.png\""), html)
    }

    func testImageWithoutBaseDirectoryIsUnchanged() {
        let html = MarkdownHTMLRenderer.html(from: "![x](a.png)")
        XCTAssertTrue(html.contains("src=\"a.png\""), html)
    }

    // MARK: Regressions in existing syntax

    func testHeadingAndEmphasisStillRender() {
        let html = MarkdownHTMLRenderer.html(from: "# Title\n\nsome **bold** and *italic*")
        XCTAssertTrue(html.contains("<h1>Title</h1>"), html)
        XCTAssertTrue(html.contains("<strong>bold</strong>"), html)
        XCTAssertTrue(html.contains("<em>italic</em>"), html)
    }

    func testFencedCodeIsEscaped() {
        let html = MarkdownHTMLRenderer.html(from: "```\nlet x = a < b\n```")
        XCTAssertTrue(html.contains("<pre><code>"), html)
        XCTAssertTrue(html.contains("a &lt; b"), html)
    }
}

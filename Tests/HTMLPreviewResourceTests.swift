import XCTest
@testable import seahelm

final class HTMLPreviewResourceTests: XCTestCase {

    func testLocalResourceBaseURLUsesCustomSchemeAndTrailingSlash() {
        let dir = URL(fileURLWithPath: "/tmp/site/docs")
        let base = PreviewWebView.localResourceBaseURL(forDirectory: dir)
        XCTAssertEqual(base?.absoluteString, "\(PreviewWebView.localScheme)://local/tmp/site/docs/")
    }

    func testLocalResourceBaseURLAddsSlashWhenDirectoryHasNone() {
        let dir = URL(fileURLWithPath: "/tmp/site")
        let base = PreviewWebView.localResourceBaseURL(forDirectory: dir)!
        XCTAssertTrue(base.absoluteString.hasSuffix("/"), base.absoluteString)
    }

    func testRelativeStylesheetResolvesUnderDocumentDirectory() {
        let dir = URL(fileURLWithPath: "/tmp/site")
        let base = PreviewWebView.localResourceBaseURL(forDirectory: dir)!
        let css = URL(string: "css/app.css", relativeTo: base)!.absoluteURL
        XCTAssertEqual(css.absoluteString, "\(PreviewWebView.localScheme)://local/tmp/site/css/app.css")
    }

    func testNestedRelativePathDoesNotEscapeWithoutTrailingSlashBug() {
        // Without a trailing slash on the base, RFC 3986 would resolve
        // "style.css" against "/tmp/site" as "/tmp/style.css".
        let dir = URL(fileURLWithPath: "/tmp/site")
        let base = PreviewWebView.localResourceBaseURL(forDirectory: dir)!
        let css = URL(string: "style.css", relativeTo: base)!.absoluteURL
        XCTAssertEqual(css.path, "/tmp/site/style.css", css.absoluteString)
    }
}

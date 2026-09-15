import XCTest
@testable import seahelm

final class ShellEscapeTests: XCTestCase {
    func testWrapsPlainStringInSingleQuotes() {
        XCTAssertEqual(ShellEscape.singleQuote("fix the login bug"), "'fix the login bug'")
    }

    func testEscapesEmbeddedSingleQuote() {
        // can't => 'can'\''t'
        XCTAssertEqual(ShellEscape.singleQuote("can't"), "'can'\\''t'")
    }

    func testKeepsDollarAndDoubleQuoteLiteral() {
        XCTAssertEqual(ShellEscape.singleQuote("echo $HOME \"x\""), "'echo $HOME \"x\"'")
    }

    func testEmptyString() {
        XCTAssertEqual(ShellEscape.singleQuote(""), "''")
    }

    // MARK: - backslash (dropped file paths)

    func testBackslashEscapesSpacesAndParentheses() {
        XCTAssertEqual(ShellEscape.backslash("/tmp/My File (1).png"), "/tmp/My\\ File\\ \\(1\\).png")
    }

    func testBackslashEscapesQuotesAndDollar() {
        // it's "$HOME" => it\'s\ \"\$HOME\"
        XCTAssertEqual(ShellEscape.backslash("it's \"$HOME\""), "it\\'s\\ \\\"\\$HOME\\\"")
    }

    func testBackslashDoesNotDoubleItsOwnEscapes() {
        // a\b c => a\\b\ c
        XCTAssertEqual(ShellEscape.backslash("a\\b c"), "a\\\\b\\ c")
    }

    func testBackslashLeavesPlainPathAndUnicodeAlone() {
        XCTAssertEqual(ShellEscape.backslash("/Users/me/résumé-v2.pdf"), "/Users/me/résumé-v2.pdf")
    }

    func testBackslashSingleQuotesValueWithNewline() {
        XCTAssertEqual(ShellEscape.backslash("a\nb"), "'a\nb'")
    }
}

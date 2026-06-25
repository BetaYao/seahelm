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
}

import XCTest
@testable import seahelm

final class TitleBarWorktreeNavTests: XCTestCase {
    private let paths = ["/a", "/b", "/c"]

    func testForwardFromMiddle() {
        XCTAssertEqual(TitleBarView.adjacentPath(paths: paths, from: "/b", forward: true), "/c")
    }

    func testBackwardFromMiddle() {
        XCTAssertEqual(TitleBarView.adjacentPath(paths: paths, from: "/b", forward: false), "/a")
    }

    func testForwardWrapsFromLast() {
        XCTAssertEqual(TitleBarView.adjacentPath(paths: paths, from: "/c", forward: true), "/a")
    }

    func testBackwardWrapsFromFirst() {
        XCTAssertEqual(TitleBarView.adjacentPath(paths: paths, from: "/a", forward: false), "/c")
    }

    func testNilCurrentForwardStartsAtFirst() {
        XCTAssertEqual(TitleBarView.adjacentPath(paths: paths, from: nil, forward: true), "/a")
    }

    func testNilCurrentBackwardStartsAtLast() {
        XCTAssertEqual(TitleBarView.adjacentPath(paths: paths, from: nil, forward: false), "/c")
    }

    func testUnknownCurrentTreatedAsNil() {
        XCTAssertEqual(TitleBarView.adjacentPath(paths: paths, from: "/zzz", forward: true), "/a")
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(TitleBarView.adjacentPath(paths: [], from: "/a", forward: true))
    }

    func testSingleTabForwardStaysPut() {
        XCTAssertEqual(TitleBarView.adjacentPath(paths: ["/only"], from: "/only", forward: true), "/only")
    }

    func testSingleTabBackwardStaysPut() {
        XCTAssertEqual(TitleBarView.adjacentPath(paths: ["/only"], from: "/only", forward: false), "/only")
    }
}

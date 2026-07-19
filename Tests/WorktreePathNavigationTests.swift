import XCTest
@testable import seahelm

final class WorktreePathNavigationTests: XCTestCase {
    private let paths = ["/a", "/b", "/c"]

    func testForwardFromMiddle() {
        XCTAssertEqual(WorktreePathNavigation.adjacentPath(paths: paths, from: "/b", forward: true), "/c")
    }

    func testBackwardFromMiddle() {
        XCTAssertEqual(WorktreePathNavigation.adjacentPath(paths: paths, from: "/b", forward: false), "/a")
    }

    func testForwardWrapsFromLast() {
        XCTAssertEqual(WorktreePathNavigation.adjacentPath(paths: paths, from: "/c", forward: true), "/a")
    }

    func testBackwardWrapsFromFirst() {
        XCTAssertEqual(WorktreePathNavigation.adjacentPath(paths: paths, from: "/a", forward: false), "/c")
    }

    func testNilCurrentForwardStartsAtFirst() {
        XCTAssertEqual(WorktreePathNavigation.adjacentPath(paths: paths, from: nil, forward: true), "/a")
    }

    func testNilCurrentBackwardStartsAtLast() {
        XCTAssertEqual(WorktreePathNavigation.adjacentPath(paths: paths, from: nil, forward: false), "/c")
    }

    func testUnknownCurrentTreatedAsNil() {
        XCTAssertEqual(WorktreePathNavigation.adjacentPath(paths: paths, from: "/zzz", forward: true), "/a")
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(WorktreePathNavigation.adjacentPath(paths: [], from: "/a", forward: true))
    }

    func testSingleTabForwardStaysPut() {
        XCTAssertEqual(WorktreePathNavigation.adjacentPath(paths: ["/only"], from: "/only", forward: true), "/only")
    }

    func testSingleTabBackwardStaysPut() {
        XCTAssertEqual(WorktreePathNavigation.adjacentPath(paths: ["/only"], from: "/only", forward: false), "/only")
    }
}

import XCTest
@testable import seahelm

final class CabinPathNavigationTests: XCTestCase {
    private let paths = ["/a", "/b", "/c"]

    func testForwardFromMiddle() {
        XCTAssertEqual(CabinPathNavigation.adjacentPath(paths: paths, from: "/b", forward: true), "/c")
    }

    func testBackwardFromMiddle() {
        XCTAssertEqual(CabinPathNavigation.adjacentPath(paths: paths, from: "/b", forward: false), "/a")
    }

    func testForwardWrapsFromLast() {
        XCTAssertEqual(CabinPathNavigation.adjacentPath(paths: paths, from: "/c", forward: true), "/a")
    }

    func testBackwardWrapsFromFirst() {
        XCTAssertEqual(CabinPathNavigation.adjacentPath(paths: paths, from: "/a", forward: false), "/c")
    }

    func testNilCurrentForwardStartsAtFirst() {
        XCTAssertEqual(CabinPathNavigation.adjacentPath(paths: paths, from: nil, forward: true), "/a")
    }

    func testNilCurrentBackwardStartsAtLast() {
        XCTAssertEqual(CabinPathNavigation.adjacentPath(paths: paths, from: nil, forward: false), "/c")
    }

    func testUnknownCurrentTreatedAsNil() {
        XCTAssertEqual(CabinPathNavigation.adjacentPath(paths: paths, from: "/zzz", forward: true), "/a")
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(CabinPathNavigation.adjacentPath(paths: [], from: "/a", forward: true))
    }

    func testSingleTabForwardStaysPut() {
        XCTAssertEqual(CabinPathNavigation.adjacentPath(paths: ["/only"], from: "/only", forward: true), "/only")
    }

    func testSingleTabBackwardStaysPut() {
        XCTAssertEqual(CabinPathNavigation.adjacentPath(paths: ["/only"], from: "/only", forward: false), "/only")
    }
}

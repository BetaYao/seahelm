import XCTest
@testable import seahelm

class SemVerTests: XCTestCase {

    // MARK: - Parsing

    func testParseThreeComponents() {
        let v = SemVer("2.1.3")
        XCTAssertNotNil(v)
        XCTAssertEqual(v?.major, 2)
        XCTAssertEqual(v?.minor, 1)
        XCTAssertEqual(v?.patch, 3)
    }

    func testParseTwoComponents() {
        let v = SemVer("1.0")
        XCTAssertNotNil(v)
        XCTAssertEqual(v?.major, 1)
        XCTAssertEqual(v?.minor, 0)
        XCTAssertEqual(v?.patch, 0)
    }

    func testParseVPrefix() {
        let v = SemVer("v2.1.0")
        XCTAssertNotNil(v)
        XCTAssertEqual(v?.major, 2)
        XCTAssertEqual(v?.minor, 1)
        XCTAssertEqual(v?.patch, 0)
        XCTAssertEqual(v?.string, "2.1.0")
    }

    func testParseMalformedReturnsNil() {
        XCTAssertNil(SemVer("abc"))
        XCTAssertNil(SemVer(""))
        XCTAssertNil(SemVer("1"))
        XCTAssertNil(SemVer("v"))
    }

    // MARK: - Comparison

    func testComparisonMajor() {
        XCTAssertTrue(SemVer("3.0.0")! > SemVer("2.9.9")!)
        XCTAssertTrue(SemVer("1.0.0")! < SemVer("2.0.0")!)
    }

    func testComparisonMinor() {
        XCTAssertTrue(SemVer("2.1.0")! > SemVer("2.0.99")!)
        XCTAssertTrue(SemVer("2.0.0")! < SemVer("2.1.0")!)
    }

    func testComparisonPatch() {
        XCTAssertTrue(SemVer("2.0.1")! > SemVer("2.0.0")!)
        XCTAssertTrue(SemVer("2.0.0")! < SemVer("2.0.1")!)
    }

    func testEqual() {
        XCTAssertEqual(SemVer("2.0.0"), SemVer("2.0.0"))
        XCTAssertEqual(SemVer("v2.0.0"), SemVer("2.0.0"))
        XCTAssertFalse(SemVer("2.0.0")! < SemVer("2.0.0")!)
        XCTAssertFalse(SemVer("2.0.0")! > SemVer("2.0.0")!)
    }

    func testStringRepresentation() {
        XCTAssertEqual(SemVer("v1.2.3")?.string, "1.2.3")
        XCTAssertEqual(SemVer("2.0")?.string, "2.0.0")
    }
}

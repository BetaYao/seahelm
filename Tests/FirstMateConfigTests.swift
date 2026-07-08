import XCTest
@testable import seahelm

final class FirstMateConfigTests: XCTestCase {
    func testDefaults() {
        let c = FirstMateConfig.default
        XCTAssertTrue(c.enabled)
        XCTAssertEqual(c.waitingTimeoutSec, 30)
        XCTAssertTrue(c.autoInspect)
        XCTAssertTrue(c.autoReview)
        XCTAssertFalse(c.autoCommit)
    }

    func testConfigDecodesMissingFirstMateAsDefault() throws {
        let json = "{}".data(using: .utf8)!
        let cfg = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertEqual(cfg.firstMate, FirstMateConfig.default)
    }

    func testConfigDecodesProvidedFirstMate() throws {
        let json = """
        {"firstMate":{"enabled":false,"waitingTimeoutSec":10,"autoInspect":false,
        "inspectionCommands":["make test"],"autoReview":false,"autoCommit":true,
        "channels":["local"]}}
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertFalse(cfg.firstMate.enabled)
        XCTAssertEqual(cfg.firstMate.waitingTimeoutSec, 10)
        XCTAssertEqual(cfg.firstMate.inspectionCommands, ["make test"])
        XCTAssertTrue(cfg.firstMate.autoCommit)
    }
}

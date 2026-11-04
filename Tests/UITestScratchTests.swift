import XCTest
@testable import seahelm

final class UITestScratchTests: XCTestCase {
    func testOnlyAScratchHomeUnderTheTestFlagIsPrepared() throws {
        let root = "/tmp/shut-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let env = ["SEAHELM_UITEST_SCRATCH": root, "CFFIXED_USER_HOME": "\(root)/h"]
        // Without the flag, or with a home outside the scratch dir: nothing.
        UITestScratch.prepareIfAsked(environment: env, arguments: ["app"])
        UITestScratch.prepareIfAsked(environment: ["SEAHELM_UITEST_SCRATCH": root, "CFFIXED_USER_HOME": NSHomeDirectory()],
                                     arguments: ["app", "-SeahelmUITesting"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root))

        UITestScratch.prepareIfAsked(environment: env, arguments: ["app", "-SeahelmUITesting"])
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(root)/h/.config/seahelm/config.json"))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(config["workspace_paths"] as? [String], ["\(root)/repo"])
        XCTAssertEqual(config["default_agent"] as? String, "shellCommand")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(root)/repo/.git"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(root)/d"))
    }
}

import XCTest
@testable import seahelm

final class SeahelmSkillInstallerTests: XCTestCase {

    func testInstallsSkillFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-skill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertTrue(SeahelmSkillInstaller.ensureInstalled(directory: tmp))
        let md = tmp.appendingPathComponent("SKILL.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: md.path))
        XCTAssertFalse(SeahelmSkillInstaller.ensureInstalled(directory: tmp)) // idempotent
    }

    func testSkillHasGuardAndFrontmatterAndCommands() {
        let s = SeahelmSkillInstaller.skillContents()
        XCTAssertTrue(s.hasPrefix("---\nname: seahelm"))
        XCTAssertTrue(s.contains("SEAHELM_ENV"))          // the guard
        XCTAssertTrue(s.contains("$SEAHELM_PANE_ID"))     // self-reference
        for cmd in ["pane split", "pane run", "pane read", "pane send-keys",
                    "wait output", "wait agent-status", "session snapshot"] {
            XCTAssertTrue(s.contains(cmd), "skill missing `\(cmd)`")
        }
    }
}

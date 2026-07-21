import XCTest
@testable import seahelm

final class CabinTaskStoreTests: XCTestCase {
    func testSetAndGetRoundTrip() {
        let path = "/tmp/seahelm-test-worktree-\(UUID().uuidString)"
        CabinTaskStore.shared.set("fix the login bug", forWorktree: path)
        XCTAssertEqual(CabinTaskStore.shared.task(forWorktree: path), "fix the login bug")
    }

    func testMissingPathReturnsNil() {
        XCTAssertNil(CabinTaskStore.shared.task(forWorktree: "/tmp/seahelm-never-set-\(UUID().uuidString)"))
    }
}

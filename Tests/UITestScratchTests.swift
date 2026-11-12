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

    func testOnlyOldScratchDirsOfThisUserOtherThanOursAreSwept() {
        let now = Date()
        let old = now.addingTimeInterval(-UITestScratch.staleAfter - 1)
        let me = getuid()
        let dirs: [(path: String, created: Date, owner: UInt32)] = [
            ("/tmp/shui-aaaa1111", old, me),          // left by an earlier launch
            ("/tmp/shui-ours", old, me),              // this launch's own
            ("/tmp/shui-bbbb2222", now, me),          // maybe a test still running
            ("/tmp/shui-cccc3333", old, me + 1),      // another user's
            ("/tmp/shui-", old, me),                  // not a ScratchHome name
            ("/tmp/shui-x/../etc", old, me),
            ("/tmp/shut-dddd4444", old, me),          // the unit tests' prefix
            ("/tmp/seahelmd-501", old, me),
        ]
        XCTAssertEqual(UITestScratch.staleScratch(dirs, keeping: "/tmp/shui-ours", user: me, now: now),
                       ["/tmp/shui-aaaa1111"])
    }

    func testSweepingEndsWhatHoldsTheDirectoryAndRemovesIt() throws {
        let tmp = "/tmp/shut-\(UUID().uuidString.prefix(8))"
        let stale = "\(tmp)/shui-stale01"
        let mine = "\(tmp)/shui-mine01"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        for d in [stale, mine] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        // A leftover daemon: a process holding a file open in the stale dir.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/sh")
        holder.arguments = ["-c", "exec 3>\(stale)/held; sleep 30"]
        try holder.run()
        Thread.sleep(forTimeInterval: 0.3)

        UITestScratch.sweepStale(keeping: mine, in: tmp, now: Date().addingTimeInterval(UITestScratch.staleAfter + 60))
        holder.waitUntilExit()
        XCTAssertEqual(holder.terminationReason, .uncaughtSignal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mine))
    }
}

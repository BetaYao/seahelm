import XCTest
@testable import seahelm

final class TodoStoreTests: XCTestCase {
    private var store: TodoStore!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = TodoStore(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testAddAndRetrieve() {
        let item = store.add(task: "Fix bug", project: "seahelm", branch: "fix-bug", issue: "#42")
        XCTAssertEqual(item.task, "Fix bug")
        XCTAssertEqual(item.project, "seahelm")
        XCTAssertEqual(item.branch, "fix-bug")
        XCTAssertEqual(item.issue, "#42")
        XCTAssertEqual(item.status, "pending_approval")
        XCTAssertEqual(store.allItems().count, 1)
    }

    func testUpdateStatus() {
        let item = store.add(task: "Task", project: "p", branch: nil, issue: nil)
        store.update(id: item.id, status: "running", progress: "Working on it")
        let updated = store.allItems().first!
        XCTAssertEqual(updated.status, "running")
        XCTAssertEqual(updated.progress, "Working on it")
        XCTAssertGreaterThan(updated.updatedAt, item.updatedAt)
    }

    func testRemove() {
        let item = store.add(task: "Task", project: "p", branch: nil, issue: nil)
        store.remove(id: item.id)
        XCTAssertTrue(store.allItems().isEmpty)
    }

    func testSaveAndLoad() {
        _ = store.add(task: "Task A", project: "seahelm", branch: "main", issue: nil)
        _ = store.add(task: "Task B", project: "seahelm2", branch: nil, issue: "#10")
        store.saveSync()

        let loaded = TodoStore(directory: tempDir)
        loaded.load()
        XCTAssertEqual(loaded.allItems().count, 2)
        XCTAssertEqual(loaded.allItems().first?.task, "Task A")
    }

    func testLoadMissingFileReturnsEmpty() {
        let emptyDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let fresh = TodoStore(directory: emptyDir)
        fresh.load()
        XCTAssertTrue(fresh.allItems().isEmpty)
    }
}

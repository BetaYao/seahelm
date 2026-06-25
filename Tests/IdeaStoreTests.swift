import XCTest
@testable import seahelm

final class IdeaStoreTests: XCTestCase {
    private var store: IdeaStore!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = IdeaStore(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testAddAndRetrieve() {
        let item = store.add(text: "Add dark mode", project: "seahelm", source: "manual", tags: ["ui"])
        XCTAssertEqual(item.text, "Add dark mode")
        XCTAssertEqual(item.project, "seahelm")
        XCTAssertEqual(item.source, "manual")
        XCTAssertEqual(item.tags, ["ui"])
        XCTAssertEqual(store.allItems().count, 1)
    }

    func testRemove() {
        let item = store.add(text: "Idea", project: "p", source: "manual", tags: [])
        store.remove(id: item.id)
        XCTAssertTrue(store.allItems().isEmpty)
    }

    func testSaveAndLoad() {
        _ = store.add(text: "Idea A", project: "seahelm", source: "manual", tags: ["perf"])
        _ = store.add(text: "Idea B", project: "seahelm2", source: "wechat", tags: [])
        store.saveSync()

        let loaded = IdeaStore(directory: tempDir)
        loaded.load()
        XCTAssertEqual(loaded.allItems().count, 2)
        // New items are appended to the end (chronological order), so the
        // first item is the oldest one added.
        XCTAssertEqual(loaded.allItems().first?.text, "Idea A")
        XCTAssertEqual(loaded.allItems().last?.text, "Idea B")
    }

    func testNewItemsAppendToEnd() {
        _ = store.add(text: "First", project: "p", source: "manual", tags: [])
        _ = store.add(text: "Second", project: "p", source: "manual", tags: [])
        // Items are appended in chronological order.
        XCTAssertEqual(store.allItems().first?.text, "First")
        XCTAssertEqual(store.allItems().last?.text, "Second")
    }

    func testLoadMissingFileReturnsEmpty() {
        let emptyDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let fresh = IdeaStore(directory: emptyDir)
        fresh.load()
        XCTAssertTrue(fresh.allItems().isEmpty)
    }
}

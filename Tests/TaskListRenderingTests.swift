import XCTest
@testable import seahelm

final class TaskListRenderingTests: XCTestCase {

    func testEmptyTasksReturnsNil() {
        let result = TaskListRenderer.attributedString(for: [])
        XCTAssertNil(result)
    }

    func testSinglePendingTask() {
        let tasks = [TaskItem(id: "1", subject: "Add tests", status: .pending)]
        let result = TaskListRenderer.attributedString(for: tasks)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.string.contains("□"))
        XCTAssertTrue(result!.string.contains("Add tests"))
    }

    func testMixedStatusTasks() {
        let tasks = [
            TaskItem(id: "1", subject: "Done task", status: .completed),
            TaskItem(id: "2", subject: "Current task", status: .inProgress),
            TaskItem(id: "3", subject: "Future task", status: .pending),
        ]
        let result = TaskListRenderer.attributedString(for: tasks)
        XCTAssertNotNil(result)
        let str = result!.string
        XCTAssertTrue(str.contains("✓"))
        XCTAssertTrue(str.contains("■"))
        XCTAssertTrue(str.contains("□"))
    }

    func testCompletedTaskHasStrikethrough() {
        let tasks = [TaskItem(id: "1", subject: "Done", status: .completed)]
        let result = TaskListRenderer.attributedString(for: tasks)!
        // Find the "D" in "Done" and check its attributes
        let str = result.string as NSString
        let doneRange = str.range(of: "Done")
        let attrs = result.attributes(at: doneRange.location, effectiveRange: nil)
        let strike = attrs[.strikethroughStyle] as? Int ?? 0
        XCTAssertEqual(strike, NSUnderlineStyle.single.rawValue)
    }

    func testInProgressTaskIsBold() {
        let tasks = [TaskItem(id: "1", subject: "Working", status: .inProgress)]
        let result = TaskListRenderer.attributedString(for: tasks)!
        let str = result.string as NSString
        let workingRange = str.range(of: "Working")
        let attrs = result.attributes(at: workingRange.location, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
        XCTAssertNotNil(font)
        // Bold monospaced should have weight >= bold
        let fontDesc = font!.fontDescriptor
        let traits = fontDesc.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let weight = traits?[.weight] as? CGFloat ?? 0
        XCTAssertGreaterThanOrEqual(weight, NSFont.Weight.bold.rawValue)
    }
}

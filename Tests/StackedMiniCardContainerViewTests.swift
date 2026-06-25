// Tests/StackedMiniCardContainerViewTests.swift
import XCTest
@testable import seahelm

final class StackedMiniCardContainerViewTests: XCTestCase {

    func testNoPanesProducesNoGhosts() {
        let container = StackedMiniCardContainerView()
        container.configure(paneCount: 1)
        XCTAssertEqual(container.ghostViews.count, 0)
    }

    func testTwoPanesProducesOneGhost() {
        let container = StackedMiniCardContainerView()
        container.configure(paneCount: 2)
        XCTAssertEqual(container.ghostViews.count, 1)
    }

    func testThreePanesProducesTwoGhosts() {
        let container = StackedMiniCardContainerView()
        container.configure(paneCount: 3)
        XCTAssertEqual(container.ghostViews.count, 2)
    }

    func testFivePanesCapsAtTwoGhosts() {
        let container = StackedMiniCardContainerView()
        container.configure(paneCount: 5)
        XCTAssertEqual(container.ghostViews.count, 2)
    }

    func testGhostsRemovedWhenPaneCountDrops() {
        let container = StackedMiniCardContainerView()
        container.configure(paneCount: 3)
        XCTAssertEqual(container.ghostViews.count, 2)
        container.configure(paneCount: 1)
        XCTAssertEqual(container.ghostViews.count, 0)
        XCTAssertEqual(container.subviews.count, 1)
    }

    func testGhostOffset3px() {
        let container = StackedMiniCardContainerView()
        container.frame = NSRect(x: 0, y: 0, width: 220, height: 128)
        container.configure(paneCount: 3)
        container.layoutChildren()
        XCTAssertEqual(container.miniCardView.frame.origin.x, 0)
        XCTAssertEqual(container.miniCardView.frame.origin.y, 6)
        XCTAssertEqual(container.miniCardView.frame.width, 214)
        XCTAssertEqual(container.miniCardView.frame.height, 122)
        XCTAssertEqual(container.ghostViews[0].frame.origin.x, 3)
        XCTAssertEqual(container.ghostViews[0].frame.origin.y, 3)
        XCTAssertEqual(container.ghostViews[1].frame.origin.x, 6)
        XCTAssertEqual(container.ghostViews[1].frame.origin.y, 0)
    }

    func testHitTestOutsideMiniCardReturnsNil() {
        let container = StackedMiniCardContainerView()
        container.frame = NSRect(x: 0, y: 0, width: 220, height: 128)
        container.miniCardView.frame = NSRect(x: 0, y: 6, width: 214, height: 122)
        container.configure(paneCount: 2)
        let ghostPoint = NSPoint(x: 10, y: 2)
        XCTAssertNil(container.hitTest(ghostPoint))
    }

    func testAgentIdForwarding() {
        let container = StackedMiniCardContainerView()
        container.miniCardView.configure(
            id: "test-id", project: "proj", thread: "main",
            status: "idle", lastMessage: "", totalDuration: "", roundDuration: ""
        )
        XCTAssertEqual(container.agentId, "test-id")
    }

    func testIsSelectedForwarding() {
        let container = StackedMiniCardContainerView()
        container.isSelected = true
        XCTAssertTrue(container.miniCardView.isSelected)
        container.isSelected = false
        XCTAssertFalse(container.miniCardView.isSelected)
    }

    func testContextMenuContainsInspectorActionsBeforeDeleteWorktree() throws {
        let container = StackedMiniCardContainerView()

        let menu = try XCTUnwrap(container.menu(for: makeRightClickEvent()))
        let titles = menu.items.map(\.title)

        XCTAssertEqual(titles.prefix(4), ["Browse Files...", "Show Changes...", "", "Delete Worktree"])
    }

    func testBrowseFilesMenuActionForwardsAgentId() throws {
        let container = StackedMiniCardContainerView()
        let spy = InspectorDelegateSpy()
        container.delegate = spy
        container.miniCardView.configure(
            id: "agent-1", project: "proj", thread: "main",
            status: "idle", lastMessage: "", totalDuration: "", roundDuration: ""
        )

        try performMenuItem(title: "Browse Files...", in: container)

        XCTAssertEqual(spy.browseIds, ["agent-1"])
        XCTAssertTrue(spy.showChangesIds.isEmpty)
    }

    func testShowChangesMenuActionForwardsSailorId() throws {
        let container = StackedMiniCardContainerView()
        let spy = InspectorDelegateSpy()
        container.delegate = spy
        container.miniCardView.configure(
            id: "agent-2", project: "proj", thread: "main",
            status: "idle", lastMessage: "", totalDuration: "", roundDuration: ""
        )

        try performMenuItem(title: "Show Changes...", in: container)

        XCTAssertEqual(spy.showChangesIds, ["agent-2"])
        XCTAssertTrue(spy.browseIds.isEmpty)
    }

    private func performMenuItem(title: String, in container: StackedMiniCardContainerView) throws {
        let menu = try XCTUnwrap(container.menu(for: makeRightClickEvent()))
        let item = try XCTUnwrap(menu.item(withTitle: title))
        let target = try XCTUnwrap(item.target as? NSObject)
        let action = try XCTUnwrap(item.action)
        target.perform(action, with: item)
    }

    private func makeRightClickEvent() -> NSEvent {
        NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}

private final class InspectorDelegateSpy: SailorCardDelegate {
    var browseIds: [String] = []
    var showChangesIds: [String] = []

    func agentCardClicked(agentId: String) {}
    func agentCardDidRequestBrowseFiles(agentId: String) { browseIds.append(agentId) }
    func agentCardDidRequestShowChanges(agentId: String) { showChangesIds.append(agentId) }
}

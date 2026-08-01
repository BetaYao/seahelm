import XCTest
@testable import seahelm

final class AddCabinPopoverTests: XCTestCase {

    func testEmptyTaskReportsAnErrorAndDoesNotCreate() {
        let controller = makeLoadedController()
        var createCount = 0
        controller.onCreate = { _, _ in createCount += 1 }

        controller.submitForTesting()

        XCTAssertEqual(createCount, 0)
        XCTAssertEqual(controller.errorTextForTesting, "Describe the task first.")
        XCTAssertFalse(controller.isCreatingForTesting)
    }

    func testSubmitPassesTaskAndAgentThenLocksTheForm() {
        let controller = makeLoadedController()
        var submitted: (task: String, agent: SailorType)?
        controller.onCreate = { task, agent in submitted = (task, agent) }
        controller.setTaskForTesting("  wire up the popover  ")

        controller.submitForTesting()

        XCTAssertEqual(submitted?.task, "wire up the popover")
        let defaultAgent = SailorType(rawValue: Config.load().defaultAgent) ?? .claudeCode
        XCTAssertEqual(submitted?.agent, defaultAgent)
        XCTAssertTrue(controller.isCreatingForTesting)

        // A second Return while the create is in flight must not double-submit.
        submitted = nil
        controller.submitForTesting()
        XCTAssertNil(submitted)
    }

    func testFailureUnlocksTheFormAndShowsTheMessage() {
        let controller = makeLoadedController()
        controller.onCreate = { _, _ in }
        controller.setTaskForTesting("do the thing")
        controller.submitForTesting()

        controller.reportFailure("fatal: invalid reference")

        XCTAssertFalse(controller.isCreatingForTesting)
        XCTAssertEqual(controller.errorTextForTesting, "fatal: invalid reference")
    }

    func testPastedImagesShowAsThumbnailsAndRideAlongInTheTask() {
        let controller = makeLoadedController()
        var submitted: String?
        controller.onCreate = { task, _ in submitted = task }
        controller.setTaskForTesting("fix this layout")
        controller.attachImageForTesting(URL(fileURLWithPath: "/tmp/shot-a.png"))
        controller.attachImageForTesting(URL(fileURLWithPath: "/tmp/shot-b.png"))

        XCTAssertEqual(controller.thumbnailCountForTesting, 2)

        controller.removeImageForTesting(at: 0)
        XCTAssertEqual(controller.thumbnailCountForTesting, 1)

        controller.submitForTesting()
        XCTAssertEqual(submitted, "fix this layout /tmp/shot-b.png")
    }

    func testPopoverGrowsOnlyWhenAttachmentsArePresent() {
        let controller = makeLoadedController()
        let baseSize = controller.contentSizeForTesting

        controller.attachImageForTesting(URL(fileURLWithPath: "/tmp/shot.png"))
        let attachmentSize = controller.contentSizeForTesting

        XCTAssertEqual(baseSize.width, attachmentSize.width)
        XCTAssertGreaterThan(attachmentSize.height, baseSize.height)

        controller.removeImageForTesting(at: 0)
        XCTAssertEqual(controller.contentSizeForTesting, baseSize)
    }

    func testAnImageAloneIsEnoughToCreate() {
        let controller = makeLoadedController()
        var submitted: String?
        controller.onCreate = { task, _ in submitted = task }
        controller.attachImageForTesting(URL(fileURLWithPath: "/tmp/shot-a.png"))

        controller.submitForTesting()

        XCTAssertEqual(submitted, "/tmp/shot-a.png")
        XCTAssertNil(controller.errorTextForTesting)
    }

    func testAgentChoicesAreTheAIAgents() {
        let controller = makeLoadedController()
        XCTAssertEqual(controller.agentChoiceTitlesForTesting,
                       InlineCabinCreateView.agentChoices.map(\.displayName))
    }

    private func makeLoadedController() -> AddCabinPopoverController {
        let controller = AddCabinPopoverController(project: "seahelm")
        _ = controller.view
        return controller
    }
}

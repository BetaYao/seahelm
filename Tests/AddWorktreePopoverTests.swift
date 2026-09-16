import XCTest
@testable import seahelm

final class AddWorktreePopoverTests: XCTestCase {

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
        var submitted: (task: String, agent: AgentType)?
        controller.onCreate = { task, agent in submitted = (task, agent) }
        controller.setTaskForTesting("  wire up the popover  ")

        controller.submitForTesting()

        XCTAssertEqual(submitted?.task, "wire up the popover")
        let defaultAgent = AgentType(rawValue: Config.load().defaultAgent) ?? .claudeCode
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
        XCTAssertEqual(
            submitted,
            TelegramInboundMedia.composeOrderText(
                paths: [URL(fileURLWithPath: "/tmp/shot-b.png")],
                caption: "fix this layout"))
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

        XCTAssertEqual(
            submitted,
            TelegramInboundMedia.composeOrderText(
                paths: [URL(fileURLWithPath: "/tmp/shot-a.png")],
                caption: nil))
        XCTAssertNil(controller.errorTextForTesting)
    }

    func testAgentChoicesAreTheAIAgents() {
        let controller = makeLoadedController()
        XCTAssertEqual(controller.agentChoiceTitlesForTesting,
                       AddWorktreePopoverController.agentChoices.map(\.displayName))
    }

    /// A screenshot puts only PNG/TIFF on the clipboard. Stock NSTextView disables
    /// Paste for that, so ⌘V never reached the task field's image handling.
    func testPasteIsEnabledWhenTheClipboardHoldsOnlyAnImage() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("seahelm-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        pasteboard.setData(png, forType: .png)

        let taskField = GrowingTextView()
        taskField.pasteboard = pasteboard
        taskField.onPasteImage = { _ in }
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")

        XCTAssertTrue(taskField.validateUserInterfaceItem(pasteItem))
    }

    private func makeLoadedController() -> AddWorktreePopoverController {
        let controller = AddWorktreePopoverController(project: "seahelm")
        _ = controller.view
        return controller
    }
}

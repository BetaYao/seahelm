import XCTest
@testable import seahelm

final class BridgeCardModelTests: XCTestCase {
    private func order(kind: FirstMateActionKind, options: [String]?) -> PendingOrder {
        let a = FirstMateAction(kind: kind, zone: .red, worktreePath: "/wt", branch: "b",
                                project: "p", terminalID: "t", message: "m", options: options)
        return PendingOrder(id: "id", action: a)
    }

    func testSuggestionButtonsAreItsOptions() {
        let o = order(kind: .suggestNextOrder, options: ["run tests", "open PR"])
        XCTAssertEqual(BridgePanelViewController.buttonTitles(for: o), ["run tests", "open PR"])
    }

    func testSingleActionButtonIsApprove() {
        let o = order(kind: .returnToPort, options: nil)
        XCTAssertEqual(BridgePanelViewController.buttonTitles(for: o), ["Approve"])
    }

    /// Lays out a real card: catches an invalid stack alignment (which asserts at
    /// runtime, not compile time) and proves the chips stack instead of sharing one
    /// row — each must get the card's full width so its label can actually be read.
    func testOptionChipsStackVerticallyAtFullWidth() {
        let o = order(kind: .suggestNextOrder, options: ["查 compose 缺失的服务", "run the tests", "open a PR"])
        let card = OrderCardView()
        card.configure(order: o) { _ in }
        card.frame = NSRect(x: 0, y: 0, width: 320, height: BridgePanelViewController.cardHeight(for: o))
        card.layoutSubtreeIfNeeded()

        let chips = card.optionChipFrames
        XCTAssertEqual(chips.count, 3)

        // Stacked: each chip strictly below the previous, none sharing a row.
        for (a, b) in zip(chips, chips.dropFirst()) {
            XCTAssertNotEqual(a.minY, b.minY, "chips still share a row — labels get truncated away")
        }
        // Full width: a chip squeezed to its number badge is ~30pt wide.
        for chip in chips {
            XCTAssertGreaterThan(chip.width, 200, "chip too narrow to show its label")
        }
    }

    func testCardHeightGrowsWithMoreButtons() {
        let small = BridgePanelViewController.cardHeight(for: order(kind: .returnToPort, options: nil))
        let big = BridgePanelViewController.cardHeight(for: order(kind: .suggestNextOrder,
                                                                  options: ["a", "b", "c", "d", "e"]))
        XCTAssertGreaterThan(big, small)
    }

    func testCardHeightGrowsWithMultilineMessage() {
        let short = order(kind: .suggestNextOrder, options: ["a"])
        let longAction = FirstMateAction(
            kind: .suggestNextOrder, zone: .red, worktreePath: "/wt", branch: "b",
            project: "p", terminalID: "t",
            message: """
            澄清完成，且未修改 Issue 或业务代码。

            已新增：

            - CONTEXT.md：记录 Dashboard 权限、指标、周期、空状态、会话隔离与数据边界术语。
            - docs/adr/0001-workbench-dashboard-metrics-boundary.md：明确员工端必须经后端聚合接口读取指标。

            文档格式与 diff 校验均通过。
            """,
            options: ["a"])
        let long = PendingOrder(id: "long", action: longAction)
        XCTAssertGreaterThan(
            BridgePanelViewController.cardHeight(for: long, width: 320),
            BridgePanelViewController.cardHeight(for: short, width: 320))
    }
}

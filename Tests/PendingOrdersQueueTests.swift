import XCTest
@testable import seahelm

final class PendingOrdersQueueTests: XCTestCase {
    private func action(_ kind: FirstMateActionKind, wt: String = "/wt/x") -> FirstMateAction {
        FirstMateAction(kind: kind, zone: .red, worktreePath: wt, branch: "b",
                        project: "p", terminalID: "t", message: "m")
    }

    func testEnqueueAddsOrder() {
        let q = PendingOrdersQueue()
        q.enqueue(action(.suggestNextOrder))
        XCTAssertEqual(q.all().count, 1)
    }

    func testDuplicateSameWorktreeAndKindKeepsOne() {
        let q = PendingOrdersQueue()
        q.enqueue(action(.suggestNextOrder))
        q.enqueue(action(.suggestNextOrder))
        XCTAssertEqual(q.all().count, 1)
    }

    func testDifferentWorktreesCoexist() {
        let q = PendingOrdersQueue()
        q.enqueue(action(.suggestNextOrder, wt: "/wt/a"))
        q.enqueue(action(.suggestNextOrder, wt: "/wt/b"))
        XCTAssertEqual(q.all().count, 2)
    }

    func testResolveRemovesAndAllowsReenqueue() {
        let q = PendingOrdersQueue()
        q.enqueue(action(.suggestNextOrder))
        let id = q.all()[0].id
        q.resolve(id: id)
        XCTAssertTrue(q.all().isEmpty)
        q.enqueue(action(.suggestNextOrder))
        XCTAssertEqual(q.all().count, 1)
    }

    func testOnChangeFiresOnEnqueueAndResolve() {
        let q = PendingOrdersQueue()
        var count = 0
        q.addObserver({ count += 1 })
        q.enqueue(action(.suggestNextOrder))
        let id = q.all()[0].id
        q.resolve(id: id)
        XCTAssertEqual(count, 2)
    }

    /// Cursor's afterAgentResponse often arrives *after* a Shell-invoked
    /// `seahelm-suggest` already queued a card whose message is tool chrome.
    /// Late prose must upgrade that summary without touching options.
    func testRefreshSuggestMessageUpgradesJunkSummary() {
        let q = PendingOrdersQueue()
        q.upsert(FirstMateAction(
            kind: .suggestNextOrder, zone: .red, worktreePath: "/wt",
            branch: "docs/5577", project: "saas-mono", terminalID: "t1",
            message: "Shell", options: ["打开架构页", "用 spec-pr 建 PR"]))
        q.refreshSuggestMessage(
            terminalID: "t1",
            message: "当前分支 docs/5577-marketing-prototype 已与远端同步，无新提交。")
        XCTAssertEqual(q.all().count, 1)
        XCTAssertEqual(q.all().first?.action.options, ["打开架构页", "用 spec-pr 建 PR"])
        XCTAssertEqual(
            q.all().first?.action.message,
            "当前分支 docs/5577-marketing-prototype 已与远端同步，无新提交。")
    }

    func testRefreshSuggestMessageKeepsMultilineSummaryWithoutSentinel() {
        let q = PendingOrdersQueue()
        q.upsert(FirstMateAction(
            kind: .suggestNextOrder, zone: .red, worktreePath: "/wt",
            branch: "docs/5577", project: "saas-mono", terminalID: "t1",
            message: "Shell", options: ["生成 Issue 规格", "查看澄清结论", "开始实施"]))
        q.refreshSuggestMessage(
            terminalID: "t1",
            message: """
            澄清完成，且未修改 Issue 或业务代码。

            已新增：

            - CONTEXT.md：记录 Dashboard 权限、指标、周期、空状态、会话隔离与数据边界术语。
            - docs/adr/0001-workbench-dashboard-metrics-boundary.md：明确员工端必须经后端聚合接口读取指标，服务端强制权限与门店范围。

            文档格式与 diff 校验均通过。

            ::seahelm-suggest:: 生成 Issue 规格 | 查看澄清结论 | 开始实施
            """)
        let message = q.all().first?.action.message ?? ""
        XCTAssertTrue(message.contains("- CONTEXT.md"))
        XCTAssertTrue(message.contains("- docs/adr/0001-workbench-dashboard-metrics-boundary.md"))
        XCTAssertTrue(message.contains("文档格式与 diff 校验均通过。"))
        XCTAssertFalse(message.contains("::seahelm-suggest::"))
    }

    func testRefreshSuggestMessageDoesNotClobberRealProse() {
        let q = PendingOrdersQueue()
        q.upsert(FirstMateAction(
            kind: .suggestNextOrder, zone: .red, worktreePath: "/wt",
            branch: "b", project: "p", terminalID: "t1",
            message: "Already have a good summary.", options: ["a"]))
        q.refreshSuggestMessage(terminalID: "t1", message: "Shorter late text")
        XCTAssertEqual(q.all().first?.action.message, "Already have a good summary.")
    }
}

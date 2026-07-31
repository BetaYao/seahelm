import XCTest
@testable import seahelm

final class IMessageRuleCoalescerTests: XCTestCase {

    private var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
    private var fired: [(prompt: String, target: IMessageRuleTarget)] = []

    private func makeCoalescer(window: TimeInterval = 30) -> IMessageRuleCoalescer {
        scheduled = []
        fired = []
        return IMessageRuleCoalescer(window: window) { [weak self] delay, work in
            self?.scheduled.append((delay, work))
        }
    }

    private func target(_ value: String = "seahelm-task-sre-monitoring") -> IMessageRuleTarget {
        IMessageRuleTarget(kind: .pane, value: value)
    }

    private func enqueue(_ c: IMessageRuleCoalescer, prompt: String, pane: String = "seahelm-task-sre-monitoring") {
        c.enqueue(prompt: prompt, target: target(pane), ruleName: "aliyun") { [weak self] combined, t in
            self?.fired.append((combined, t))
        }
    }

    func testSingleAlertFiresUnchangedAfterWindow() {
        let c = makeCoalescer()
        enqueue(c, prompt: "alert-80")

        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(scheduled[0].delay, 30)
        XCTAssertTrue(fired.isEmpty, "must wait for the window")

        scheduled[0].work()

        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired[0].prompt, "alert-80")
        XCTAssertEqual(fired[0].target.value, "seahelm-task-sre-monitoring")
    }

    /// The Aliyun case: 80% and 90% SMS land in the same second for one pane.
    func testBurstToSamePaneMergesIntoOnePrompt() {
        let c = makeCoalescer()
        enqueue(c, prompt: "发生告警…cpu>=80 当前值: 84.07")
        enqueue(c, prompt: "发生告警…cpu>=90 当前值: 93.38")

        XCTAssertEqual(scheduled.count, 1, "second hit must not restart the window")
        scheduled[0].work()

        XCTAssertEqual(fired.count, 1)
        let body = fired[0].prompt
        XCTAssertTrue(body.contains("2 条告警"), body)
        XCTAssertTrue(body.contains("84.07"), body)
        XCTAssertTrue(body.contains("93.38"), body)
        XCTAssertTrue(body.contains("—— 1/2 ——"), body)
        XCTAssertTrue(body.contains("—— 2/2 ——"), body)
    }

    func testDifferentPanesDoNotMerge() {
        let c = makeCoalescer()
        enqueue(c, prompt: "a", pane: "pane-a")
        enqueue(c, prompt: "b", pane: "pane-b")

        XCTAssertEqual(scheduled.count, 2)
        scheduled[0].work()
        scheduled[1].work()

        XCTAssertEqual(fired.map(\.prompt), ["a", "b"])
    }

    func testIdenticalPromptsInWindowAreDeduped() {
        let c = makeCoalescer()
        enqueue(c, prompt: "same-alert")
        enqueue(c, prompt: "same-alert")
        scheduled[0].work()

        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired[0].prompt, "same-alert",
                       "exact duplicates (SMS retry) must not become a 2-alert merge")
    }

    func testCombineHelperFormatsMultiAlertPrompt() {
        let one = IMessageRuleCoalescer.combine(["only"])
        XCTAssertEqual(one, "only")

        let two = IMessageRuleCoalescer.combine(["first", "second"])
        XCTAssertTrue(two.hasPrefix("收到 2 条告警"))
        XCTAssertTrue(two.contains("—— 1/2 ——\nfirst"))
        XCTAssertTrue(two.contains("—— 2/2 ——\nsecond"))
    }
}

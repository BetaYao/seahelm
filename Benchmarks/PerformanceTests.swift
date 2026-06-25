import XCTest
@testable import amux

final class PerformanceTests: XCTestCase {

    // MARK: - Test 1: AgentCardView creation + configure overhead

    func testAgentCardCreationPerformance() {
        measure {
            for i in 0..<20 {
                let card = AgentCardView()
                card.configure(
                    id: "/path/to/worktree/\(i)",
                    project: "my-project",
                    thread: "feature-branch-\(i)",
                    status: "running",
                    lastMessage: "Editing file src/components/App.tsx...",
                    totalDuration: "01:23:45",
                    roundDuration: "00:05:30"
                )
            }
        }
    }

    // MARK: - Test 2: MiniCardView creation + constraint activation (simulates rebuildLeftRight)

    func testMiniCardRebuildPerformance() {
        measure {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false

            for i in 0..<20 {
                let card = MiniCardView()
                card.configure(
                    id: "/path/to/worktree/\(i)",
                    project: "my-project",
                    thread: "feature-branch-\(i)",
                    status: ["running", "waiting", "idle", "error"][i % 4],
                    lastMessage: "Some agent output message line \(i)",
                    totalDuration: "00:45:12",
                    roundDuration: "00:02:30"
                )
                card.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(card)

                NSLayoutConstraint.activate([
                    card.widthAnchor.constraint(equalToConstant: 200),
                ])
            }

            // Simulate what happens: destroy everything (like rebuildLeftRight does)
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        }
    }

    // MARK: - Test 3: SemanticColors allocation overhead

    func testSemanticColorsAllocationPerformance() {
        measure {
            for _ in 0..<10_000 {
                _ = SemanticColors.panel2.cgColor
                _ = SemanticColors.bg.cgColor
                _ = SemanticColors.text.cgColor
                _ = SemanticColors.line.cgColor
                _ = SemanticColors.muted.cgColor
                _ = SemanticColors.line.cgColor
                _ = SemanticColors.running.cgColor
                _ = SemanticColors.waiting.cgColor
            }
        }
    }

    // MARK: - Test 4: StatusDetector + text pattern matching (simulates pollAll)

    func testStatusDetectorPerformance() {
        let detector = StatusDetector()
        let agentDef = AgentDef(
            name: "claude",
            rules: [
                AgentRule(status: "Running", patterns: ["to interrupt"]),
                AgentRule(status: "Error", patterns: ["ERROR", "error:"]),
                AgentRule(status: "Waiting", patterns: ["?", "(y/n)", "(yes/no)"]),
            ],
            defaultStatus: "Idle",
            messageSkipPatterns: ["shift+tab", "accept edits", "to interrupt"]
        )

        // Simulate 1000 lines of terminal output
        let bigContent = (0..<1000).map { i in
            "line \(i): some typical terminal output with various characters and content"
        }.joined(separator: "\n")

        measure {
            // Simulate polling 10 surfaces, each with large content
            for _ in 0..<10 {
                _ = detector.detect(
                    processStatus: .running,
                    shellInfo: nil,
                    content: bigContent,
                    agentDef: agentDef
                )
                _ = agentDef.extractLastMessage(from: bigContent, maxLen: 80)
            }
        }
    }

    // MARK: - Test 5: GridLayout calculation (simulates viewDidLayout)

    func testGridLayoutCalculationPerformance() {
        measure {
            for _ in 0..<1000 {
                let layout = GridLayout(
                    availableWidth: 1200,
                    availableHeight: 800,
                    cardCount: 20,
                    minCardWidth: 300,
                    spacing: 12,
                    aspectRatio: 0.6
                )
                for i in 0..<20 {
                    _ = layout.cardFrame(at: i)
                }
            }
        }
    }

    // MARK: - Test 6: Full rebuild cycle (create + configure + destroy)

    func testFullRebuildCyclePerformance() {
        // Simulates what happens every 2 seconds when status changes:
        // destroy all cards, then recreate them all
        let container = NSView()
        container.wantsLayer = true

        measure {
            // Destroy phase
            container.subviews.forEach { $0.removeFromSuperview() }

            // Rebuild phase: create 20 AgentCardViews
            for i in 0..<20 {
                let card = AgentCardView()
                card.configure(
                    id: "/path/\(i)",
                    project: "project-\(i % 3)",
                    thread: "branch-\(i)",
                    status: ["running", "waiting", "idle", "error"][i % 4],
                    lastMessage: "Agent is working on something important right now...",
                    totalDuration: "01:00:00",
                    roundDuration: "00:10:00"
                )
                card.translatesAutoresizingMaskIntoConstraints = true
                container.addSubview(card)

                // Simulate grid frame assignment
                let col = i % 4
                let row = i / 4
                card.frame = NSRect(
                    x: CGFloat(col) * 312,
                    y: CGFloat(row) * 187,
                    width: 300,
                    height: 175
                )
            }
        }
    }

    // MARK: - Test 7: updateAppearance call frequency

    func testUpdateAppearanceOverhead() {
        let cards = (0..<20).map { i -> AgentCardView in
            let card = AgentCardView()
            card.configure(
                id: "/path/\(i)",
                project: "project",
                thread: "branch-\(i)",
                status: "running",
                lastMessage: "Working...",
                totalDuration: "00:30:00",
                roundDuration: "00:05:00"
            )
            return card
        }

        measure {
            // Simulate what wantsUpdateLayer=true causes:
            // updateLayer() is called on every display cycle for every card
            for _ in 0..<60 {  // ~1 second at 60fps
                for card in cards {
                    card.updateLayer()
                }
            }
        }
    }

    // MARK: - Test 8: Theme.refreshSubviews recursive traversal

    func testThemeRefreshSubviewsPerformance() {
        // Build a realistic view hierarchy: root > 4 containers > 20 cards each (80 leaf views)
        // Each card has 4 subviews (statusDot, titleLabel, messageLabel, timeLabel)
        // Total: ~400 views
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        root.wantsLayer = true

        for _ in 0..<4 {
            let container = NSView()
            container.wantsLayer = true
            root.addSubview(container)

            for _ in 0..<20 {
                let card = AgentCardView()
                card.configure(
                    id: "/path/test",
                    project: "project",
                    thread: "branch",
                    status: "running",
                    lastMessage: "Working...",
                    totalDuration: "00:30:00",
                    roundDuration: "00:05:00"
                )
                container.addSubview(card)
            }
        }

        measure {
            // Simulate what Theme.applyAppearance does: recursive needsDisplay + needsLayout
            recursiveRefresh(root)
        }
    }

    /// Mirrors Theme.refreshSubviews exactly
    private func recursiveRefresh(_ view: NSView) {
        view.needsDisplay = true
        view.needsLayout = true
        if view.wantsLayer {
            view.layer?.setNeedsDisplay()
        }
        for sub in view.subviews {
            recursiveRefresh(sub)
        }
    }

    // MARK: - Test 9: Sidebar full table reload vs single-row update

    func testSidebarFullReloadPerformance() {
        // Simulates SidebarViewController.updateStatus calling tableView.reloadData()
        // for every single status change (happens every 2 seconds per surface)
        let tableView = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("test"))
        tableView.addTableColumn(column)

        let dataSource = MockTableDataSource(rowCount: 30)
        tableView.dataSource = dataSource

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        scrollView.documentView = tableView

        measure {
            // Simulate 10 surfaces each triggering a full reload
            for _ in 0..<10 {
                tableView.reloadData()
            }
        }
    }

    // MARK: - Test 10: Shadow without shadowPath cost

    func testShadowWithoutPathPerformance() {
        // AIPanelView and NotificationPanelView use shadows without shadowPath
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        container.wantsLayer = true

        measure {
            for _ in 0..<100 {
                let panel = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 800))
                panel.wantsLayer = true
                panel.shadow = NSShadow()
                panel.layer?.shadowColor = NSColor.black.withAlphaComponent(0.12).cgColor
                panel.layer?.shadowOffset = CGSize(width: -8, height: 0)
                panel.layer?.shadowRadius = 16
                panel.layer?.shadowOpacity = 1.0
                // NO shadowPath — forces Core Animation to rasterize from shape
                container.addSubview(panel)
            }
            container.subviews.forEach { $0.removeFromSuperview() }
        }
    }

    // MARK: - Test 11: Shadow WITH shadowPath (comparison baseline)

    func testShadowWithPathPerformance() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        container.wantsLayer = true

        measure {
            for _ in 0..<100 {
                let panel = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 800))
                panel.wantsLayer = true
                panel.shadow = NSShadow()
                panel.layer?.shadowColor = NSColor.black.withAlphaComponent(0.12).cgColor
                panel.layer?.shadowOffset = CGSize(width: -8, height: 0)
                panel.layer?.shadowRadius = 16
                panel.layer?.shadowOpacity = 1.0
                // WITH shadowPath — Core Animation uses pre-computed path
                panel.layer?.shadowPath = CGPath(rect: panel.bounds, transform: nil)
                container.addSubview(panel)
            }
            container.subviews.forEach { $0.removeFromSuperview() }
        }
    }

    // MARK: - Test 12: TitleBar updateLayer cascade to all project tabs

    func testTitleBarUpdateLayerCascadePerformance() {
        // TitleBar.updateLayer() calls needsDisplay on every project tab
        // Each ProjectTabView.updateLayer() accesses SemanticColors
        let titleBar = TitleBarView()
        titleBar.wantsLayer = true
        titleBar.frame = NSRect(x: 0, y: 0, width: 1200, height: 36)

        // Add 10 project tabs
        titleBar.projects = (0..<10).map { "project-\($0)" }
        titleBar.renderTabs()

        measure {
            // Simulate 60 frames of updateLayer cascade
            for _ in 0..<60 {
                titleBar.updateLayer()
            }
        }
    }

    // MARK: - Test 13: AIPanelView updateLayer overhead (iterates all bubbles)

    func testAIPanelUpdateLayerPerformance() {
        let panel = AIPanelView()
        panel.frame = NSRect(x: 0, y: 0, width: 350, height: 800)

        // Add 20 TODO items
        let items = (0..<20).map {
            AIPanelView.TodoDisplayItem(
                id: $0,
                task: "Task number \($0) with some content to render.",
                status: $0 % 3 == 0 ? "running" : "approved",
                issue: "#\($0)",
                worktree: nil,
                progress: nil
            )
        }
        panel.updateTodoItems(items)

        measure {
            // Simulate 60 frames
            for _ in 0..<60 {
                panel.updateLayer()
            }
        }
    }

    // MARK: - Test 14: FocusPanelView creation + configure

    func testFocusPanelConfigurePerformance() {
        let panel = FocusPanelView()
        panel.frame = NSRect(x: 0, y: 0, width: 900, height: 600)

        measure {
            // Simulate repeated reconfiguration (happens on every card click)
            for i in 0..<100 {
                panel.configure(
                    name: "Agent-\(i % 5)",
                    project: "project-\(i % 3)",
                    thread: "feature-branch-\(i)",
                    status: ["running", "waiting", "idle", "error"][i % 4],
                    total: "01:23:45",
                    round: "00:05:30"
                )
            }
        }
    }

    // MARK: - Test 15: Sidebar cell view creation (creates new views per row every time)

    func testSidebarCellCreationPerformance() {
        // SidebarViewController.tableView(_:viewFor:row:) creates brand new NSView
        // with labels, dots, and constraints for EVERY row on EVERY reload
        measure {
            for i in 0..<30 {
                let cell = NSView()

                let nameLabel = NSTextField(labelWithString: "worktree-branch-\(i)")
                nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
                nameLabel.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(nameLabel)

                let dotView = NSView()
                dotView.wantsLayer = true
                dotView.layer?.cornerRadius = 4
                dotView.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(dotView)

                let messageLabel = NSTextField(labelWithString: "Agent is doing work...")
                messageLabel.font = NSFont.systemFont(ofSize: 10)
                messageLabel.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(messageLabel)

                NSLayoutConstraint.activate([
                    nameLabel.topAnchor.constraint(equalTo: cell.topAnchor, constant: 10),
                    nameLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                    nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: dotView.leadingAnchor, constant: -8),
                    dotView.widthAnchor.constraint(equalToConstant: 8),
                    dotView.heightAnchor.constraint(equalToConstant: 8),
                    dotView.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
                    dotView.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
                    messageLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
                    messageLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                    messageLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
                ])
            }
        }
    }
}

// MARK: - Test Helpers

private class MockTableDataSource: NSObject, NSTableViewDataSource {
    let rowCount: Int
    init(rowCount: Int) {
        self.rowCount = rowCount
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        return rowCount
    }
}

import AppKit
import UserNotifications

extension Notification.Name {
    static let navigateToWorktree = Notification.Name("seahelm.navigateToWorktree")
    static let repoViewDidChangeWorktree = Notification.Name("seahelm.repoViewDidChangeWorktree")
    static let repoViewDidChangeFocusedPane = Notification.Name("seahelm.repoViewDidChangeFocusedPane")
}

/// Sends macOS system notifications when agent status changes to actionable states.
class NotificationManager: NSObject {
    static let shared = NotificationManager()

    private var lastNotified: [String: Date] = [:]
    private let cooldown: TimeInterval = 30  // Don't spam same worktree within 30s

    private override init() {
        super.init()
        requestPermission()
    }

    private static let categoryIdentifier = "seahelm.agentStatus"
    private static let openTerminalAction = "open_terminal"
    private static let maxBodyLength = 80

    private func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("Notification permission error: \(error)")
            }
        }
        UNUserNotificationCenter.current().delegate = self

        // Register notification category with action buttons
        let openAction = UNNotificationAction(
            identifier: Self.openTerminalAction,
            title: "Open Terminal",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [openAction],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func shouldNotify(terminalID: String, oldStatus: AgentStatus, newStatus: AgentStatus) -> Bool {
        guard oldStatus == .running else { return false }
        guard newStatus == .waiting || newStatus == .error || newStatus == .idle else { return false }
        if let last = lastNotified[terminalID], Date().timeIntervalSince(last) < cooldown {
            return false
        }
        lastNotified[terminalID] = Date()
        return true
    }

    static func formatTitle(status: AgentStatus, workspaceName: String, branch: String, paneIndex: Int, paneCount: Int) -> String {
        let target = displayTarget(workspaceName: workspaceName, branch: branch)
        let base: String
        switch status {
        case .idle: base = "Agent finished — \(target)"
        case .waiting: base = "Agent needs input — \(target)"
        case .error: base = "Agent error — \(target)"
        default: base = "Agent status — \(target)"
        }
        if paneCount > 1 {
            return "\(base) [Pane \(paneIndex)]"
        }
        return base
    }

    static func formatTitle(
        status: AgentStatus,
        workspaceName: String,
        branch: String,
        paneIndex: Int,
        paneCount: Int,
        lastMessage: String
    ) -> String {
        let target = displayTarget(workspaceName: workspaceName, branch: branch)
        let base: String
        switch status {
        case .error:
            if let summary = summarizeErrorTitle(from: lastMessage) {
                base = "\(summary) — \(target)"
            } else {
                base = "Agent error — \(target)"
            }
        default:
            switch status {
            case .idle: base = "Agent finished — \(target)"
            case .waiting: base = "Agent needs input — \(target)"
            default: base = "Agent status — \(target)"
            }
        }
        if paneCount > 1 {
            return "\(base) [Pane \(paneIndex)]"
        }
        return base
    }

    static func formatBody(
        status: AgentStatus,
        workspaceName: String,
        branch: String,
        lastMessage: String,
        lastUserPrompt: String = ""
    ) -> String {
        let target = displayTarget(workspaceName: workspaceName, branch: branch)
        let fallback: String
        switch status {
        case .waiting: fallback = "\(target) is waiting for your response"
        case .error: fallback = "\(target) encountered an error"
        case .idle: fallback = "\(target) completed its task"
        default: fallback = ""
        }

        let trimmed = lastMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        let summary: String
        switch status {
        case .error:
            summary = summarizeErrorBody(from: trimmed) ?? trimmed
        case .waiting:
            summary = summarizeWaitingBody(from: trimmed)
        case .idle:
            summary = summarizeIdleBody(from: trimmed, lastUserPrompt: lastUserPrompt)
        default:
            summary = trimmed
        }
        return truncateBody(summary)
    }

    private static func displayTarget(workspaceName: String, branch: String) -> String {
        workspaceName.isEmpty ? branch : "\(workspaceName) / \(branch)"
    }

    private static func summarizeErrorTitle(from message: String) -> String? {
        let lower = message.lowercased()
        if lower.contains("failed bash cd") || lower.contains(" cd ") {
            return "cd failed"
        }
        if lower.contains("no such file") || lower.contains("directory not found") || lower.contains("not found") {
            return "Worktree missing"
        }
        if lower.contains("permission denied") {
            return "Permission denied"
        }
        return nil
    }

    private static func summarizeErrorBody(from message: String) -> String? {
        let lower = message.lowercased()
        if lower.contains("failed bash cd") || lower.contains(" cd ") {
            if let leaf = pathLeaf(in: message) {
                return "Cannot open \(leaf) worktree"
            }
            return "Cannot open worktree directory"
        }
        if lower.contains("no such file") || lower.contains("directory not found") || lower.contains("not found") {
            if let leaf = pathLeaf(in: message) {
                return "\(leaf) worktree directory is missing"
            }
            return "Worktree directory is missing"
        }
        if lower.contains("permission denied") {
            return "Permission denied while opening worktree"
        }
        return sanitizeMessage(message)
    }

    private static func summarizeWaitingBody(from message: String) -> String {
        sanitizeMessage(message)
    }

    private static func summarizeIdleBody(from message: String, lastUserPrompt: String) -> String {
        let trimmedPrompt = lastUserPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            return "\(sanitizeMessage(trimmedPrompt)) — Task completed"
        }
        return sanitizeMessage(message)
    }

    private static func sanitizeMessage(_ message: String) -> String {
        let collapsed = message.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let parts = collapsed.split(whereSeparator: \.isWhitespace)
        let rewritten = parts.map { token -> String in
            let raw = String(token)
            if raw.hasPrefix("/") {
                return URL(fileURLWithPath: raw).lastPathComponent
            }
            return raw
        }.joined(separator: " ")
        return rewritten
    }

    private static func pathLeaf(in message: String) -> String? {
        for token in message.split(whereSeparator: \.isWhitespace).reversed() {
            let raw = String(token)
            guard raw.hasPrefix("/") else { continue }
            let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,:;"))
            let leaf = URL(fileURLWithPath: cleaned).lastPathComponent
            if !leaf.isEmpty {
                return leaf
            }
        }
        return nil
    }

    private static func truncateBody(_ body: String) -> String {
        guard body.count > maxBodyLength else { return body }
        return String(body.prefix(maxBodyLength - 3)) + "..."
    }

    static func formatSystemTitle(status: AgentStatus) -> String {
        switch status {
        case .idle:
            return "Finished successfully"
        case .waiting:
            return "Awaiting your response"
        case .error:
            return "Exited with error"
        default:
            return status.rawValue
        }
    }

    static func formatSystemSubtitle(workspaceName: String, branch: String, paneIndex: Int, paneCount: Int) -> String {
        let target = displayTarget(workspaceName: workspaceName, branch: branch)
        if paneCount > 1 {
            return "\(target) [Pane \(paneIndex)]"
        }
        return target
    }

    static func formatSystemBody(status: AgentStatus, workspaceName: String, branch: String, lastMessage: String, lastUserPrompt: String = "") -> String {
        let trimmedPrompt = lastUserPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            return truncateBody(sanitizeMessage(trimmedPrompt))
        }
        return formatBody(status: status, workspaceName: workspaceName, branch: branch, lastMessage: lastMessage)
    }

    /// Per-pane notification with terminalID-based cooldown.
    /// `isFocusedPane`: true when this pane is the currently focused pane — suppresses system notification.
    func notify(terminalID: String, worktreePath: String, workspaceName: String, branch: String,
                paneIndex: Int, paneCount: Int,
                oldStatus: AgentStatus, newStatus: AgentStatus, lastMessage: String,
                lastUserPrompt: String = "",
                isFocusedPane: Bool) {
        guard shouldNotify(terminalID: terminalID, oldStatus: oldStatus, newStatus: newStatus) else { return }

        let title = Self.formatSystemTitle(status: newStatus)
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = Self.formatSystemSubtitle(
            workspaceName: workspaceName,
            branch: branch,
            paneIndex: paneIndex,
            paneCount: paneCount
        )

        content.body = Self.formatSystemBody(
            status: newStatus,
            workspaceName: workspaceName,
            branch: branch,
            lastMessage: lastMessage,
            lastUserPrompt: lastUserPrompt
        )
        content.sound = newStatus == .error ? .defaultCritical : .default

        let historyPaneIndex: Int? = paneCount > 1 ? paneIndex : nil
        let entry = NotificationEntry(
            workspaceName: workspaceName,
            branch: branch,
            worktreePath: worktreePath,
            status: newStatus,
            message: content.body,
            paneIndex: historyPaneIndex
        )
        NotificationHistory.shared.add(entry)

        // Only suppress system notification for the currently focused pane
        if isFocusedPane { return }

        content.userInfo = ["worktreePath": worktreePath, "paneIndex": paneIndex]
        content.categoryIdentifier = Self.categoryIdentifier

        let request = UNNotificationRequest(
            identifier: "seahelm-\(worktreePath.hashValue)-\(paneIndex)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Failed to send notification: \(error)") }
        }
    }

    /// Notify when agent transitions to a notable state
    func notify(
        worktreePath: String,
        workspaceName: String,
        branch: String,
        oldStatus: AgentStatus,
        newStatus: AgentStatus,
        lastMessage: String = "",
        lastUserPrompt: String = ""
    ) {
        // Only notify for transitions TO these states
        guard newStatus == .waiting || newStatus == .error || newStatus == .idle else { return }

        // Only notify if it was previously running (agent finished something)
        guard oldStatus == .running else { return }

        // Cooldown per worktree
        if let last = lastNotified[worktreePath], Date().timeIntervalSince(last) < cooldown {
            return
        }
        lastNotified[worktreePath] = Date()

        // Always add to in-app history
        let historyMessage: String
        let content = UNMutableNotificationContent()

        switch newStatus {
        case .waiting:
            content.title = Self.formatSystemTitle(status: newStatus)
            content.subtitle = Self.formatSystemSubtitle(
                workspaceName: workspaceName,
                branch: branch,
                paneIndex: 1,
                paneCount: 1
            )
            content.body = Self.formatSystemBody(
                status: newStatus,
                workspaceName: workspaceName,
                branch: branch,
                lastMessage: lastMessage,
                lastUserPrompt: lastUserPrompt
            )
            content.sound = .default
            historyMessage = content.body
        case .error:
            content.title = Self.formatSystemTitle(status: newStatus)
            content.subtitle = Self.formatSystemSubtitle(
                workspaceName: workspaceName,
                branch: branch,
                paneIndex: 1,
                paneCount: 1
            )
            content.body = Self.formatSystemBody(
                status: newStatus,
                workspaceName: workspaceName,
                branch: branch,
                lastMessage: lastMessage,
                lastUserPrompt: lastUserPrompt
            )
            content.sound = .defaultCritical
            historyMessage = content.body
        case .idle:
            content.title = Self.formatSystemTitle(status: newStatus)
            content.subtitle = Self.formatSystemSubtitle(
                workspaceName: workspaceName,
                branch: branch,
                paneIndex: 1,
                paneCount: 1
            )
            content.body = Self.formatSystemBody(
                status: newStatus,
                workspaceName: workspaceName,
                branch: branch,
                lastMessage: lastMessage,
                lastUserPrompt: lastUserPrompt
            )
            content.sound = .default
            historyMessage = content.body
        default:
            return
        }

        // Add to in-app history
        let entry = NotificationEntry(
            workspaceName: workspaceName,
            branch: branch,
            worktreePath: worktreePath,
            status: newStatus,
            message: historyMessage
        )
        NotificationHistory.shared.add(entry)

        // Don't send system notification if app is frontmost
        if NSApp.isActive { return }

        content.userInfo = ["worktreePath": worktreePath]
        content.categoryIdentifier = Self.categoryIdentifier

        let request = UNNotificationRequest(
            identifier: "seahelm-\(worktreePath.hashValue)",
            content: content,
            trigger: nil  // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Failed to send notification: \(error)")
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Show notification even when app is in foreground (for secondary monitors)
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Handle notification click or action button
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo

        // Both default tap and "Open Terminal" action navigate to worktree
        let shouldNavigate = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            || response.actionIdentifier == Self.openTerminalAction

        if shouldNavigate, let path = userInfo["worktreePath"] as? String {
            let paneIndex = userInfo["paneIndex"] as? Int
            DispatchQueue.main.async {
                NotificationHistory.shared.markLatestRead(worktreePath: path, paneIndex: paneIndex)
                guard let appDelegate = NSApp.delegate as? AppDelegate,
                      let mwc = appDelegate.mainWindowController else { return }

                // Bring existing window to front without creating a new one
                mwc.window?.deminiaturize(nil)
                mwc.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)

                // Navigate directly — no NotificationCenter broadcast
                mwc.tabCoordinator.handleNavigateToWorktree(worktreePath: path, paneIndex: paneIndex)
            }
        }

        completionHandler()
    }
}

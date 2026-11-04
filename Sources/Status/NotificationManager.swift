import AppKit
import UserNotifications

extension Notification.Name {
    static let navigateToWorktree = Notification.Name("seahelm.navigateToWorktree")
    static let repoViewDidChangeFocusedPane = Notification.Name("seahelm.repoViewDidChangeFocusedPane")
    /// Posted by `GhosttyNSView.becomeFirstResponder` with the `Station` as
    /// object — the synchronous click→title path, independent of Fleet polling.
    static let paneDidAcquireFocus = Notification.Name("seahelm.paneDidAcquireFocus")
}

/// Sends macOS system notifications when agent status changes to actionable states.
class NotificationManager: NSObject {
    static let shared = NotificationManager()

    /// Sound preference from settings: `default`, `defaultCritical`, `none`.
    var soundPreference: String = "default"

    private override init() {
        super.init()
        // Permission is requested at launch or on the first delivery path.
        configureCategories()
    }

    private static let categoryIdentifier = "seahelm.agentStatus"
    private static let openTerminalAction = "open_terminal"
    private static let maxBodyLength = 80

    /// Request notification authorization (idempotent).
    func requestPermission(completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("Notification permission error: \(error)")
            }
            if !granted {
                NSLog("Notification permission NOT granted — system banners will be dropped (System Settings → Notifications → seahelm)")
            }
            DispatchQueue.main.async { completion?(granted) }
        }
        UNUserNotificationCenter.current().delegate = self
    }

    private func configureCategories() {
        UNUserNotificationCenter.current().delegate = self
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

    static func openNotificationSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    func sendTestNotification(completion: ((Error?) -> Void)? = nil) {
        requestPermission { [weak self] _ in
            guard let self else { return }
            let content = UNMutableNotificationContent()
            content.title = "Seahelm"
            content.body = "Test notification — you're all set."
            if let sound = self.resolvedSound(forError: false) {
                content.sound = sound
            }
            let request = UNNotificationRequest(
                identifier: "seahelm-test-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                DispatchQueue.main.async { completion?(error) }
            }
        }
    }

    func resolvedSound(forError: Bool) -> UNNotificationSound? {
        switch soundPreference {
        case "none":
            return nil
        case "defaultCritical":
            return .defaultCritical
        default:
            return forError ? .defaultCritical : .default
        }
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
        // Check command-not-found before the generic "not found" (missing
        // worktree) clause, which would otherwise swallow it.
        if lower.contains("command not found") {
            return "Command not found"
        }
        if lower.contains("no such file") || lower.contains("directory not found") || lower.contains("not found") {
            return "Worktree missing"
        }
        if lower.contains("permission denied") || lower.contains("eacces") {
            return "Permission denied"
        }
        // Broader agent/tool/API failures (Claude, Codex, and generic tools use
        // varied wording; match on stable substrings rather than one phrasing).
        if lower.contains("rate limit") || lower.contains("usage limit") || lower.contains("quota") || lower.contains("overloaded") {
            return "Rate limited"
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return "Timed out"
        }
        if lower.contains("connection") || lower.contains("network") || lower.contains("econnrefused") {
            return "Network error"
        }
        if lower.contains("api error") || lower.contains("stream error") || lower.contains("server error") {
            return "API error"
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
        // Before the generic "not found" (missing worktree) clause.
        if lower.contains("command not found") {
            return sanitizeMessage(message)
        }
        if lower.contains("no such file") || lower.contains("directory not found") || lower.contains("not found") {
            if let leaf = pathLeaf(in: message) {
                return "\(leaf) worktree directory is missing"
            }
            return "Worktree directory is missing"
        }
        if lower.contains("permission denied") || lower.contains("eacces") {
            return "Permission denied while opening worktree"
        }
        if lower.contains("rate limit") || lower.contains("usage limit") || lower.contains("quota") || lower.contains("overloaded") {
            return "Agent hit a rate/usage limit"
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return "Agent request timed out"
        }
        if lower.contains("connection") || lower.contains("network") || lower.contains("econnrefused") {
            return "Network error reaching the agent"
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

    /// Mirrors a delivered banner out to the registered chat channels
    /// (Telegram), so a phone learns an agent finished without seahelm having to own
    /// a transport, a relay, or push certificates — the IM app already has all
    /// three.
    ///
    /// Hung off `deliver` rather than off Fleet's ingest so the chat message
    /// inherits this type's gating: the running → done edge, the per-key
    /// cooldown, and the stability delay that swallows an idle flicker mid-turn.
    /// The Fleet broadcast this replaced had none of those, and never fired on
    /// completion at all.
    ///
    /// Fires on every edge that earns a banner, whether or not the banner is
    /// actually shown, and reports which via `bannerSuppressed`. Suppression is
    /// a statement about *this screen* — the pane is on it, frontmost — and the
    /// phone is not this screen: a chat that bound itself to the pane with
    /// `/go #n` asked for its answers from somewhere else and must still get
    /// them. Deciding it here would silence that chat too, which is the bug
    /// where an order sent from Telegram was answered only in the terminal the
    /// sender happened to be sitting in front of. The receiver draws the line
    /// between a bound conversation and a fleet-wide listener.
    ///
    /// Set by MainWindowController; nil in tests and headless runs.
    var onDeliverExternal: ((_ status: AgentStatus, _ title: String, _ subtitle: String, _ body: String,
                             _ terminalID: String, _ bannerSuppressed: Bool) -> Void)?

    /// Whether a suggestion card for this pane is already expanded on screen (the
    /// island popped open with it). Set by MainWindowController; nil in tests and
    /// headless runs, where nothing is on screen to be redundant with.
    var isCardOnScreen: ((_ terminalID: String) -> Bool)?

    /// Whether the system banner would only repeat something the user is already
    /// looking at. Both surfaces that can pre-empt it — the focused pane itself and
    /// an expanded island card — only count while seahelm is frontmost: in the
    /// background the island collapses on its own after ten seconds and may never
    /// have been seen at all, so the banner is the only durable record.
    static func shouldSuppressBanner(appActive: Bool, targetVisible: Bool, cardOnScreen: Bool) -> Bool {
        appActive && (targetVisible || cardOnScreen)
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

    static func formatSystemSubtitle(workspaceName: String, branch: String, paneIndex: Int, paneCount: Int,
                                      sessionTitle: String? = nil) -> String {
        var target = displayTarget(workspaceName: workspaceName, branch: branch)
        if let title = sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            target += " · \(title)"
        }
        if paneCount > 1 {
            return "\(target) [Pane \(paneIndex)]"
        }
        return target
    }

    static func formatSystemBody(status: AgentStatus, workspaceName: String, branch: String, lastMessage: String, lastUserPrompt: String = "", lastAssistantMessage: String = "") -> String {
        // The agent's own final prose is the most informative line — placeholder
        // hook labels ("Processing prompt") in lastMessage carry nothing.
        let trimmedAssistant = lastAssistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAssistant.isEmpty {
            return truncateBody(sanitizeMessage(trimmedAssistant))
        }
        let trimmedPrompt = lastUserPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            return truncateBody(sanitizeMessage(trimmedPrompt))
        }
        return formatBody(status: status, workspaceName: workspaceName, branch: branch, lastMessage: lastMessage)
    }

    /// What a chat channel gets, which is deliberately not what a banner gets.
    ///
    /// A macOS banner has two lines, so `formatSystemBody` collapses newlines,
    /// shortens paths and cuts to `maxBodyLength` (80) — and, when the agent
    /// produced no prose of its own, falls back to the user's *own* last
    /// prompt. On a desktop banner that reads as "this is the task you asked
    /// for"; mirrored to a phone it reads as the bot repeating back the message
    /// you just sent it, followed by an ellipsis where the rest should be.
    ///
    /// A chat has 4096 characters per message (and `TelegramFormatter.chunk`
    /// past that), keeps its line breaks, and is being read by the person who
    /// typed the prompt. So: the agent's own words, whole, or a plain statement
    /// of what happened — never an echo.
    static func formatExternalBody(
        status: AgentStatus,
        workspaceName: String,
        branch: String,
        lastMessage: String,
        lastAssistantMessage: String
    ) -> String {
        let prose = lastAssistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prose.isEmpty { return prose }
        return formatBody(status: status, workspaceName: workspaceName,
                          branch: branch, lastMessage: lastMessage)
    }

    /// A notice seahelm-core already decided on (`pane.notice`): history,
    /// banner and the chat mirror, with no decision of the app's own.
    func show(worktreePath: String, workspaceName: String, branch: String, paneIndex: Int, paneCount: Int,
              terminalID: String, newStatus: AgentStatus, lastMessage: String, lastUserPrompt: String,
              lastAssistantMessage: String, isTargetVisible: Bool) {
        deliver(worktreePath: worktreePath, workspaceName: workspaceName, branch: branch,
                paneIndex: paneIndex, paneCount: paneCount, terminalID: terminalID, newStatus: newStatus,
                lastMessage: lastMessage, lastUserPrompt: lastUserPrompt,
                lastAssistantMessage: lastAssistantMessage, isTargetVisible: isTargetVisible)
    }

    /// Builds and posts the notification (in-app history + optional system
    /// banner). Assumes eligibility was already decided by `notify`.
    private func deliver(
        worktreePath: String,
        workspaceName: String,
        branch: String,
        paneIndex: Int,
        paneCount: Int,
        terminalID: String,
        newStatus: AgentStatus,
        lastMessage: String,
        lastUserPrompt: String,
        lastAssistantMessage: String,
        isTargetVisible: Bool
    ) {
        let sessionTitle = SessionTitleLookup.title(worktreePath: worktreePath)
        let content = UNMutableNotificationContent()
        content.title = Self.formatSystemTitle(status: newStatus)
        content.subtitle = Self.formatSystemSubtitle(
            workspaceName: workspaceName,
            branch: branch,
            paneIndex: paneIndex,
            paneCount: paneCount,
            sessionTitle: sessionTitle
        )
        content.body = Self.formatSystemBody(
            status: newStatus,
            workspaceName: workspaceName,
            branch: branch,
            lastMessage: lastMessage,
            lastUserPrompt: lastUserPrompt,
            lastAssistantMessage: lastAssistantMessage
        )
        content.sound = resolvedSound(forError: newStatus == .error)
        // Group all notifications for a worktree together in Notification Center.
        content.threadIdentifier = worktreePath
        // Let errors punch through Focus / Do Not Disturb.
        if newStatus == .error {
            content.interruptionLevel = .timeSensitive
        }

        // Always record to in-app history.
        let historyPaneIndex: Int? = paneCount > 1 ? paneIndex : nil
        NotificationHistory.shared.add(NotificationEntry(
            workspaceName: workspaceName,
            branch: branch,
            worktreePath: worktreePath,
            status: newStatus,
            message: content.body,
            paneIndex: historyPaneIndex
        ))

        // Suppress the system banner only when the user can already see this
        // event — the pane itself is on screen and focused, or the island is
        // expanded showing this pane's suggestion card (the same completion,
        // rendered with the buttons that act on it).
        let cardOnScreen = !terminalID.isEmpty && isCardOnScreen?(terminalID) == true
        let bannerSuppressed = Self.shouldSuppressBanner(appActive: NSApp.isActive,
                                                         targetVisible: isTargetVisible,
                                                         cardOnScreen: cardOnScreen)

        // Mirror the banner, not the history entry: this fires on exactly the
        // edges that earn a banner, so the chat inherits the same gating. It is
        // handed the suppression flag rather than gated by it — see the
        // property's note: a chat bound to this pane hears it even while the
        // pane is on screen, a fleet-wide listener still yields to the screen.
        onDeliverExternal?(newStatus, content.title, content.subtitle,
                           Self.formatExternalBody(status: newStatus,
                                                   workspaceName: workspaceName,
                                                   branch: branch,
                                                   lastMessage: lastMessage,
                                                   lastAssistantMessage: lastAssistantMessage),
                           terminalID, bannerSuppressed)

        if bannerSuppressed { return }

        var userInfo: [String: Any] = ["worktreePath": worktreePath]
        if let historyPaneIndex { userInfo["paneIndex"] = historyPaneIndex }
        content.userInfo = userInfo
        content.categoryIdentifier = Self.categoryIdentifier

        // Unique per delivery. Reusing an identifier makes macOS update the
        // already-delivered notification in place — it re-alerts nothing and the
        // user never sees a banner for the second and later events on a worktree.
        // Grouping in Notification Center is `threadIdentifier`'s job, not this.
        let identifier = "seahelm-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Failed to send notification: \(error)") }
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

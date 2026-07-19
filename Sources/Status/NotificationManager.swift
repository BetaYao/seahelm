import AppKit
import ApplicationServices
import UserNotifications

extension Notification.Name {
    static let navigateToWorktree = Notification.Name("seahelm.navigateToWorktree")
    static let repoViewDidChangeFocusedPane = Notification.Name("seahelm.repoViewDidChangeFocusedPane")
}

/// Sends macOS system notifications when agent status changes to actionable states.
class NotificationManager: NSObject {
    static let shared = NotificationManager()

    private var lastNotified: [String: Date] = [:]

    /// Minimum seconds between delivered notifications for the same key. Injected
    /// from `Config.notifications` at startup.
    var cooldown: TimeInterval = 30

    /// Stability gate: after a qualifying edge, hold the notification this long
    /// and only deliver if the status is still the same when the timer fires.
    /// 0 disables the gate (deliver on the edge). Injected from config.
    var stabilityDelay: TimeInterval = 1.0

    /// Sound preference from onboarding / settings: `default`, `defaultCritical`, `none`.
    var soundPreference: String = "default"

    /// Latest observed status per key, updated on *every* edge (not just
    /// qualifying ones) so a pending fire can tell the agent moved on.
    private var latestStatus: [String: SailorStatus] = [:]
    /// In-flight stability timers, keyed by cooldownKey.
    private var pendingFires: [String: Timer] = [:]

    private override init() {
        super.init()
        // Permission is requested from onboarding or the first delivery path.
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

    static func openAccessibilitySystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
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

    /// Eligibility gate: only fire on a `running → (waiting | error | idle)` edge,
    /// and not more than once per `cooldown` per key. `cooldownKey` is a
    /// namespaced pane- or worktree-level identity (see
    /// `cooldownKey(terminalID:worktreePath:)`), so the pane and worktree call
    /// paths can never collide in `lastNotified`.
    ///
    /// Pure predicate — it does NOT consume the cooldown. Cooldown is recorded
    /// only when a notification is actually *delivered* (`recordDelivery`), so a
    /// notification held by the stability gate and then dropped does not burn the
    /// cooldown window.
    func shouldNotify(cooldownKey: String, oldStatus: SailorStatus, newStatus: SailorStatus,
                      now: Date = Date()) -> Bool {
        guard oldStatus == .running else { return false }
        guard newStatus == .waiting || newStatus == .error || newStatus == .idle else { return false }
        if let last = lastNotified[cooldownKey], now.timeIntervalSince(last) < cooldown {
            return false
        }
        return true
    }

    /// Whether a pending (delayed) notification for `targetStatus` should still
    /// fire, given the latest observed status for its key. Pure — extracted so the
    /// stability-gate decision is unit-testable without a live Timer.
    static func shouldDeliverPending(targetStatus: SailorStatus, latestStatus: SailorStatus?) -> Bool {
        latestStatus == targetStatus
    }

    /// Prefer a stable per-pane key (terminalID) when we have one, otherwise fall
    /// back to the worktree. Namespaced so the two never alias.
    private static func cooldownKey(terminalID: String, worktreePath: String) -> String {
        terminalID.isEmpty ? "wt:\(worktreePath)" : "tid:\(terminalID)"
    }

    static func formatTitle(status: SailorStatus, workspaceName: String, branch: String, paneIndex: Int, paneCount: Int) -> String {
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
        status: SailorStatus,
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
        status: SailorStatus,
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

    /// Mirrors a delivered banner out to the registered chat channels (WeCom /
    /// WeChat), so a phone learns an agent finished without seahelm having to own
    /// a transport, a relay, or push certificates — the IM app already has all
    /// three.
    ///
    /// Hung off `deliver` rather than off ShipLog's ingest so the chat message
    /// inherits this type's gating: the running → done edge, the per-key
    /// cooldown, and the stability delay that swallows an idle flicker mid-turn.
    /// The ShipLog broadcast this replaced had none of those, and never fired on
    /// completion at all.
    ///
    /// Set by MainWindowController; nil in tests and headless runs.
    var onDeliverExternal: ((_ status: SailorStatus, _ title: String, _ subtitle: String, _ body: String) -> Void)?

    static func formatSystemTitle(status: SailorStatus) -> String {
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

    static func formatSystemBody(status: SailorStatus, workspaceName: String, branch: String, lastMessage: String, lastUserPrompt: String = "", lastAssistantMessage: String = "") -> String {
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

    /// The single notification entry point for the whole app.
    ///
    /// Behaviour:
    ///  - Gated by `shouldNotify` (running → waiting/error/idle, per-key cooldown).
    ///  - **Always** records to the in-app `NotificationHistory`.
    ///  - Posts a macOS system notification unless the target is already visible
    ///    to the user, i.e. the app is frontmost AND `isTargetVisible` (the
    ///    worktree is the one currently on screen). If you're looking at a
    ///    *different* worktree — even in the foreground — the banner still fires
    ///    so you learn another agent needs you.
    ///
    /// - Parameters:
    ///   - terminalID: stable per-pane id used for the cooldown key; pass "" for
    ///     worktree-level callers (First Mate, inspection).
    ///   - paneIndex/paneCount: 1-based; `paneCount > 1` adds a `[Pane N]` label
    ///     and records the pane in history so a click can mark just that pane read.
    ///   - isTargetVisible: whether this worktree is the one currently shown.
    func notify(
        worktreePath: String,
        workspaceName: String,
        branch: String,
        paneIndex: Int = 1,
        paneCount: Int = 1,
        terminalID: String = "",
        oldStatus: SailorStatus,
        newStatus: SailorStatus,
        lastMessage: String,
        lastUserPrompt: String = "",
        lastAssistantMessage: String = "",
        isTargetVisible: Bool = false
    ) {
        let key = Self.cooldownKey(terminalID: terminalID, worktreePath: worktreePath)

        // Track the latest observed status for this key on *every* edge so a
        // pending stability timer can detect the agent moved on (e.g. an idle
        // flicker that flips back to running mid-turn).
        latestStatus[key] = newStatus

        guard shouldNotify(cooldownKey: key, oldStatus: oldStatus, newStatus: newStatus) else { return }

        // The delivery closure captures the fully-formed payload. Invoked either
        // immediately or when the stability timer fires and the status still holds.
        let deliver = { [weak self] in
            guard let self else { return }
            self.lastNotified[key] = Date()
            self.deliver(
                worktreePath: worktreePath,
                workspaceName: workspaceName,
                branch: branch,
                paneIndex: paneIndex,
                paneCount: paneCount,
                newStatus: newStatus,
                lastMessage: lastMessage,
                lastUserPrompt: lastUserPrompt,
                lastAssistantMessage: lastAssistantMessage,
                isTargetVisible: isTargetVisible
            )
        }

        // The stability gate only applies to the pane path, which has a live
        // status stream to cancel against. First Mate / inspection callers pass
        // terminalID == "" and never update `latestStatus`, so a timer there would
        // just add latency and always fire — deliver those immediately.
        guard stabilityDelay > 0, !terminalID.isEmpty else {
            deliver()
            return
        }

        pendingFires[key]?.invalidate()
        let targetStatus = newStatus
        let timer = Timer.scheduledTimer(withTimeInterval: stabilityDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.pendingFires[key] = nil
            guard Self.shouldDeliverPending(targetStatus: targetStatus, latestStatus: self.latestStatus[key]) else {
                return
            }
            deliver()
        }
        pendingFires[key] = timer
    }

    /// Builds and posts the notification (in-app history + optional system
    /// banner). Assumes eligibility was already decided by `notify`.
    private func deliver(
        worktreePath: String,
        workspaceName: String,
        branch: String,
        paneIndex: Int,
        paneCount: Int,
        newStatus: SailorStatus,
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
        // target (frontmost AND the worktree is on screen).
        if isTargetVisible && NSApp.isActive { return }

        // Mirror the banner, not the history entry: this fires on exactly the
        // edges that earn a banner, and is skipped by the return above when the
        // user is already looking at the pane — a phone ping for something on
        // screen in front of them is noise.
        onDeliverExternal?(newStatus, content.title, content.subtitle, content.body)

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

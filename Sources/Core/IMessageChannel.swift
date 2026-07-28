import Foundation

/// iMessage channel — the phone-side transport that replaced WeCom/WeChat.
///
/// The trade it makes: no server, no token, no relay, no push certificate. The
/// price is that both directions are local-only side doors — reading
/// `chat.db` for inbound (Full Disk Access) and driving Messages.app over
/// AppleScript for outbound (Automation permission). Neither is an API Apple
/// supports, so both are wrapped in their own type and this class only
/// orchestrates them.
///
/// Inbound is edge-triggered: an FSEvents stream on `~/Library/Messages` fires
/// when Messages commits to the WAL, and only then do we query. Polling worked
/// too, but this is seconds-fresh and costs nothing while the mailbox is quiet.
final class IMessageChannel: ExternalChannel {
    let channelId: String
    let channelType: ExternalChannelType = .imessage
    var onMessage: ((InboundMessage) -> Void)?

    private var config: IMessageConfig
    private var stateMachine = GatewayStateMachine()
    private(set) var gatewayState: GatewayState = .disconnected

    private let db: IMessageChatDB
    private let dbPath: String
    private let queue = DispatchQueue(label: "com.seahelm.imessage", qos: .utility)
    private var stream: FSEventStreamRef?
    private var lastRowId: Int64 = 0
    private var pendingDrain: DispatchWorkItem?

    /// Chat GUID last seen per sender, so a reply lands in the thread the
    /// command arrived in rather than a fresh 1:1.
    private var chatGuidBySender: [String: String] = [:]
    private let lock = NSLock()

    var onStateChange: ((GatewayState) -> Void)?

    /// Messages writes the WAL in bursts; coalesce so one conversation turn
    /// costs one query rather than four.
    private static let drainDebounce: TimeInterval = 0.25

    init(config: IMessageConfig,
         channelId: String = "imessage",
         dbPath: String = IMessageChatDB.defaultPath) {
        self.config = config
        self.channelId = channelId
        self.dbPath = dbPath
        self.db = IMessageChatDB(path: dbPath)
    }

    deinit { disconnect() }

    // MARK: - ExternalChannel

    func connect() {
        guard stateMachine.transition(to: .connecting) else { return }
        gatewayState = stateMachine.state
        onStateChange?(gatewayState)

        queue.async { [weak self] in
            guard let self else { return }

            switch self.db.probe() {
            case .missing:
                self.updateState(.error("No Messages database at \(self.dbPath)"))
                return
            case .denied(let msg):
                // Nearly always TCC, so say the thing the user has to do.
                self.updateState(.error("Full Disk Access required to read Messages (\(msg))"))
                return
            case .ok:
                break
            }

            // Start from the current tail, minus a short backfill window, so
            // turning the bridge on doesn't replay old texts as commands.
            self.lastRowId = self.db.maxRowId()
            self.rewindCursor(bySeconds: self.config.resolvedBackfillSeconds)

            self.startWatching()
            self.updateState(.connected)
            // One immediate pass picks up anything inside the backfill window.
            self.drain()
        }
    }

    func disconnect() {
        pendingDrain?.cancel()
        pendingDrain = nil
        stopWatching()
        // Captured rather than `self.db` so this stays valid when called from deinit,
        // and async rather than sync so a call from the watcher queue can't deadlock.
        let db = self.db
        queue.async { db.close() }
        updateState(.disconnected)
    }

    func send(_ message: OutboundMessage) {
        // Broadcasts (agent-finished notifications) carry no target; they go to
        // the configured default recipient. Replies carry the originating chat.
        let target = message.targetChatId
            ?? message.targetUserId
            ?? config.resolvedDefaultRecipient
            ?? ""

        guard !target.isEmpty else {
            NSLog("[iMessage] Dropping outbound: no recipient configured")
            return
        }

        let body = Self.flatten(message.content, format: message.format)
        queue.async {
            do {
                try IMessageSender.send(body, to: target)
            } catch {
                NSLog("[iMessage] Send failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Config

    /// Swap settings without tearing down the FSEvents stream — the allowlist
    /// is consulted per message, so a Settings save takes effect immediately.
    func update(config: IMessageConfig) {
        lock.lock()
        self.config = config
        lock.unlock()
    }

    // MARK: - Watching

    private func startWatching() {
        stopWatching()

        // Watch the directory, not the file: sqlite's WAL and journal are
        // separate files, and Messages replaces rather than rewrites some of
        // them, which a file-level watch would stop following.
        let dir = (dbPath as NSString).deletingLastPathComponent
        let paths = [dir] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let channel = Unmanaged<IMessageChannel>.fromOpaque(info).takeUnretainedValue()
            channel.scheduleDrain()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            updateState(.error("Could not watch \(dir)"))
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopWatching() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scheduleDrain() {
        pendingDrain?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.drain() }
        pendingDrain = work
        queue.asyncAfter(deadline: .now() + Self.drainDebounce, execute: work)
    }

    // MARK: - Draining

    /// Read every new inbound row and forward the allowed ones.
    ///
    /// The cursor advances past rejected rows too — an unauthorised sender must
    /// not wedge the bridge by leaving a permanent unread row at the head.
    private func drain() {
        let rows = db.fetchIncoming(afterRowId: lastRowId)
        guard !rows.isEmpty else { return }
        lastRowId = rows.map(\.rowId).max() ?? lastRowId

        lock.lock()
        let cfg = config
        lock.unlock()

        for row in rows {
            guard cfg.allows(handle: row.sender) else {
                NSLog("[iMessage] Ignoring message from unlisted handle \(row.sender)")
                continue
            }
            if let chatGuid = row.chatGuid {
                lock.lock()
                chatGuidBySender[row.sender] = chatGuid
                lock.unlock()
            }

            let inbound = InboundMessage(
                channelId: channelId,
                senderId: row.sender,
                senderName: row.sender,
                chatId: row.chatGuid,
                chatType: row.isGroup ? .group : .direct,
                content: row.text,
                messageId: row.guid,
                timestamp: row.date,
                replyTo: nil,
                metadata: ["rowId": row.rowId]
            )
            onMessage?(inbound)
        }
    }

    /// Walk the cursor back so messages from the last `seconds` are replayed —
    /// covers the gap between an agent finishing a text and the app launching.
    private func rewindCursor(bySeconds seconds: Double) {
        guard seconds > 0 else { return }
        let cutoff = Date().addingTimeInterval(-seconds)
        let window = Int64(200)
        let recent = db.fetchIncoming(afterRowId: max(0, lastRowId - window), limit: Int(window))
        guard let first = recent.first(where: { $0.date >= cutoff }) else { return }
        lastRowId = min(lastRowId, first.rowId - 1)
    }

    // MARK: - Formatting

    /// iMessage has no markdown. Strip the emphasis markers the notification
    /// mirror emits so a phone shows `**Finished**` as `Finished`.
    static func flatten(_ content: String, format: MessageFormat) -> String {
        guard format == .markdown else { return content }
        return content
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    // MARK: - State

    private func updateState(_ newState: GatewayState) {
        guard stateMachine.transition(to: newState) else { return }
        gatewayState = stateMachine.state
        if case .error(let msg) = newState { NSLog("[iMessage] \(msg)") }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStateChange?(self.gatewayState)
        }
    }
}

import Foundation

enum WorktreeGroupingMode: String, CaseIterable {
    case repository
    case status
    case activityTime
    /// Fully-expanded three-level view: repository header → worktree row → pane
    /// rows. Groups by repository like `.repository`; the pane expansion is a
    /// render-time concern (see `DashboardOverviewView.render`).
    case pane
}

enum WorktreeActivityBucket: String, CaseIterable {
    case recentHour
    case today
    case recentSevenDays
    case earlier
    case noActivity
}

enum WorktreeGroupID: Hashable {
    case repository(String)
    case status(AgentStatus)
    case activity(WorktreeActivityBucket)
}

struct WorktreeGroupingItem: Equatable {
    let id: String
    let path: String
    let repository: String
    let status: AgentStatus
    let lastActivityAt: Date?
    let isMainWorktree: Bool
    let creationDate: Date
    /// The repo's integration checkout rather than a fleet member. It has no
    /// agent, so its status and activity describe a shell, not work — see
    /// `groups(_:mode:now:calendar:)` for what that changes.
    let isIntegration: Bool

    init(
        id: String,
        path: String,
        repository: String,
        status: AgentStatus,
        lastActivityAt: Date?,
        isMainWorktree: Bool,
        creationDate: Date,
        isIntegration: Bool = false
    ) {
        self.id = id
        self.path = path
        self.repository = repository
        self.status = status
        self.lastActivityAt = lastActivityAt
        self.isMainWorktree = isMainWorktree
        self.creationDate = creationDate
        self.isIntegration = isIntegration
    }
}

extension WorktreeRowInfo {
    func groupingItem(creationDate: Date, isIntegration: Bool = false) -> WorktreeGroupingItem {
        WorktreeGroupingItem(
            id: id,
            path: worktreePath,
            repository: project,
            status: AgentStatus.highestPriority(paneStatuses),
            lastActivityAt: lastActivityAt,
            isMainWorktree: isMainWorktree,
            creationDate: creationDate,
            isIntegration: isIntegration
        )
    }
}

struct WorktreeGroup: Equatable {
    let id: WorktreeGroupID
    let title: String
    let status: AgentStatus?
    let items: [WorktreeGroupingItem]
}

enum WorktreeGrouping {
    static func groups(
        _ items: [WorktreeGroupingItem],
        mode: WorktreeGroupingMode,
        now: Date,
        calendar: Calendar = .current
    ) -> [WorktreeGroup] {
        switch mode {
        case .repository, .pane:
            // Belongs to its repo, so it belongs in the repo's group — pinned
            // just under main rather than sorted among the agents.
            return repositoryGroups(items)
        case .status:
            // Status groups answer "what needs me now" and time buckets answer
            // "what has been happening". The integration checkout is neither: it
            // has no agent, so its status is a shell's and its activity is
            // terminal output. Including it would only dilute both views. It is
            // surfaced separately instead.
            return statusGroups(items.filter { !$0.isIntegration })
        case .activityTime:
            return activityGroups(items.filter { !$0.isIntegration }, now: now, calendar: calendar)
        }
    }

    private static func repositoryGroups(_ items: [WorktreeGroupingItem]) -> [WorktreeGroup] {
        var repositoryOrder: [String] = []
        var groupedItems: [String: [WorktreeGroupingItem]] = [:]

        for item in items {
            let repository = item.repository.isEmpty ? "Unknown project" : item.repository
            if groupedItems[repository] == nil {
                repositoryOrder.append(repository)
            }
            groupedItems[repository, default: []].append(item)
        }

        return repositoryOrder.map { repository in
            WorktreeGroup(
                id: .repository(repository),
                title: repository,
                status: nil,
                items: groupedItems[repository, default: []].sorted(by: repositoryRowComesFirst)
            )
        }
    }

    private static func statusGroups(_ items: [WorktreeGroupingItem]) -> [WorktreeGroup] {
        let statuses: [(status: AgentStatus, title: String)] = [
            (.waiting, "Needs input"),
            (.running, "Running"),
            (.idle, "Idle"),
            (.error, "Error"),
            (.exited, "Dormant"),
            (.unknown, "Unknown"),
        ]

        return statuses.compactMap { status, title in
            let matchingItems = items.filter { $0.status == status }
            guard !matchingItems.isEmpty else { return nil }
            return WorktreeGroup(
                id: .status(status),
                title: title,
                status: status,
                items: matchingItems.sorted(by: activityRowComesFirst)
            )
        }
    }

    private static func activityGroups(
        _ items: [WorktreeGroupingItem],
        now: Date,
        calendar: Calendar
    ) -> [WorktreeGroup] {
        let buckets: [(bucket: WorktreeActivityBucket, title: String)] = [
            (.recentHour, "Recent hour"),
            (.today, "Today"),
            (.recentSevenDays, "Recent 7 days"),
            (.earlier, "Earlier"),
            (.noActivity, "No activity"),
        ]
        var groupedItems: [WorktreeActivityBucket: [WorktreeGroupingItem]] = [:]

        for item in items {
            let bucket = activityBucket(for: item.lastActivityAt, now: now, calendar: calendar)
            groupedItems[bucket, default: []].append(item)
        }

        return buckets.compactMap { bucket, title in
            guard let matchingItems = groupedItems[bucket], !matchingItems.isEmpty else { return nil }
            return WorktreeGroup(
                id: .activity(bucket),
                title: title,
                status: nil,
                items: matchingItems.sorted(by: activityRowComesFirst)
            )
        }
    }

    private static func activityBucket(
        for activity: Date?,
        now: Date,
        calendar: Calendar
    ) -> WorktreeActivityBucket {
        guard let activity else { return .noActivity }
        let age = max(0, now.timeIntervalSince(activity))
        if age < 3_600 { return .recentHour }
        if calendar.isDate(activity, inSameDayAs: now) { return .today }
        if age < 7 * 86_400 { return .recentSevenDays }
        return .earlier
    }

    private static func repositoryRowComesFirst(
        _ lhs: WorktreeGroupingItem,
        _ rhs: WorktreeGroupingItem
    ) -> Bool {
        if lhs.isMainWorktree != rhs.isMainWorktree {
            return lhs.isMainWorktree
        }
        // Pinned under main, explicitly rather than by creation date: it is a
        // fixture of the repo, and sorting it by when it happened to be made
        // would move it every time it is recreated.
        if lhs.isIntegration != rhs.isIntegration {
            return lhs.isIntegration
        }
        if lhs.creationDate != rhs.creationDate {
            return lhs.creationDate < rhs.creationDate
        }
        return lhs.path < rhs.path
    }

    private static func activityRowComesFirst(
        _ lhs: WorktreeGroupingItem,
        _ rhs: WorktreeGroupingItem
    ) -> Bool {
        switch (lhs.lastActivityAt, rhs.lastActivityAt) {
        case let (left?, right?) where left != right:
            return left > right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return lhs.path < rhs.path
        }
    }
}

struct WorktreeGroupingPreference {
    static let key = "seahelm.dashboard.worktreeGroupingMode"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> WorktreeGroupingMode {
        guard let rawValue = defaults.string(forKey: Self.key),
              let mode = WorktreeGroupingMode(rawValue: rawValue) else {
            return .repository
        }
        return mode
    }

    func save(_ mode: WorktreeGroupingMode) {
        defaults.set(mode.rawValue, forKey: Self.key)
    }
}

// MARK: - Wire format

/// Remote clients render the same groups the dashboard does. Grouping stays a
/// Mac-side computation and travels as data, so the browser cannot drift from
/// the desktop the way a re-implementation would.
extension WorktreeGroupingMode {
    init(wire: String) {
        switch wire.lowercased() {
        case "status": self = .status
        case "activity", "activitytime", "time": self = .activityTime
        case "pane": self = .pane
        default: self = .repository
        }
    }

    var wire: String {
        switch self {
        case .repository: return "repository"
        case .status: return "status"
        case .activityTime: return "activity"
        case .pane: return "pane"
        }
    }
}

extension WorktreeGroupID {
    var wire: String {
        switch self {
        case let .repository(name): return "repository:\(name)"
        case let .status(status): return "status:\(status.rawValue)"
        case let .activity(bucket): return "activity:\(bucket.rawValue)"
        }
    }
}

extension WorktreeGroupingItem {
    var dict: [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "worktree_path": path,
            "repository": repository,
            "status": status.rawValue,
            "is_main_worktree": isMainWorktree,
        ]
        if let lastActivityAt {
            d["last_activity_at"] = lastActivityAt.timeIntervalSince1970
        }
        return d
    }
}

extension WorktreeGroup {
    var dict: [String: Any] {
        var d: [String: Any] = [
            "id": id.wire,
            "title": title,
            "items": items.map(\.dict),
        ]
        if let status { d["status"] = status.rawValue }
        return d
    }
}

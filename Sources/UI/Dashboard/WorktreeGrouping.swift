import Foundation

enum WorktreeGroupingMode: String, CaseIterable {
    case repository
    case status
    case activityTime
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
    case status(SailorStatus)
    case activity(WorktreeActivityBucket)
}

struct WorktreeGroupingItem: Equatable {
    let id: String
    let path: String
    let repository: String
    let status: SailorStatus
    let lastActivityAt: Date?
    let isMainWorktree: Bool
    let creationDate: Date
}

extension SailorDisplayInfo {
    func groupingItem(creationDate: Date) -> WorktreeGroupingItem {
        WorktreeGroupingItem(
            id: id,
            path: worktreePath,
            repository: project,
            status: SailorStatus.highestPriority(paneStatuses),
            lastActivityAt: lastActivityAt,
            isMainWorktree: isMainWorktree,
            creationDate: creationDate
        )
    }
}

struct WorktreeGroup: Equatable {
    let id: WorktreeGroupID
    let title: String
    let status: SailorStatus?
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
        case .repository:
            return repositoryGroups(items)
        case .status:
            return statusGroups(items)
        case .activityTime:
            return activityGroups(items, now: now, calendar: calendar)
        }
    }

    private static func repositoryGroups(_ items: [WorktreeGroupingItem]) -> [WorktreeGroup] {
        var repositoryOrder: [String] = []
        var groupedItems: [String: [WorktreeGroupingItem]] = [:]

        for item in items {
            let repository = item.repository.isEmpty ? "Unknown repository" : item.repository
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
        let statuses: [(status: SailorStatus, title: String)] = [
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

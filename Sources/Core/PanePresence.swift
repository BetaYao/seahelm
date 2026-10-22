import Foundation

/// Which pane is acting on which. When an agent drives a sibling pane through
/// the CLI (`seahelm pane run #12 …`), the target pane wears a pill naming the
/// agent — "Claude Code #7 · running the tests" — so it is plain who is typing
/// into a terminal that nobody at the keyboard touched. Clicking the pill goes
/// to the pane that acted.
///
/// The caller is known without the agent saying so: every pane's CLI runs with
/// `SEAHELM_PANE_ID`, which names the pane and through it the agent in it.
/// Presence never changes what a request does or which pane it reaches.
struct PresenceEntry: Equatable {
    /// The pane that acted — where a click on the pill goes.
    let originStationId: String
    /// "Claude Code #7".
    let actor: String
    /// What the agent said it was doing, if it did (`seahelm --note …`).
    let note: String?

    /// The pill's text.
    var label: String {
        guard let note, !note.isEmpty else { return actor }
        return "\(actor) · \(note)"
    }
}

/// The presence state, without timers or views, so its rules are testable.
struct PresenceLedger {
    /// How long a pill stays after the last call. Long enough to be seen across
    /// the gaps of a tool loop, short enough not to outstay the work.
    static let linger: TimeInterval = 6
    static let maxNoteLength = 80

    private var marks: [String: [String: (entry: PresenceEntry, until: Date)]] = [:]

    /// Record that `entry.originStationId` acted on `target`. A pane acting on
    /// itself is not news. Returns whether there is anything to show.
    @discardableResult
    mutating func note(target: String, entry: PresenceEntry, now: Date = Date()) -> Bool {
        guard target != entry.originStationId else { return false }
        marks[target, default: [:]][entry.originStationId] = (entry, now.addingTimeInterval(Self.linger))
        return true
    }

    /// Drop expired marks; returns the targets whose pills changed.
    mutating func prune(now: Date = Date()) -> Set<String> {
        var changed = Set<String>()
        for (target, byOrigin) in marks {
            let live = byOrigin.filter { $0.value.until > now }
            if live.count != byOrigin.count { changed.insert(target) }
            marks[target] = live.isEmpty ? nil : live
        }
        return changed
    }

    /// The pills on `target`, in a stable order so they do not reshuffle as
    /// calls arrive.
    func entries(for target: String) -> [PresenceEntry] {
        (marks[target] ?? [:]).values
            .sorted { $0.entry.actor < $1.entry.actor }
            .map(\.entry)
    }

    /// When the next mark runs out, if any.
    var nextExpiry: Date? { marks.values.flatMap { $0.values.map(\.until) }.min() }

    /// One line, trimmed to fit a pill.
    static func cleanNote(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let line = raw.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return nil }
        return line.count > maxNoteLength ? String(line.prefix(maxNoteLength - 1)) + "…" : line
    }
}

/// Main-thread owner of the ledger: pushes pills to the panes' views and
/// clears them when they lapse.
final class PanePresence {
    static let shared = PanePresence()

    private var ledger = PresenceLedger()
    private var expiryTimer: Timer?
    /// Bring the pane that acted to the front. Set by the coordinator that knows
    /// how to select a worktree and focus a pane.
    var onNavigate: ((String) -> Void)?

    func note(target: String, entry: PresenceEntry) {
        guard ledger.note(target: target, entry: entry) else { return }
        apply(target)
        scheduleExpiry()
    }

    func navigate(toOrigin stationId: String) {
        onNavigate?(stationId)
    }

    /// Re-draw a pane's pills, e.g. after its surface was recreated.
    func refresh(_ target: String) { apply(target) }

    private func apply(_ target: String) {
        StationRegistry.shared.station(forId: target)?.view?.setPresence(ledger.entries(for: target))
    }

    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        guard let next = ledger.nextExpiry else { return }
        let timer = Timer(fire: next.addingTimeInterval(0.05), interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            for target in self.ledger.prune() { self.apply(target) }
            self.scheduleExpiry()
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }
}

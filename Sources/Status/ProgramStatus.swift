import Foundation

/// OSC 7501 (Program Status Protocol): a program telling the terminal what it is
/// doing. Spec: https://www.superlogical.com/rex/docs/build/program-status (rev
/// 0.4); design and probe results: docs/osc7501.md.
///
/// libghostty (our patched GhosttyKit) parses and validates each report and hands
/// it over as `GHOSTTY_ACTION_PROGRAM_STATUS`; it keeps no records. Keeping them —
/// one per id, with the spec's lifetime rules — is this file's job, and it is pure
/// so the rules can be tested without a terminal.
struct ProgramStatusReport: Equatable {
    /// Mirrors `ghostty_action_program_status_state_e`.
    enum State: Int {
        case idle = 0
        case working = 1
        case done = 2
        case blocked = 3
        case error = 4
        /// Not a state: removes the addressed record and its subtree, or every
        /// record when `id` is empty.
        case clear = 5
    }

    /// Mirrors `ghostty_action_program_status_kind_e`. What a blocked program needs.
    enum Kind: Int {
        case permission = 0
        case question = 1
        case auth = 2
    }

    let state: State
    var kind: Kind?
    /// 0…100; nil when absent or indeterminate.
    var progress: Int?
    /// `/`-separated record id; empty addresses the root record (the program itself).
    var id: String = ""
    var app: String = ""
    var title: String = ""
    var msg: String = ""

    init(state: State, kind: Kind? = nil, progress: Int? = nil,
         id: String = "", app: String = "", title: String = "", msg: String = "") {
        self.state = state
        self.kind = kind
        self.progress = progress
        self.id = id
        self.app = app
        self.title = ProgramStatusReport.displaySafe(title)
        self.msg = ProgramStatusReport.displaySafe(msg)
    }

    /// The spec makes report text untrusted: libghostty already refused control
    /// characters, and a terminal showing the text outside the grid should disarm
    /// bidi overrides and invisible formatting so a program cannot make one line
    /// read as another.
    static func displaySafe(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        let banned: Set<UInt32> = [
            0x061C, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x2028, 0x2029,
            0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2060, 0x2066, 0x2067,
            0x2068, 0x2069, 0xFEFF,
        ]
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars where !banned.contains(scalar.value) {
            out.append(scalar)
        }
        return String(out)
    }
}

/// One record as the terminal keeps it.
struct ProgramStatusRecord: Equatable {
    let report: ProgramStatusReport
    /// `app` resolved through the nearest ancestor that has one.
    let app: String
    /// Monotonic stamp of the last update, for least-recently-updated eviction.
    let stamp: UInt64

    var state: ProgramStatusReport.State { report.state }

    /// What this record says about the agent, in Seahelm's vocabulary. `done`
    /// is at rest like `idle` — the "you have not looked yet" half of it is the
    /// record surviving, not a status.
    var agentStatus: AgentStatus {
        switch report.state {
        case .working: return .running
        case .blocked: return .waiting
        case .idle, .done: return .idle
        case .error: return .error
        case .clear: return .unknown
        }
    }

    /// The line to show beside the status, if the program gave one.
    var message: String {
        if !report.msg.isEmpty { return report.msg }
        if report.state == .blocked, let kind = report.kind {
            switch kind {
            case .permission: return "Needs permission"
            case .question: return "Needs an answer"
            case .auth: return "Needs a login"
            }
        }
        return ""
    }
}

/// The records one terminal holds.
struct ProgramStatusStore: Equatable {
    /// Spec: at most 256, at least 64. A program hitting this is misbehaving; the
    /// least recently updated record goes.
    static let maxRecords = 256

    private(set) var records: [String: ProgramStatusRecord] = [:]
    private var clock: UInt64 = 0
    /// The process that wrote the records has handed the terminal back to the
    /// shell. `done` / `error` outlive it by design, but they describe a program
    /// that is gone, so they stop driving the pane's status.
    private(set) var processExited = false

    var root: ProgramStatusRecord? { records[""] }

    /// The status the pane should take from 7501, or nil when 7501 has nothing
    /// live to say (no root record, or only the leftovers of an exited program).
    var liveRoot: ProgramStatusRecord? {
        guard let root, !processExited else { return nil }
        return root
    }

    /// Apply one report. Returns whether anything changed.
    @discardableResult
    mutating func apply(_ report: ProgramStatusReport) -> Bool {
        let before = self
        if report.state == .clear {
            if report.id.isEmpty {
                records.removeAll()
            } else {
                removeSubtree(of: report.id)
            }
            return self != before
        }

        // A report means the program is running in this terminal now.
        processExited = false
        clock &+= 1
        let app = report.app.isEmpty ? inheritedApp(for: report.id) : report.app
        records[report.id] = ProgramStatusRecord(report: report, app: app, stamp: clock)
        if records.count > Self.maxRecords,
           let oldest = records.min(by: { $0.value.stamp < $1.value.stamp })?.key {
            records[oldest] = nil
        }
        return self != before
    }

    /// The shell got the terminal back (a command finished; OSC 133). Per the
    /// spec, `working` and `blocked` die with the process and `idle` may; `done`
    /// and `error` stay until the user has seen them.
    @discardableResult
    mutating func promptReturned() -> Bool {
        let before = self
        records = records.filter { $0.value.state == .done || $0.value.state == .error }
        processExited = true
        return self != before
    }

    private mutating func removeSubtree(of id: String) {
        let prefix = id + "/"
        records = records.filter { $0.key != id && !$0.key.hasPrefix(prefix) }
    }

    private func inheritedApp(for id: String) -> String {
        guard !id.isEmpty else { return "" }
        // Nearest first, ending at the root record ("").
        var parts = id.split(separator: "/").map(String.init)
        repeat {
            parts.removeLast()
            if let app = records[parts.joined(separator: "/")]?.app, !app.isEmpty { return app }
        } while !parts.isEmpty
        return ""
    }
}

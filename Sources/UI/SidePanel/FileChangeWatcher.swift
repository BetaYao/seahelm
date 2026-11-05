import Foundation

/// Watches one file and reports, on the main queue, that it may have changed on
/// disk — an agent editing the file open in the preview column, say.
///
/// A vnode source on the file itself, not FSEvents on its directory: the
/// editor cares about exactly one file, and a busy worktree's directory churn
/// is not its business. Editors and agents mostly save by writing a temporary
/// file and renaming it over the original, which leaves the source watching
/// an inode that is gone; on a rename or delete the watcher reopens the path
/// (retrying while it does not exist yet) and reports once it is back.
/// Bursts are coalesced (`debounce`): one save is often several writes.
final class FileChangeWatcher {
    static let debounce: TimeInterval = 0.15
    /// How long to keep retrying a path that vanished (deleted, or mid-rename).
    static let reopenWindow: TimeInterval = 5
    private static let reopenStep: TimeInterval = 0.1

    private let path: String
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "seahelm.editor.file-watcher")
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    /// Queue-side: no more arming or scheduling.
    private var stopped = false
    /// Main-side: no more reports, even one already on its way.
    private var stoppedOnMain = false

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        queue.async { [weak self] in self?.arm(waited: 0, reportWhenArmed: false) }
    }

    deinit {
        source?.cancel()
    }

    /// Main thread.
    func stop() {
        stoppedOnMain = true
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.pending?.cancel()
            self.source?.cancel()
            self.source = nil
        }
    }

    /// Open the path and start watching it. Queue only.
    private func arm(waited: TimeInterval, reportWhenArmed: Bool) {
        guard !stopped else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            guard waited < Self.reopenWindow else { return }
            queue.asyncAfter(deadline: .now() + Self.reopenStep) { [weak self] in
                self?.arm(waited: waited + Self.reopenStep, reportWhenArmed: reportWhenArmed)
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) {
                // The inode we hold is no longer the file at `path`.
                source.cancel()
                self.source = nil
                self.arm(waited: 0, reportWhenArmed: true)
            } else {
                self.schedule()
            }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
        if reportWhenArmed { schedule() }
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stoppedOnMain else { return }
                self.onChange()
            }
        }
        pending = item
        queue.asyncAfter(deadline: .now() + Self.debounce, execute: item)
    }
}

/// What an open editor does when its file changes on disk. Pure.
enum ExternalChange: Equatable {
    /// Nothing to do: unreadable, or what is on disk is what the editor last
    /// saved or loaded (its own save coming back, a touch).
    case ignore
    /// The buffer holds no edits of the user's: show the disk's text.
    case reload
    /// The disk now holds exactly what the buffer has: just mark it saved.
    case adopt
    /// The user has edits and the file changed under them: ask.
    case conflict

    static func decide(disk: String?, buffer: String, saved: String) -> ExternalChange {
        guard let disk, disk != saved else { return .ignore }
        if disk == buffer { return .adopt }
        return buffer == saved ? .reload : .conflict
    }
}

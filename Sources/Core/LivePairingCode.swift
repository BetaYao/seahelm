import Foundation

protocol PairingCodeVerifying: AnyObject {
    func verify(_ raw: String) -> Bool
}

/// Thread-safe holder for the live pairing code. Settings refresh and Gateway
/// auth sessions share one instance so a refresh is visible to the next `auth`.
final class LivePairingCode: PairingCodeVerifying {
    private let lock = NSLock()
    private var store: PairingCodeStore
    /// Fired (on the caller's thread) after `ensureCode`/`refresh` mutate the store.
    var onChange: ((PairingCodeStore) -> Void)?

    init(store: PairingCodeStore) {
        self.store = store
    }

    func current() -> String {
        lock.lock()
        defer { lock.unlock() }
        let before = store.code
        let code = store.ensureCode()
        if store.code != before { onChange?(store) }
        return code
    }

    @discardableResult
    func refresh() -> String {
        lock.lock()
        defer { lock.unlock() }
        let code = store.refresh()
        onChange?(store)
        return code
    }

    func verify(_ raw: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return store.verify(raw)
    }

    /// Snapshot for persistence.
    func snapshot() -> PairingCodeStore {
        lock.lock()
        defer { lock.unlock() }
        return store
    }
}

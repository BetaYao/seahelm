import Foundation

/// Global registry mapping station IDs to live Station instances.
///
/// Accessed from several threads: the main thread registers/unregisters as panes
/// are created, restored and closed, while hook events (`ShipLog.handleWebhookEvent`,
/// on the event-sink queue) and control-socket requests (one thread per connection)
/// look stations up. A Swift Dictionary is not thread-safe, so every access is
/// serialized here — an unsynchronized read racing a register can miss a live
/// station, and a hook that fails to resolve its pane is silently attributed to a
/// sibling pane instead.
class StationRegistry {
    static let shared = StationRegistry()
    private var stations: [String: Station] = [:]
    private let lock = NSLock()

    func register(_ station: Station) {
        lock.lock(); defer { lock.unlock() }
        stations[station.id] = station
    }

    func unregister(_ stationId: String) {
        lock.lock(); defer { lock.unlock() }
        stations.removeValue(forKey: stationId)
    }

    func station(forId id: String) -> Station? {
        lock.lock(); defer { lock.unlock() }
        return stations[id]
    }

    /// Find the station owning a given Ghostty surface (for routing OSC / action
    /// callbacks back to a pane). Linear scan — the station count is small.
    func station(forSurface surface: ghostty_surface_t) -> Station? {
        lock.lock(); defer { lock.unlock() }
        return stations.values.first { $0.surface == surface }
    }

    /// Find a station by its persistent zmx session name. Unlike the per-instance
    /// station id, the session name is stable across app restarts, so it is what
    /// agents receive as SEAHELM_PANE_ID and use to reference their own pane.
    func station(forSessionName name: String) -> Station? {
        lock.lock(); defer { lock.unlock() }
        return stations.values.first { $0.sessionName == name }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        stations.removeAll()
    }
}

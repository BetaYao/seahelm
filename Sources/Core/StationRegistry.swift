import Foundation

/// Global registry mapping station IDs to live Station instances.
class StationRegistry {
    static let shared = StationRegistry()
    private var stations: [String: Station] = [:]

    func register(_ station: Station) {
        stations[station.id] = station
    }

    func unregister(_ stationId: String) {
        stations.removeValue(forKey: stationId)
    }

    func station(forId id: String) -> Station? {
        stations[id]
    }

    /// Find the station owning a given Ghostty surface (for routing OSC / action
    /// callbacks back to a pane). Linear scan — the station count is small.
    func station(forSurface surface: ghostty_surface_t) -> Station? {
        stations.values.first { $0.surface == surface }
    }

    /// Find a station by its persistent zmx session name. Unlike the per-instance
    /// station id, the session name is stable across app restarts, so it is what
    /// agents receive as SEAHELM_PANE_ID and use to reference their own pane.
    func station(forSessionName name: String) -> Station? {
        stations.values.first { $0.sessionName == name }
    }

    func removeAll() {
        stations.removeAll()
    }
}

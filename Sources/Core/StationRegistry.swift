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

    func removeAll() {
        stations.removeAll()
    }
}

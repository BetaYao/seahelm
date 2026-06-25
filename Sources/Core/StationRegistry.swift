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

    func removeAll() {
        stations.removeAll()
    }
}

import Foundation

/// Global registry mapping surface IDs to live TerminalSurface instances.
class SurfaceRegistry {
    static let shared = SurfaceRegistry()
    private var surfaces: [String: TerminalSurface] = [:]

    func register(_ surface: TerminalSurface) {
        surfaces[surface.id] = surface
    }

    func unregister(_ surfaceId: String) {
        surfaces.removeValue(forKey: surfaceId)
    }

    func surface(forId id: String) -> TerminalSurface? {
        surfaces[id]
    }

    func removeAll() {
        surfaces.removeAll()
    }
}

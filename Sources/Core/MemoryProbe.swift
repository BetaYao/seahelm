import Foundation

/// Reads this process's own memory accounting, so a measurement can be taken
/// over the control socket instead of shelling out to `footprint`/`vmmap`.
enum MemoryProbe {
    /// Physical footprint in bytes — the same figure `footprint -p` reports and
    /// the number macOS actually charges the app against memory pressure.
    /// Includes IOSurface/IOAccelerator, which is where most of a pane's cost
    /// lives. Returns nil if the kernel call fails.
    static func stats() -> [String: Any]? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let stations = StationRegistry.shared.allStations()
        let awake = stations.filter { $0.hasLiveSurface }.count
        let asleep = stations.filter { $0.isAsleep }.count
        let footprint = UInt64(info.phys_footprint)
        return [
            "phys_footprint": footprint,
            "phys_footprint_mb": Double(footprint) / 1_048_576,
            "resident": info.resident_size,
            "resident_peak": info.resident_size_peak,
            "compressed": info.compressed,
            "panes_total": stations.count,
            "panes_awake": awake,
            "panes_asleep": asleep,
            // Only meaningful once some panes are asleep, but it is the figure
            // the whole hibernation question turns on.
            "mb_per_awake_pane": awake > 0 ? Double(footprint) / 1_048_576 / Double(awake) : 0,
        ]
    }
}

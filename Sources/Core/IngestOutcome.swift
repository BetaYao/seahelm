import Foundation

/// The single output of ShipLog.ingest — one per recorded event.
/// Subscribers (UI, aggregator, FirstMate, external broadcast) react to this; they do not
/// read ShipLog state directly for the change that just happened.
struct IngestOutcome {
    let info: SailorInfo
    let statusChanged: Bool
    let oldStatus: SailorStatus
    let newStatus: SailorStatus
    let holdSeconds: Double
    let isCompletionSignal: Bool
    let event: NormalizedEvent
    /// Monotonic global sequence number assigned at ingest time. Strictly
    /// increasing across all events; lets future socket subscribers replay via
    /// `events_after(seq)` and detect dropped events. (mirrors herdr EventHub.sequence)
    var seq: UInt64 = 0
}

import Foundation

/// Signalman: translates raw data from one source into a unified NormalizedEvent (translation only, no adjudication).
protocol SignalDecoder {
    func decode() -> NormalizedEvent?   // returns nil = nothing to report this time
}

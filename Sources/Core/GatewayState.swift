import Foundation

enum GatewayState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    static func == (lhs: GatewayState, rhs: GatewayState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.connected, .connected):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

struct GatewayStateMachine {
    private(set) var state: GatewayState = .disconnected

    var isConnected: Bool { state == .connected }

    /// Transition to a new state. Returns true if the state changed.
    /// Valid transitions:
    ///   disconnected → connecting
    ///   connecting   → connected | error | disconnected
    ///   connected    → disconnected | error
    ///   error        → connecting | disconnected
    @discardableResult
    mutating func transition(to newState: GatewayState) -> Bool {
        guard newState != state else { return false }

        let valid: Bool
        switch (state, newState) {
        case (.disconnected, .connecting):
            valid = true
        case (.connecting, .connected),
             (.connecting, .disconnected),
             (.connecting, .error):
            valid = true
        case (.connected, .disconnected),
             (.connected, .error):
            valid = true
        case (.error, .connecting),
             (.error, .disconnected):
            valid = true
        default:
            valid = false
        }

        guard valid else { return false }
        state = newState
        return true
    }
}

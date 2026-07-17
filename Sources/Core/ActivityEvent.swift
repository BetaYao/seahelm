import Foundation

struct ActivityEvent: Equatable {
    let tool: String
    let detail: String
    let isError: Bool
    let timestamp: Date
}

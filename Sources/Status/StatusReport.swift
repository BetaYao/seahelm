import Foundation

/// 信号员解码后的规范化状态报告,所有情报通道的统一产出。
struct StatusReport {
    let status: AgentStatus
    let lastMessage: String
    let activityEvents: [ActivityEvent]
}

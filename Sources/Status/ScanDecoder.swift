import Foundation

/// 主动通道的信号员:扫屏文本 + 进程状态 → StatusReport。
/// 取数(瞭望员)发生在 StatusPublisher;本类型只负责解码。
struct ScanDecoder: SignalDecoder {
    let detector: StatusDetector
    let processStatus: ProcessStatus
    let shellInfo: ShellPhaseInfo?
    let content: String
    let agentDef: SailorDef?

    func decode() -> StatusReport? {
        let status = detector.detect(
            processStatus: processStatus,
            shellInfo: shellInfo,
            content: content,
            agentDef: agentDef
        )
        let events = detector.extractActivityEvents(from: content)
        // lastMessage 由调用方(StatusPublisher)用既有逻辑补,先留空串占位
        return StatusReport(status: status, lastMessage: "", activityEvents: events)
    }
}

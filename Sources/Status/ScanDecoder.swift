import Foundation

/// 主动通道的信号员:扫屏文本 + 进程状态 → NormalizedEvent(.screenObserved)。
/// 取数(瞭望员)发生在 StatusPublisher;本类型只负责解码。
struct ScanDecoder: SignalDecoder {
    let terminalID: String
    let detector: StatusDetector
    let processStatus: ProcessStatus
    let shellInfo: ShellPhaseInfo?
    let content: String
    let agentDef: SailorDef?
    var manifest: CompiledManifest? = nil
    let commandLine: String?
    let agentType: SailorType
    let roundDuration: TimeInterval
    let tasks: [TaskItem]

    func decode() -> NormalizedEvent? {
        let status = detector.detect(
            processStatus: processStatus,
            shellInfo: shellInfo,
            content: content,
            agentDef: agentDef,
            manifest: manifest
        )
        let events = detector.extractActivityEvents(from: content)
        let kind = NormalizedEventKind.screenObserved(
            status: status, message: "", activity: events,
            commandLine: commandLine, agentType: agentType,
            roundDuration: roundDuration, tasks: tasks)
        return NormalizedEvent(terminalID: terminalID, source: .scan, kind: kind)
    }
}

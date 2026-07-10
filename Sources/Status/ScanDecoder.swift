import Foundation

/// Signalman for the active channel: screen-scan text + process state → NormalizedEvent (.screenObserved).
/// Data capture (the lookout) happens in StatusPublisher; this type only decodes.
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

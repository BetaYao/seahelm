import Foundation

/// Signalman for the active channel: screen-scan text + process state → NormalizedEvent (.screenObserved).
/// Data capture (the lookout) happens in StatusPublisher; this type only decodes.
struct ScanDecoder: SignalDecoder {
    let terminalID: String
    let detector: StatusDetector
    let processStatus: ProcessStatus
    let shellInfo: ShellPhaseInfo?
    let content: String
    let agentDef: AgentDef?
    var manifest: CompiledManifest? = nil
    let commandLine: String?
    let agentType: AgentType
    let roundDuration: TimeInterval
    let tasks: [TaskItem]

    func decode() -> NormalizedEvent? {
        let detection = detector.detectDetailed(
            processStatus: processStatus,
            shellInfo: shellInfo,
            content: content,
            manifest: manifest
        )
        // `detect` is still the answer for the legacy AgentDef path, which
        // `detectDetailed` does not cover; the rich call only adds the flags.
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
            roundDuration: roundDuration, tasks: tasks,
            backgroundBusy: detection.backgroundBusy)
        return NormalizedEvent(terminalID: terminalID, source: .scan, kind: kind)
    }
}

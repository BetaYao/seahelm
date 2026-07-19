import Foundation

/// PATH detection for AI agents shown in the first-launch onboarding wizard.
enum OnboardingAgentDetector {
    struct AgentInfo: Equatable {
        let type: SailorType
        let command: String
        let detected: Bool
    }

    /// All AI agents Seahelm can launch, with PATH detection via `commandExists`.
    static func scan(
        commandExists: (String) -> Bool = ProcessRunner.commandExists
    ) -> [AgentInfo] {
        SailorType.allCases
            .filter(\.isAIAgent)
            .compactMap { type in
                guard let command = type.launchCommand else { return nil }
                return AgentInfo(
                    type: type,
                    command: command,
                    detected: commandExists(command)
                )
            }
    }

    /// Prefer Claude when detected; otherwise the first detected agent; else Claude.
    static func preferredDefault(from agents: [AgentInfo]) -> SailorType {
        if let claude = agents.first(where: { $0.type == .claudeCode && $0.detected }) {
            return claude.type
        }
        if let first = agents.first(where: \.detected) {
            return first.type
        }
        return .claudeCode
    }
}

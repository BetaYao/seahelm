import Foundation

/// PATH detection for AI agents shown in the first-launch onboarding wizard.
enum OnboardingAgentDetector {
    struct AgentInfo: Equatable {
        let type: AgentType
        let command: String
        let detected: Bool
    }

    /// All AI agents Seahelm can launch, with PATH detection via `commandExists`.
    /// The default resolves every command in one pass through the user's own
    /// login shell (`ProcessRunner.commandPaths`), the shell panes launch in.
    static func scan(
        commandExists: ((String) -> Bool)? = nil
    ) -> [AgentInfo] {
        let candidates = AgentType.allCases
            .filter(\.isAIAgent)
            .compactMap { type in type.launchCommand.map { (type, $0) } }
        let exists = commandExists ?? {
            let found = ProcessRunner.commandPaths(candidates.map(\.1))
            return { found[$0] != nil }
        }()
        return candidates.map { type, command in
            AgentInfo(type: type, command: command, detected: exists(command))
        }
    }

    /// Prefer Claude when detected; otherwise the first detected agent; else Claude.
    static func preferredDefault(from agents: [AgentInfo]) -> AgentType {
        if let claude = agents.first(where: { $0.type == .claudeCode && $0.detected }) {
            return claude.type
        }
        if let first = agents.first(where: \.detected) {
            return first.type
        }
        return .claudeCode
    }
}

import Foundation

/// Installs Seahelm hook bridge + per-agent integrations for the onboarding wizard
/// and subsequent launches filtered by `enabledHookAgents`.
enum OnboardingHookInstaller {
    /// Shared bridge pieces needed whenever any agent hooks are enabled.
    static func installSharedBridge() {
        SeahelmHookInstaller.ensureInstalled()
        SeahelmSuggestInstaller.ensureInstalled()
        SeahelmCliInstaller.ensureInstalled()
    }

    /// Install hooks for the given agent manifest ids (`claude`, `codex`, …).
    static func install(agents: [String]) {
        guard !agents.isEmpty else { return }
        installSharedBridge()
        let set = Set(agents.map { $0.lowercased() })
        if set.contains("claude") {
            ClaudeHooksSetup.ensureHooksConfigured()
            ClaudeStatuslineBridgeInstaller.ensureInstalled()
            SeahelmSkillInstaller.ensureInstalled()
        }
        if set.contains("codex") {
            CodexHooksSetup.ensureHooksConfigured()
        }
        if set.contains("cursor") {
            CursorHooksSetup.ensureHooksConfigured()
        }
        if set.contains("opencode") {
            OpenCodePluginInstaller.ensureInstalled()
        }
        if set.contains("pi") {
            PiExtensionInstaller.ensureInstalled()
        }
    }

    /// Launch-time install: use `enabledHookAgents` when non-empty, otherwise
    /// the historical “install everything” path for legacy configs.
    static func installForLaunch(config: Config) {
        guard config.webhook.enabled else { return }
        if config.enabledHookAgents.isEmpty {
            installSharedBridge()
            ClaudeHooksSetup.ensureHooksConfigured()
            ClaudeStatuslineBridgeInstaller.ensureInstalled()
            CodexHooksSetup.ensureHooksConfigured()
            CursorHooksSetup.ensureHooksConfigured()
            OpenCodePluginInstaller.ensureInstalled()
            PiExtensionInstaller.ensureInstalled()
            SeahelmSkillInstaller.ensureInstalled()
        } else {
            install(agents: config.enabledHookAgents)
        }
    }
}

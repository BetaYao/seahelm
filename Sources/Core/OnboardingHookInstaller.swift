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

    /// One installed component and whether it landed. The onboarding wizard shows
    /// these on its final step — hook installation used to be entirely silent, so
    /// a failure (unwritable `~/.claude/settings.json`, say) looked identical to
    /// success right up until status detection quietly didn't work.
    struct InstallStep {
        let name: String
        let detail: String
        let ok: Bool
    }

    /// Install hooks for the given agent manifest ids (`claude`, `codex`, …),
    /// reporting what happened. `install(agents:)` is the fire-and-forget form.
    @discardableResult
    static func install(agents: [String]) -> [InstallStep] {
        guard !agents.isEmpty else { return [] }
        var steps: [InstallStep] = [
            InstallStep(name: "Hook bridge", detail: "~/.local/bin/seahelm-hook",
                        ok: SeahelmHookInstaller.ensureInstalled()),
            InstallStep(name: "Suggestion bridge", detail: "~/.local/bin/seahelm-suggest",
                        ok: SeahelmSuggestInstaller.ensureInstalled()),
            InstallStep(name: "seahelm CLI", detail: "~/.local/bin/seahelm",
                        ok: SeahelmCliInstaller.ensureInstalled()),
        ]
        let set = Set(agents.map { $0.lowercased() })
        if set.contains("claude") {
            steps.append(InstallStep(name: "Claude Code hooks", detail: "~/.claude/settings.json",
                                     ok: ClaudeHooksSetup.ensureHooksConfigured()))
            steps.append(InstallStep(name: "Claude statusline", detail: "~/.claude/settings.json",
                                     ok: ClaudeStatuslineBridgeInstaller.ensureInstalled()))
            steps.append(InstallStep(name: "seahelm skill", detail: "~/.claude/skills/seahelm",
                                     ok: SeahelmSkillInstaller.ensureInstalled()))
        }
        if set.contains("codex") {
            steps.append(InstallStep(name: "Codex hooks", detail: "~/.codex/hooks.json",
                                     ok: CodexHooksSetup.ensureHooksConfigured()))
        }
        if set.contains("cursor") {
            steps.append(InstallStep(name: "Cursor hooks", detail: "~/.cursor/hooks.json",
                                     ok: CursorHooksSetup.ensureHooksConfigured()))
        }
        if set.contains("opencode") {
            steps.append(InstallStep(name: "OpenCode plugin", detail: "~/.config/opencode/plugin",
                                     ok: OpenCodePluginInstaller.ensureInstalled()))
        }
        if set.contains("pi") {
            steps.append(InstallStep(name: "Pi extension", detail: "~/.pi/agent",
                                     ok: PiExtensionInstaller.ensureInstalled()))
        }
        return steps
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

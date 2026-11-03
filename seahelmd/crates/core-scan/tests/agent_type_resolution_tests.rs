//! Port of Tests/AgentTypeResolutionTests.swift (AgentTypeResolutionTests).
//! `HostGatewayPaneNotifyTests`, in the same Swift file, is about the web
//! gateway, not the scan, and is not ported here.

use seahelm_core_scan::pane::{resolve_agent_type, NoAgentSighting};
use seahelm_core_types::AgentType::{self, *};

fn resolve(probed: AgentType, no_agent: NoAgentSighting, screen: AgentType, existing: AgentType) -> AgentType {
    resolve_agent_type(probed, no_agent, screen, existing, |t| t == ClaudeCode || t == Codex)
}

#[test]
fn probed_agent_wins() {
    assert_eq!(resolve(Codex, NoAgentSighting::None, ClaudeCode, Unknown), Codex);
}

#[test]
fn a_miss_keeps_the_known_agent() {
    assert_eq!(resolve(Unknown, NoAgentSighting::None, Unknown, ClaudeCode), ClaudeCode);
}

#[test]
fn a_fresh_probe_with_no_agent_takes_the_agent_away() {
    assert_eq!(resolve(Unknown, NoAgentSighting::Fresh, Unknown, ClaudeCode), ShellCommand);
}

#[test]
fn scrollback_naming_the_agent_does_not_bring_it_back() {
    assert_eq!(resolve(Unknown, NoAgentSighting::Fresh, ClaudeCode, ClaudeCode), ShellCommand);
    assert_eq!(resolve(Unknown, NoAgentSighting::Cached, ClaudeCode, ShellCommand), ShellCommand);
}

/// A hook reported the agent starting after the last probe: the remembered
/// sighting must not undo it.
#[test]
fn a_cached_sighting_does_not_overrule_an_agent_since_reported() {
    assert_eq!(resolve(Unknown, NoAgentSighting::Cached, Unknown, ClaudeCode), ClaudeCode);
}

/// The probe cannot recognise this agent, so not finding it proves nothing.
#[test]
fn an_agent_the_probe_cannot_see_is_kept() {
    assert_eq!(resolve(Unknown, NoAgentSighting::Fresh, Unknown, Aider), Aider);
    assert_eq!(resolve(Unknown, NoAgentSighting::Fresh, Aider, Unknown), Aider);
}

#[test]
fn a_shell_job_is_left_alone() {
    assert_eq!(resolve(Unknown, NoAgentSighting::Fresh, Unknown, Npm), Npm);
}

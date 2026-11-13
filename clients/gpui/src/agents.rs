//! Empty-fleet agent list: every AI agent Seahelm can launch, lit when its
//! binary is on PATH and dimmed otherwise. Click opens the vendor install page
//! (same role as the macOS `EmptyFleetAgentsView`).

use std::collections::HashSet;
use std::process::Command;

use seahelm_core_types::AgentType;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentInfo {
    pub agent: AgentType,
    pub detected: bool,
}

impl AgentInfo {
    pub fn glyph(&self) -> &'static str {
        self.agent.tab_glyph().unwrap_or("◆")
    }

    pub fn install_url(&self) -> Option<&'static str> {
        self.agent.install_url()
    }
}

/// PATH scan of every AI agent, matching the macOS `AgentDetector` set.
pub fn scan() -> Vec<AgentInfo> {
    let bins: Vec<&'static str> = AgentType::ai_agents().iter().filter_map(|a| a.launch_bin()).collect();
    let found = commands_on_path(&bins);
    AgentType::ai_agents()
        .iter()
        .copied()
        .filter_map(|agent| {
            let bin = agent.launch_bin()?;
            Some(AgentInfo {
                agent,
                detected: found.contains(bin),
            })
        })
        .collect()
}

fn commands_on_path(bins: &[&str]) -> HashSet<String> {
    if bins.is_empty() {
        return HashSet::new();
    }
    #[cfg(windows)]
    {
        let mut found = HashSet::new();
        let Some(paths) = std::env::var_os("PATH") else {
            return found;
        };
        for bin in bins {
            let exe = format!("{bin}{}", std::env::consts::EXE_SUFFIX);
            if std::env::split_paths(&paths).any(|d| d.join(&exe).is_file()) {
                found.insert((*bin).to_string());
            }
        }
        found
    }
    #[cfg(not(windows))]
    {
        // Login shell so `~/.local/bin` from zshrc is visible, as the macOS app's
        // `ProcessRunner.commandPaths` does.
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
        let script = bins
            .iter()
            .map(|b| format!("command -v {b} >/dev/null 2>&1 && printf '%s\\n' {b}"))
            .collect::<Vec<_>>()
            .join("; ");
        let Ok(out) = Command::new(&shell).args(["-lic", &script]).output() else {
            return HashSet::new();
        };
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_ai_agent_has_install_url_and_bin() {
        for agent in AgentType::ai_agents() {
            assert!(agent.launch_bin().is_some(), "{agent:?}");
            let url = agent.install_url().expect("install_url");
            assert!(url.starts_with("https://"), "{agent:?}: {url}");
        }
    }
}

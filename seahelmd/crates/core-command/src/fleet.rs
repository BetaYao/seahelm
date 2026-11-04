//! The fleet frozen for one line (`FleetIndex.swift`): everything a command
//! can name. Built by the core from live state; pure.

use seahelm_core_types::AgentStatus;

#[derive(Clone, Debug, PartialEq)]
pub struct PaneRef {
    /// The stable handle: what `#7` means on every surface.
    pub handle: u32,
    /// The key the handle was minted for (the seahelmd session name).
    pub key: String,
    pub project: String,
    pub branch: String,
    pub worktree_path: String,
    /// Agent kind, e.g. "Claude Code".
    pub kind: String,
    pub title: String,
    pub status: AgentStatus,
    pub last_message: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct WorktreeRef {
    /// The repo's directory name.
    pub repo: String,
    pub branch: String,
    pub path: String,
    pub is_main: bool,
}

impl WorktreeRef {
    /// Its branch, or its directory on a detached HEAD.
    pub fn name(&self) -> String {
        worktree_name(&self.branch, &self.path)
    }
}

pub fn worktree_name(branch: &str, path: &str) -> String {
    let b = branch.trim();
    if !b.is_empty() {
        return b.to_string();
    }
    std::path::Path::new(path).file_name().and_then(|n| n.to_str()).filter(|n| !n.is_empty()).unwrap_or(path).to_string()
}

#[derive(Clone, Debug, PartialEq)]
pub struct RepoRef {
    pub name: String,
    pub path: String,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct FleetIndex {
    pub panes: Vec<PaneRef>,
    pub worktrees: Vec<WorktreeRef>,
    pub repos: Vec<RepoRef>,
}

/// Why a name named nothing usable.
#[derive(Clone, Debug, PartialEq)]
pub enum NameError {
    Unknown(String),
    Ambiguous(String, Vec<String>),
    RepoNotWorktree(String),
}

impl FleetIndex {
    pub fn pane(&self, handle: u32) -> Option<&PaneRef> {
        self.panes.iter().find(|p| p.handle == handle)
    }

    pub fn pane_by_key(&self, key: &str) -> Option<&PaneRef> {
        self.panes.iter().find(|p| p.key == key)
    }

    /// Lowest handle first: the oldest pane is what a worktree binding uses.
    pub fn panes_in(&self, path: &str) -> Vec<&PaneRef> {
        let mut v: Vec<&PaneRef> = self.panes.iter().filter(|p| p.worktree_path == path).collect();
        v.sort_by_key(|p| p.handle);
        v
    }

    /// `name`, or `repo/name` when several repos carry it; case-insensitive.
    /// A branch with a `/` in it matches whole before the slash is read as a
    /// repo separator.
    pub fn worktree(&self, name: &str) -> Result<&WorktreeRef, NameError> {
        let needle = name.to_lowercase();
        let exact: Vec<&WorktreeRef> = self.worktrees.iter().filter(|w| w.name().to_lowercase() == needle).collect();
        match exact.len() {
            1 => return Ok(exact[0]),
            n if n > 1 => return Err(NameError::Ambiguous(name.into(), exact.iter().map(|w| format!("{}/{}", w.repo, w.name())).collect())),
            _ => {}
        }
        if let Some((repo, branch)) = needle.split_once('/') {
            let known = self.worktrees.iter().any(|w| w.repo.to_lowercase() == repo) || self.repo(repo).is_some();
            if known {
                return self
                    .worktrees
                    .iter()
                    .find(|w| w.repo.to_lowercase() == repo && w.name().to_lowercase() == branch)
                    .ok_or_else(|| NameError::Unknown(name.into()));
            }
        }
        Err(if self.repo(name).is_some() { NameError::RepoNotWorktree(name.into()) } else { NameError::Unknown(name.into()) })
    }

    /// `@name`, or `@repo/name` when the bare one would be ambiguous: what a
    /// listing prints is what can be typed.
    pub fn label(&self, w: &WorktreeRef) -> String {
        let same = self.worktrees.iter().filter(|x| x.name().to_lowercase() == w.name().to_lowercase()).count();
        if same > 1 {
            format!("@{}/{}", w.repo, w.name())
        } else {
            format!("@{}", w.name())
        }
    }

    pub fn worktree_at(&self, path: &str) -> Option<&WorktreeRef> {
        self.worktrees.iter().find(|w| w.path == path)
    }

    pub fn repo(&self, name: &str) -> Option<&RepoRef> {
        let n = name.to_lowercase();
        self.repos.iter().find(|r| r.name.to_lowercase() == n)
    }
}

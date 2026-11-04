//! What is actually in a worktree, measured rather than described by First
//! Mate (`WorktreeFacts.swift`): uncommitted files and lines, commits no
//! remote has, busy panes. In every event and on every card that would
//! delete the worktree, so a summary that leaves something out cannot be
//! what the user approves on.

use std::path::Path;
use std::process::Command;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Facts {
    pub changed: u32,
    pub deleted: u32,
    pub untracked: u32,
    pub insertions: u32,
    pub deletions: u32,
    /// Commits on HEAD no remote-tracking ref has; None when git could not say.
    pub unpushed: Option<u32>,
    pub busy_panes: u32,
}

impl Facts {
    /// "41 files uncommitted (+16 −47942; 40 deleted, 1 untracked) · every commit is on a remote · panes idle".
    pub fn summary(&self) -> String {
        let mut parts = Vec::new();
        let n = self.changed + self.untracked;
        if n == 0 {
            parts.push("nothing uncommitted".to_string());
        } else {
            let mut kinds = Vec::new();
            if self.deleted > 0 {
                kinds.push(format!("{} deleted", self.deleted));
            }
            if self.untracked > 0 {
                kinds.push(format!("{} untracked", self.untracked));
            }
            let mut detail = format!("+{} \u{2212}{}", self.insertions, self.deletions);
            if !kinds.is_empty() {
                detail += &format!("; {}", kinds.join(", "));
            }
            parts.push(format!("{n} file{} uncommitted ({detail})", if n == 1 { "" } else { "s" }));
        }
        parts.push(match self.unpushed {
            None => "unpushed commits unknown".into(),
            Some(0) => "every commit is on a remote".into(),
            Some(u) => format!("{u} commit{} on no remote", if u == 1 { "" } else { "s" }),
        });
        parts.push(match self.busy_panes {
            0 => "panes idle".into(),
            b => format!("{b} pane{} busy", if b == 1 { "" } else { "s" }),
        });
        parts.join(" · ")
    }

    /// Measure with git. Blocking. `busy_panes` is the caller's to fill in.
    pub fn probe(worktree: &Path) -> Self {
        let mut f = Facts::default();
        if let Some(s) = git(worktree, &["status", "--porcelain=v1"]) {
            (f.changed, f.deleted, f.untracked) = parse_status(&s);
        }
        if let Some(s) = git(worktree, &["diff", "HEAD", "--shortstat"]) {
            (f.insertions, f.deletions) = parse_shortstat(&s);
        }
        f.unpushed = git(worktree, &["rev-list", "--count", "HEAD", "--not", "--remotes"]).and_then(|s| s.trim().parse().ok());
        f
    }
}

pub fn git(dir: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git").arg("-C").arg(dir).args(args).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

fn parse_status(porcelain: &str) -> (u32, u32, u32) {
    let (mut changed, mut deleted, mut untracked) = (0, 0, 0);
    for line in porcelain.lines().filter(|l| l.len() >= 2) {
        let code = &line[..2];
        if code == "??" {
            untracked += 1;
            continue;
        }
        changed += 1;
        if code.contains('D') {
            deleted += 1;
        }
    }
    (changed, deleted, untracked)
}

fn parse_shortstat(text: &str) -> (u32, u32) {
    let number_before = |word: &str| -> u32 {
        text.find(word)
            .and_then(|i| text[..i].trim().rsplit(' ').next().and_then(|n| n.parse().ok()))
            .unwrap_or(0)
    };
    (number_before("insertion"), number_before("deletion"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_git() {
        assert_eq!(parse_status(" M a\nD  b\n?? c\n"), (2, 1, 1));
        assert_eq!(parse_shortstat(" 3 files changed, 16 insertions(+), 47942 deletions(-)\n"), (16, 47942));
        assert_eq!(parse_shortstat(" 1 file changed, 1 deletion(-)\n"), (0, 1));
    }

    #[test]
    fn summary_reads_like_the_apps() {
        let f = Facts { changed: 40, deleted: 40, untracked: 1, insertions: 16, deletions: 47942, unpushed: Some(0), busy_panes: 0 };
        assert_eq!(f.summary(), "41 files uncommitted (+16 \u{2212}47942; 40 deleted, 1 untracked) · every commit is on a remote · panes idle");
        assert_eq!(Facts { unpushed: Some(2), busy_panes: 1, ..Facts::default() }.summary(), "nothing uncommitted · 2 commits on no remote · 1 pane busy");
    }
}

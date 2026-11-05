//! What the side panel shows of a worktree, read from git: its files, and
//! what in it still has to go in a PR (the macOS app's Changes tab,
//! `GitDiff.branchChangedFiles`). Blocking; run off the UI thread.
//!
//! Committed work is what merging HEAD into the base would change
//! (`git merge-tree --write-tree`): work already in the base merges to
//! nothing, squash-merged or not. The macOS app first looks for a merged
//! PR's head to measure from; the core's `pr.list` does not carry heads, so
//! this client goes straight to the merge.

use std::collections::BTreeSet;
use std::path::Path;
use std::process::Command;

/// Trunk names tried, in order, when picking what to compare against.
const BASES: &[&str] = &["origin/main", "origin/master", "main", "master"];
/// A preview stops here: the panel is for a look, not an editor.
const PREVIEW_BYTES: usize = 512 * 1024;
const PREVIEW_LINES: usize = 5000;

fn git_raw(path: &str, args: &[&str]) -> Option<(i32, Vec<u8>)> {
    let mut cmd = Command::new("git");
    cmd.arg("-C").arg(path).args(args);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    let out = cmd.output().ok()?;
    Some((out.status.code().unwrap_or(-1), out.stdout))
}

fn git(path: &str, args: &[&str]) -> Option<Vec<u8>> {
    git_raw(path, args).and_then(|(code, out)| (code == 0).then_some(out))
}

fn git_text(path: &str, args: &[&str]) -> Option<String> {
    git(path, args).map(|b| String::from_utf8_lossy(&b).into_owned())
}

/// Every file git would show: tracked, and untracked but not ignored.
/// Sorted, `/`-separated, relative to the worktree.
pub fn files(path: &str) -> Vec<String> {
    let out = git(path, &["ls-files", "-z", "--cached", "--others", "--exclude-standard"]).unwrap_or_default();
    let set: BTreeSet<String> = split_z(&out).into_iter().collect();
    set.into_iter().collect()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stage {
    /// Edited since HEAD (staged or not), or untracked.
    Uncommitted,
    /// Committed, and not in the base yet.
    Committed,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Change {
    pub path: String,
    /// Where a rename came from.
    pub old_path: Option<String>,
    /// `M`, `A`, `D`, `R`, or `?` for untracked.
    pub status: char,
    pub stage: Stage,
    /// Lines added and removed; None for a binary file.
    pub added: Option<u64>,
    pub removed: Option<u64>,
    /// Merging into the base conflicts here.
    pub conflicted: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Changes {
    /// The ref committed work is measured against (`origin/main`), if any.
    pub base: Option<String>,
    /// The tree merging HEAD into the base would give: what committed diffs
    /// are taken against.
    pub merge_tree: Option<String>,
    pub files: Vec<Change>,
}

impl Changes {
    pub fn uncommitted(&self) -> impl Iterator<Item = &Change> {
        self.files.iter().filter(|c| c.stage == Stage::Uncommitted)
    }

    pub fn committed(&self) -> impl Iterator<Item = &Change> {
        self.files.iter().filter(|c| c.stage == Stage::Committed)
    }
}

pub fn base_ref(path: &str) -> Option<String> {
    BASES.iter().find(|r| git(path, &["rev-parse", "--verify", "--quiet", r]).is_some()).map(|r| r.to_string())
}

/// Uncommitted work, then committed work the base lacks; a file with
/// uncommitted edits is listed once, as uncommitted (it has to be committed
/// before it can go anywhere).
pub fn changes(path: &str) -> Changes {
    let has_head = git(path, &["rev-parse", "--verify", "--quiet", "HEAD"]).is_some();
    let mut files = if has_head { diff_changes(path, &["HEAD"], Stage::Uncommitted) } else { Vec::new() };
    let known: BTreeSet<String> = files.iter().map(|c| c.path.clone()).collect();
    let untracked = git(path, &["ls-files", "-z", "--others", "--exclude-standard"]).unwrap_or_default();
    for p in split_z(&untracked) {
        if !known.contains(&p) {
            let added = std::fs::read(Path::new(path).join(&p)).ok().and_then(|b| (!is_binary(&b)).then(|| line_count(&b)));
            files.push(Change { path: p, old_path: None, status: '?', stage: Stage::Uncommitted, added, removed: added.map(|_| 0), conflicted: false });
        }
    }
    let base = if has_head { base_ref(path) } else { None };
    let mut merge_tree = None;
    if let Some(base) = &base {
        if let Some((tree, conflicted)) = git_raw(path, &["merge-tree", "--write-tree", "-z", "--name-only", "--no-messages", base, "HEAD"])
            .and_then(|(code, out)| parse_merge_tree(&out, code))
        {
            let mine: BTreeSet<String> = files.iter().flat_map(|c| [Some(c.path.clone()), c.old_path.clone()]).flatten().collect();
            for mut c in diff_changes(path, &[base.as_str(), tree.as_str()], Stage::Committed) {
                if mine.contains(&c.path) {
                    continue;
                }
                c.conflicted = conflicted.contains(&c.path);
                files.push(c);
            }
            merge_tree = Some(tree);
        }
    }
    Changes { base, merge_tree, files }
}

/// `git diff <revs>`, as changes: status from `--name-status`, line counts
/// from `--numstat`.
fn diff_changes(path: &str, revs: &[&str], stage: Stage) -> Vec<Change> {
    let run = |kind: &str| {
        let mut args = vec!["diff", kind, "-z", "-M"];
        args.extend_from_slice(revs);
        git(path, &args).unwrap_or_default()
    };
    let mut out = parse_name_status(&run("--name-status"), stage);
    let counts = parse_numstat(&run("--numstat"));
    for c in &mut out {
        if let Some((a, r)) = counts.iter().find(|(p, _)| *p == c.path).map(|(_, n)| *n) {
            c.added = a;
            c.removed = r;
        }
    }
    out
}

fn split_z(b: &[u8]) -> Vec<String> {
    b.split(|c| *c == 0).filter(|s| !s.is_empty()).map(|s| String::from_utf8_lossy(s).into_owned()).collect()
}

/// `--name-status -z`: `M\0path\0`, `R100\0old\0new\0`.
fn parse_name_status(b: &[u8], stage: Stage) -> Vec<Change> {
    let fields = split_z(b);
    let mut out = Vec::new();
    let mut i = 0;
    while i < fields.len() {
        let status = fields[i].chars().next().unwrap_or('M');
        let renamed = matches!(status, 'R' | 'C');
        let (old_path, path) = if renamed {
            (fields.get(i + 1).cloned(), fields.get(i + 2).cloned())
        } else {
            (None, fields.get(i + 1).cloned())
        };
        i += if renamed { 3 } else { 2 };
        let Some(path) = path else { break };
        out.push(Change { path, old_path, status: if status == 'C' { 'A' } else { status }, stage, added: None, removed: None, conflicted: false });
    }
    out
}

/// Lines added and removed; None for a binary file.
type LineCounts = (Option<u64>, Option<u64>);

/// `--numstat -z`: `a\tr\tpath\0`, or `a\tr\t\0old\0new\0` for a rename;
/// `-\t-` for a binary file. (path, (added, removed)).
fn parse_numstat(b: &[u8]) -> Vec<(String, LineCounts)> {
    let fields = split_z(b);
    let mut out = Vec::new();
    let mut i = 0;
    while i < fields.len() {
        let mut parts = fields[i].splitn(3, '\t');
        let a = parts.next().and_then(|n| n.parse().ok());
        let r = parts.next().and_then(|n| n.parse().ok());
        let rest = parts.next().unwrap_or("");
        if rest.is_empty() {
            // A rename: the new path is two fields on.
            if let Some(p) = fields.get(i + 2) {
                out.push((p.clone(), (a, r)));
            }
            i += 3;
        } else {
            out.push((rest.to_string(), (a, r)));
            i += 1;
        }
    }
    out
}

/// Exit 0 is a clean merge and 1 a conflicted one: the tree id, then each
/// conflicted path. Anything else (git older than 2.38) is None.
fn parse_merge_tree(b: &[u8], code: i32) -> Option<(String, BTreeSet<String>)> {
    if code != 0 && code != 1 {
        return None;
    }
    let mut fields = split_z(b).into_iter();
    let tree = fields.next()?.trim().to_string();
    if tree.is_empty() {
        return None;
    }
    let conflicted = if code == 1 { fields.collect() } else { BTreeSet::new() };
    Some((tree, conflicted))
}

fn is_binary(b: &[u8]) -> bool {
    b.iter().take(8000).any(|c| *c == 0)
}

fn line_count(b: &[u8]) -> u64 {
    let n = b.iter().filter(|c| **c == b'\n').count() as u64;
    if b.last().is_some_and(|c| *c != b'\n') { n + 1 } else { n }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LineKind {
    Context,
    Added,
    Removed,
    /// `@@ … @@` and file headers.
    Meta,
}

/// What the panel shows for a file or a change.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Preview {
    Text(Vec<String>),
    Diff(Vec<(LineKind, String)>),
    Note(String),
}

/// A file as it is on disk, for the Files tab.
pub fn preview_file(worktree: &str, rel: &str) -> Preview {
    let p = Path::new(worktree).join(rel);
    let Ok(meta) = std::fs::metadata(&p) else { return Preview::Note("Not on disk".into()) };
    if meta.is_dir() {
        return Preview::Note("A directory".into());
    }
    let mut bytes = match std::fs::read(&p) {
        Ok(b) => b,
        Err(e) => return Preview::Note(format!("Cannot read it: {e}")),
    };
    if is_binary(&bytes) {
        return Preview::Note(format!("Binary file, {}", human_size(meta.len())));
    }
    let cut = bytes.len() > PREVIEW_BYTES;
    bytes.truncate(PREVIEW_BYTES);
    let text = String::from_utf8_lossy(&bytes);
    let mut lines: Vec<String> = text.lines().take(PREVIEW_LINES).map(expand_tabs).collect();
    if cut || text.lines().nth(PREVIEW_LINES).is_some() {
        lines.push(format!("… (first {} lines shown)", lines.len()));
    }
    Preview::Text(lines)
}

/// A change's diff, for the Changes tab: uncommitted against HEAD (an
/// untracked file as all added), committed from the base to the merge.
pub fn preview_change(worktree: &str, c: &Change, changes: &Changes) -> Preview {
    let mut paths = vec![c.path.as_str()];
    if let Some(old) = &c.old_path {
        paths.push(old);
    }
    let out = match c.stage {
        Stage::Uncommitted if c.status == '?' => {
            return match preview_file(worktree, &c.path) {
                Preview::Text(lines) => Preview::Diff(lines.into_iter().map(|l| (LineKind::Added, format!("+{l}"))).collect()),
                other => other,
            };
        }
        Stage::Uncommitted => {
            let mut args = vec!["diff", "-M", "HEAD", "--"];
            args.extend(&paths);
            git_text(worktree, &args)
        }
        Stage::Committed => {
            let (Some(base), Some(tree)) = (changes.base.as_deref(), changes.merge_tree.as_deref()) else {
                return Preview::Note("No base to compare with".into());
            };
            let mut args = vec!["diff", "-M", base, tree, "--"];
            args.extend(&paths);
            git_text(worktree, &args)
        }
    };
    match out {
        Some(text) if text.trim().is_empty() => Preview::Note("No textual change".into()),
        Some(text) => Preview::Diff(parse_diff(&text)),
        None => Preview::Note("git could not show it".into()),
    }
}

/// Unified diff text as lines with a kind; the `diff --git` / index /
/// `---` / `+++` headers are left out, hunks kept.
fn parse_diff(text: &str) -> Vec<(LineKind, String)> {
    let mut out = Vec::new();
    let mut in_hunk = false;
    for line in text.lines().take(PREVIEW_LINES) {
        if line.starts_with("diff --git") {
            in_hunk = false;
            continue;
        }
        if line.starts_with("@@") {
            in_hunk = true;
            out.push((LineKind::Meta, line.to_string()));
            continue;
        }
        if !in_hunk {
            if line.starts_with("Binary files") {
                out.push((LineKind::Meta, line.to_string()));
            }
            continue;
        }
        let kind = match line.as_bytes().first() {
            Some(b'+') => LineKind::Added,
            Some(b'-') => LineKind::Removed,
            Some(b'\\') => LineKind::Meta,
            _ => LineKind::Context,
        };
        out.push((kind, expand_tabs(line)));
    }
    out
}

fn expand_tabs(line: &str) -> String {
    line.replace('\t', "    ")
}

fn human_size(n: u64) -> String {
    match n {
        n if n < 1024 => format!("{n} B"),
        n if n < 1024 * 1024 => format!("{:.0} KB", n as f64 / 1024.0),
        n => format!("{:.1} MB", n as f64 / 1024.0 / 1024.0),
    }
}

/// One row of the file tree as drawn.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TreeRow {
    pub depth: usize,
    pub name: String,
    /// The file's path, or the directory's (no trailing `/`).
    pub path: String,
    pub is_dir: bool,
    pub expanded: bool,
}

/// The rows the tree shows for `files` (sorted, `/`-separated) with the
/// directories in `expanded` open: directories before files at each level,
/// both by name.
pub fn tree_rows(files: &[String], expanded: &BTreeSet<String>) -> Vec<TreeRow> {
    #[derive(Default)]
    struct Node {
        dirs: std::collections::BTreeMap<String, Node>,
        files: Vec<String>,
    }
    let mut root = Node::default();
    for f in files {
        let mut node = &mut root;
        let mut parts: Vec<&str> = f.split('/').collect();
        let Some(name) = parts.pop() else { continue };
        for d in parts {
            node = node.dirs.entry(d.to_string()).or_default();
        }
        node.files.push(name.to_string());
    }
    fn walk(node: &Node, prefix: &str, depth: usize, expanded: &BTreeSet<String>, out: &mut Vec<TreeRow>) {
        for (name, child) in &node.dirs {
            let path = if prefix.is_empty() { name.clone() } else { format!("{prefix}/{name}") };
            let open = expanded.contains(&path);
            out.push(TreeRow { depth, name: name.clone(), path: path.clone(), is_dir: true, expanded: open });
            if open {
                walk(child, &path, depth + 1, expanded, out);
            }
        }
        let mut names = node.files.clone();
        names.sort();
        for name in names {
            let path = if prefix.is_empty() { name.clone() } else { format!("{prefix}/{name}") };
            out.push(TreeRow { depth, name, path, is_dir: false, expanded: false });
        }
    }
    let mut out = Vec::new();
    walk(&root, "", 0, expanded, &mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn z(parts: &[&str]) -> Vec<u8> {
        let mut v = Vec::new();
        for p in parts {
            v.extend_from_slice(p.as_bytes());
            v.push(0);
        }
        v
    }

    #[test]
    fn name_status_reads_renames_and_plain_changes() {
        let c = parse_name_status(&z(&["M", "a.rs", "R087", "old.rs", "new.rs", "D", "gone.rs"]), Stage::Committed);
        assert_eq!(c.len(), 3);
        assert_eq!((c[0].status, c[0].path.as_str()), ('M', "a.rs"));
        assert_eq!((c[1].status, c[1].path.as_str(), c[1].old_path.as_deref()), ('R', "new.rs", Some("old.rs")));
        assert_eq!((c[2].status, c[2].path.as_str()), ('D', "gone.rs"));
    }

    #[test]
    fn numstat_reads_counts_renames_and_binaries() {
        let n = parse_numstat(&z(&["3\t1\ta.rs", "5\t0\t", "old.rs", "new.rs", "-\t-\timg.png"]));
        assert_eq!(n[0], ("a.rs".into(), (Some(3), Some(1))));
        assert_eq!(n[1], ("new.rs".into(), (Some(5), Some(0))));
        assert_eq!(n[2], ("img.png".into(), (None, None)));
    }

    #[test]
    fn merge_tree_output() {
        assert_eq!(parse_merge_tree(&z(&["abc123"]), 0), Some(("abc123".into(), BTreeSet::new())));
        let (tree, conflicted) = parse_merge_tree(&z(&["def456", "x.rs", "y.rs"]), 1).unwrap();
        assert_eq!(tree, "def456");
        assert!(conflicted.contains("x.rs") && conflicted.contains("y.rs"));
        assert_eq!(parse_merge_tree(b"usage: ...", 129), None);
    }

    #[test]
    fn diffs_keep_hunks_and_drop_headers() {
        let d = parse_diff("diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n\\ No newline at end of file\n");
        assert_eq!(
            d,
            vec![
                (LineKind::Meta, "@@ -1,2 +1,2 @@".into()),
                (LineKind::Context, " keep".into()),
                (LineKind::Removed, "-old".into()),
                (LineKind::Added, "+new".into()),
                (LineKind::Meta, "\\ No newline at end of file".into()),
            ]
        );
    }

    #[test]
    fn tree_rows_open_only_expanded_directories() {
        let files: Vec<String> = ["README.md", "src/main.rs", "src/ui/view.rs", "Cargo.toml"].iter().map(|s| s.to_string()).collect();
        let closed = tree_rows(&files, &BTreeSet::new());
        assert_eq!(closed.iter().map(|r| r.name.as_str()).collect::<Vec<_>>(), ["src", "Cargo.toml", "README.md"]);
        let open: BTreeSet<String> = ["src".to_string()].into();
        let rows = tree_rows(&files, &open);
        assert_eq!(rows.iter().map(|r| (r.depth, r.name.as_str())).collect::<Vec<_>>(), [(0, "src"), (1, "ui"), (1, "main.rs"), (0, "Cargo.toml"), (0, "README.md")]);
        assert!(rows[0].expanded && !rows[1].expanded);
        assert_eq!(rows[2].path, "src/main.rs");
    }

    #[test]
    fn lines_are_counted_with_or_without_a_final_newline() {
        assert_eq!(line_count(b"a\nb\n"), 2);
        assert_eq!(line_count(b"a\nb"), 2);
        assert_eq!(line_count(b""), 0);
        assert!(is_binary(b"\x89PNG\0\0"));
    }

    /// A real repository: uncommitted, untracked, committed-not-in-base, and
    /// work already in the base (which must not be listed).
    #[test]
    fn changes_in_a_scratch_repository() {
        let dir = std::env::temp_dir().join(format!("sh-gpui-git-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let d = dir.to_str().unwrap();
        let sh = |args: &[&str]| assert!(git_raw(d, args).is_some_and(|(c, _)| c == 0), "git {args:?}");
        sh(&["init", "-q", "-b", "main"]);
        sh(&["config", "user.email", "t@t"]);
        sh(&["config", "user.name", "t"]);
        std::fs::write(dir.join("base.txt"), "one\n").unwrap();
        std::fs::write(dir.join("shared.txt"), "same\n").unwrap();
        sh(&["add", "."]);
        sh(&["commit", "-qm", "base"]);
        sh(&["switch", "-qc", "task/x"]);
        std::fs::write(dir.join("feature.txt"), "a\nb\n").unwrap();
        sh(&["add", "feature.txt"]);
        sh(&["commit", "-qm", "feature"]);
        // The same change made on main as well (as a squash merge would):
        // merging adds nothing for it.
        std::fs::write(dir.join("shared.txt"), "same\nmore\n").unwrap();
        sh(&["commit", "-qam", "shared on branch"]);
        sh(&["switch", "-q", "main"]);
        std::fs::write(dir.join("shared.txt"), "same\nmore\n").unwrap();
        sh(&["commit", "-qam", "shared on main"]);
        sh(&["switch", "-q", "task/x"]);
        std::fs::write(dir.join("base.txt"), "one\ntwo\n").unwrap();
        std::fs::write(dir.join("new.txt"), "x\n").unwrap();

        let c = changes(d);
        assert_eq!(c.base.as_deref(), Some("main"));
        let un: Vec<(&str, char)> = c.uncommitted().map(|f| (f.path.as_str(), f.status)).collect();
        assert_eq!(un, [("base.txt", 'M'), ("new.txt", '?')]);
        let co: Vec<&str> = c.committed().map(|f| f.path.as_str()).collect();
        assert_eq!(co, ["feature.txt"], "shared.txt is already in main");
        let feat = c.committed().next().unwrap();
        assert_eq!((feat.added, feat.removed), (Some(2), Some(0)));
        match preview_change(d, feat, &c) {
            Preview::Diff(lines) => assert!(lines.contains(&(LineKind::Added, "+b".into()))),
            other => panic!("{other:?}"),
        }
        match preview_change(d, c.uncommitted().nth(1).unwrap(), &c) {
            Preview::Diff(lines) => assert_eq!(lines, vec![(LineKind::Added, "+x".into())]),
            other => panic!("{other:?}"),
        }
        assert_eq!(files(d), ["base.txt", "feature.txt", "new.txt", "shared.txt"]);
        let _ = std::fs::remove_dir_all(&dir);
    }
}

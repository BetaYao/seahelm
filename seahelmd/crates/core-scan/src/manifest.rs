//! Agent manifests: one JSON file per agent holding the priority-ordered
//! screen rules that say what the agent is doing, plus how to recognise its
//! process and which signal is the authority for its state.
//!
//! Ported from `AgentManifest.swift`, `ManifestEngine.swift` and
//! `ManifestStore.swift`. The schema mirrors herdr's per-agent manifests; the
//! `process`, `authority` and `message` blocks are seahelm's own.
//!
//! Two things differ from the Swift on purpose (`docs/status-core-port.md`):
//! a regex that does not compile rejects the whole manifest with an error,
//! where the Swift dropped the pattern silently and left a rule that matched
//! more than its author meant; and the store's order is deterministic (user
//! overrides, then bundled, each by id), where the Swift's dictionary order
//! could change which manifest won process identification.

use std::collections::{BTreeMap, HashMap};
use std::fmt;
use std::path::{Path, PathBuf};

use regex::Regex;
use seahelm_core_types::{AgentStatus, AgentType, Authority};
use serde::Deserialize;

use crate::detect::{Detection, DetectionInput};

/// The detection-engine version this build understands. A manifest asking
/// for a newer one is rejected rather than half-understood.
pub const MANIFEST_ENGINE_VERSION: i64 = 1;

// Safety limits (from herdr), enforced after decoding.
const MAX_RULES_PER_MANIFEST: usize = 128;
const MAX_GATE_DEPTH: usize = 8;
const MAX_TOTAL_GATES: usize = 512;
const MAX_MATCHER_CHARS: usize = 512;

/// The manifests shipped with seahelm, embedded so the core needs no
/// resource directory. Sorted by id.
const BUNDLED: &[(&str, &str)] = &[
    ("agent.json", include_str!("../manifests/agent.json")),
    ("aider.json", include_str!("../manifests/aider.json")),
    ("amp.json", include_str!("../manifests/amp.json")),
    ("claude.json", include_str!("../manifests/claude.json")),
    ("cline.json", include_str!("../manifests/cline.json")),
    ("codex.json", include_str!("../manifests/codex.json")),
    ("cursor.json", include_str!("../manifests/cursor.json")),
    ("gemini.json", include_str!("../manifests/gemini.json")),
    ("goose.json", include_str!("../manifests/goose.json")),
    ("kiro.json", include_str!("../manifests/kiro.json")),
    ("opencode.json", include_str!("../manifests/opencode.json")),
    ("pi.json", include_str!("../manifests/pi.json")),
];

fn default_status_idle() -> String {
    "idle".into()
}
fn default_engine() -> i64 {
    1
}
fn default_authority() -> String {
    "session_only".into()
}
fn default_region() -> String {
    "whole_recent".into()
}

/// One agent's manifest, as decoded.
#[derive(Clone, Debug, Deserialize)]
pub struct AgentManifest {
    pub id: String,
    #[serde(default)]
    pub version: String,
    #[serde(default = "default_engine")]
    pub min_engine_version: i64,
    #[serde(default)]
    pub aliases: Vec<String>,
    /// What the agent is when no rule matched. Weaker than a match: see
    /// [`Detection::is_defaulted`].
    #[serde(default = "default_status_idle")]
    pub default_status: String,
    #[serde(default)]
    pub message_skip_patterns: Vec<String>,
    #[serde(default)]
    pub rules: Vec<ManifestRule>,
    /// How to recognise the agent's process (seahelm extension).
    #[serde(default)]
    pub process: Option<ProcessMatch>,
    /// `session_only` | `full_lifecycle` | `screen_only` (seahelm extension).
    #[serde(default = "default_authority")]
    pub authority: String,
    /// The message-stream display policy (seahelm extension).
    #[serde(default)]
    pub message: Option<MessageConfig>,
}

/// Process-tree identification hints: match a pane's processes by executable
/// name or argv, looking through generic runtimes (node → codex).
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
pub struct ProcessMatch {
    /// argv0's basename equals one of these.
    pub exec_names: Vec<String>,
    /// Any argv token contains one of these (wrapper penetration).
    pub argv_contains: Vec<String>,
    /// When argv0 is one of these, `argv_contains` decides.
    pub generic_runtimes: Vec<String>,
    /// Declared by every bundled manifest but read by nothing in production.
    pub env_hint: Option<String>,
}

/// A rule: an inline [`MatchGate`] plus what a match means.
#[derive(Clone, Debug, Deserialize)]
pub struct ManifestRule {
    pub id: String,
    pub state: String,
    #[serde(default)]
    pub priority: i64,
    #[serde(default = "default_region")]
    pub region: String,
    #[serde(default)]
    pub skip_state_update: bool,
    #[serde(default)]
    pub visible_idle: bool,
    #[serde(default)]
    pub visible_blocker: bool,
    #[serde(default)]
    pub visible_working: bool,
    /// This rule reports background work the session started (a shell, a
    /// monitor), not the agent's own state. It never decides `state`: it only
    /// raises [`Detection::background_busy`]. Conflating the two pinned a pane
    /// parked at an empty prompt on running for as long as its monitor lived,
    /// and a pane that never leaves running never produces the edge that
    /// notifies.
    #[serde(default)]
    pub background_task: bool,
    #[serde(flatten)]
    pub gate: MatchGate,
}

/// A recursive boolean matcher. It matches when every `contains` substring
/// and every `regex` is found, some line matches each `line_regex`, every
/// `all` gate matches, some `any` gate matches (when there are any), and no
/// `not` gate matches.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
pub struct MatchGate {
    pub contains: Vec<String>,
    pub regex: Vec<String>,
    pub line_regex: Vec<String>,
    pub all: Vec<MatchGate>,
    pub any: Vec<MatchGate>,
    pub not: Vec<MatchGate>,
}

/// How the message stream shows an agent's turns. Decoded and resolved here
/// because it lives in the manifest; consumed by whoever builds the stream.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct MessageConfig {
    pub assistant_from: String,
    pub user_fields: Vec<String>,
    pub tool_detail_keys: BTreeMap<String, Vec<String>>,
    pub tool_aliases: BTreeMap<String, String>,
    pub coalesce_tools: bool,
    pub screen_fallback: bool,
}

impl Default for MessageConfig {
    fn default() -> Self {
        MessageConfig {
            assistant_from: "stop_last_assistant_message".into(),
            user_fields: vec!["prompt".into(), "message".into()],
            tool_detail_keys: BTreeMap::new(),
            tool_aliases: BTreeMap::new(),
            coalesce_tools: true,
            screen_fallback: false,
        }
    }
}

impl MessageConfig {
    /// The agent manifest's `message` block, or the defaults. Looked up by
    /// manifest id ("claude"), not the agent type's wire name ("claudeCode"),
    /// which no manifest id or alias answers to.
    pub fn resolve<'a>(agent: AgentType, lookup: impl FnOnce(&str) -> Option<&'a AgentManifest>) -> MessageConfig {
        lookup(agent.manifest_id()).and_then(|m| m.message.clone()).unwrap_or_default()
    }
}

/// A slice of the screen a rule is matched against.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Region {
    WholeRecent,
    AfterLastHorizontalRule,
    /// The prompt-box and prompt-marker regions need OSC 133 marks, which
    /// nothing feeds yet; like the Swift they read the whole screen.
    PromptBoxBody,
    AfterLastPromptMarker,
    BeforeCurrentPromptMarker,
    BottomLines(usize),
    BottomNonEmptyLines(usize),
    OscTitle,
    OscProgress,
}

impl Region {
    /// `name` or `name:N`. Unknown names read the whole screen; a missing or
    /// unparsable N is 10; a negative one selects nothing.
    pub fn parse(raw: &str) -> Region {
        let (head, arg) = match raw.split_once(':') {
            Some((h, a)) => (h, Some(a)),
            None => (raw, None),
        };
        let n = arg.and_then(|a| a.parse::<i64>().ok()).map(|v| v.max(0) as usize).unwrap_or(10);
        match head {
            "bottom_lines" => Region::BottomLines(n),
            "bottom_non_empty_lines" => Region::BottomNonEmptyLines(n),
            "after_last_horizontal_rule" => Region::AfterLastHorizontalRule,
            "prompt_box_body" => Region::PromptBoxBody,
            "after_last_prompt_marker" => Region::AfterLastPromptMarker,
            "before_current_prompt_marker" => Region::BeforeCurrentPromptMarker,
            "osc_title" => Region::OscTitle,
            "osc_progress" => Region::OscProgress,
            _ => Region::WholeRecent,
        }
    }
}

/// Why a manifest was not loaded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ManifestError {
    /// Not valid JSON, or not a manifest.
    Decode(String),
    EngineTooNew(i64),
    TooManyRules(usize),
    GateTooDeep,
    TooManyGates(usize),
    MatcherTooLong,
    /// A pattern the regex engine rejects. The Swift dropped these silently.
    Regex { rule: String, pattern: String, error: String },
}

impl fmt::Display for ManifestError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ManifestError::Decode(e) => write!(f, "decode: {e}"),
            ManifestError::EngineTooNew(v) => {
                write!(f, "needs engine version {v}, this build has {MANIFEST_ENGINE_VERSION}")
            }
            ManifestError::TooManyRules(n) => write!(f, "{n} rules (limit {MAX_RULES_PER_MANIFEST})"),
            ManifestError::GateTooDeep => write!(f, "gates nested deeper than {MAX_GATE_DEPTH}"),
            ManifestError::TooManyGates(n) => write!(f, "{n} gates (limit {MAX_TOTAL_GATES})"),
            ManifestError::MatcherTooLong => write!(f, "a matcher is longer than {MAX_MATCHER_CHARS} characters"),
            ManifestError::Regex { rule, pattern, error } => {
                write!(f, "rule {rule}: invalid regex {pattern:?}: {error}")
            }
        }
    }
}

impl std::error::Error for ManifestError {}

impl AgentManifest {
    /// Decode one manifest file.
    pub fn from_json(json: &str) -> Result<AgentManifest, ManifestError> {
        serde_json::from_str(json).map_err(|e| ManifestError::Decode(e.to_string()))
    }

    /// Reject manifests that are incompatible or exceed the safety limits.
    pub fn validated(self) -> Result<AgentManifest, ManifestError> {
        if self.min_engine_version > MANIFEST_ENGINE_VERSION {
            return Err(ManifestError::EngineTooNew(self.min_engine_version));
        }
        if self.rules.len() > MAX_RULES_PER_MANIFEST {
            return Err(ManifestError::TooManyRules(self.rules.len()));
        }
        let mut total = 0;
        for rule in &self.rules {
            walk(&rule.gate, 0, &mut total)?;
        }
        Ok(self)
    }
}

fn walk(gate: &MatchGate, depth: usize, total: &mut usize) -> Result<(), ManifestError> {
    if depth > MAX_GATE_DEPTH {
        return Err(ManifestError::GateTooDeep);
    }
    let matchers = gate.contains.iter().chain(&gate.regex).chain(&gate.line_regex);
    if matchers.into_iter().any(|m| m.chars().count() > MAX_MATCHER_CHARS) {
        return Err(ManifestError::MatcherTooLong);
    }
    for sub in gate.all.iter().chain(&gate.any).chain(&gate.not) {
        *total += 1;
        if *total > MAX_TOTAL_GATES {
            return Err(ManifestError::TooManyGates(*total));
        }
        walk(sub, depth + 1, total)?;
    }
    Ok(())
}

/// A manifest `state` in seahelm's vocabulary. Accepts herdr's words
/// (working/blocked) and seahelm's (running/waiting), in any case.
pub fn status_from_manifest(raw: &str) -> AgentStatus {
    match raw.to_lowercase().as_str() {
        "working" | "running" => AgentStatus::Running,
        "blocked" | "waiting" => AgentStatus::Waiting,
        "idle" => AgentStatus::Idle,
        "error" => AgentStatus::Error,
        "exited" => AgentStatus::Exited,
        _ => AgentStatus::Unknown,
    }
}

// MARK: - Compiled

/// A gate with its regexes compiled and substrings lowercased (the screen
/// it is matched against is lowercased by the caller).
#[derive(Clone, Debug)]
struct CompiledGate {
    contains: Vec<String>,
    regex: Vec<Regex>,
    line_regex: Vec<Regex>,
    all: Vec<CompiledGate>,
    any: Vec<CompiledGate>,
    not: Vec<CompiledGate>,
}

impl CompiledGate {
    fn new(gate: &MatchGate, rule: &str) -> Result<CompiledGate, ManifestError> {
        let compile = |patterns: &[String]| -> Result<Vec<Regex>, ManifestError> {
            patterns
                .iter()
                .map(|p| {
                    Regex::new(p).map_err(|e| ManifestError::Regex {
                        rule: rule.to_string(),
                        pattern: p.clone(),
                        error: e.to_string(),
                    })
                })
                .collect()
        };
        let sub = |gates: &[MatchGate]| -> Result<Vec<CompiledGate>, ManifestError> {
            gates.iter().map(|g| CompiledGate::new(g, rule)).collect()
        };
        Ok(CompiledGate {
            contains: gate.contains.iter().map(|c| c.to_lowercase()).collect(),
            regex: compile(&gate.regex)?,
            line_regex: compile(&gate.line_regex)?,
            all: sub(&gate.all)?,
            any: sub(&gate.any)?,
            not: sub(&gate.not)?,
        })
    }

    fn matches(&self, text: &str) -> bool {
        self.contains.iter().all(|c| text.contains(c.as_str()))
            && self.regex.iter().all(|r| r.is_match(text))
            && self.line_regex.iter().all(|r| text.split('\n').any(|line| r.is_match(line)))
            && self.all.iter().all(|g| g.matches(text))
            && (self.any.is_empty() || self.any.iter().any(|g| g.matches(text)))
            && !self.not.iter().any(|g| g.matches(text))
    }
}

#[derive(Clone, Debug)]
struct CompiledRule {
    rule: ManifestRule,
    region: Region,
    gate: CompiledGate,
}

/// What [`CompiledManifest::match_detail`] reports for `pane.explain`.
#[derive(Clone, Debug)]
pub struct MatchDetail<'a> {
    pub rule: &'a ManifestRule,
    /// The single line that satisfies the rule on its own when there is one,
    /// else the whole region text.
    pub evidence: String,
}

/// A manifest with its regexes compiled once, rules sorted by descending
/// priority (ties keep file order) so evaluation stops at the first match.
#[derive(Clone, Debug)]
pub struct CompiledManifest {
    pub manifest: AgentManifest,
    rules: Vec<CompiledRule>,
    /// `background_task` rules: their own pass, never status candidates.
    /// "The session has a shell running" and "the agent is working" answer
    /// different questions and must not shadow one another.
    background: Vec<CompiledRule>,
}

impl CompiledManifest {
    /// Validate and compile. Any pattern that does not compile is an error.
    pub fn new(manifest: AgentManifest) -> Result<CompiledManifest, ManifestError> {
        let manifest = manifest.validated()?;
        let mut sorted: Vec<&ManifestRule> = manifest.rules.iter().collect();
        sorted.sort_by_key(|r| std::cmp::Reverse(r.priority)); // stable: ties keep file order
        let mut rules = Vec::new();
        let mut background = Vec::new();
        for r in sorted {
            let compiled = CompiledRule { rule: r.clone(), region: Region::parse(&r.region), gate: CompiledGate::new(&r.gate, &r.id)? };
            if r.background_task {
                background.push(compiled);
            } else {
                rules.push(compiled);
            }
        }
        Ok(CompiledManifest { manifest, rules, background })
    }

    /// Decode, validate and compile one manifest file.
    pub fn from_json(json: &str) -> Result<CompiledManifest, ManifestError> {
        CompiledManifest::new(AgentManifest::from_json(json)?)
    }

    /// The highest-priority matching rule's state, or `Unknown` when none
    /// matched (the caller then falls back to [`default_status`]).
    ///
    /// [`default_status`]: CompiledManifest::default_status
    pub fn evaluate(&self, input: &DetectionInput) -> Detection {
        let background_busy = self.background.iter().any(|r| r.gate.matches(&region_text(r.region, input)));
        for cr in &self.rules {
            if !cr.gate.matches(&region_text(cr.region, input)) {
                continue;
            }
            return Detection {
                state: status_from_manifest(&cr.rule.state),
                visible_idle: cr.rule.visible_idle,
                visible_blocker: cr.rule.visible_blocker,
                visible_working: cr.rule.visible_working,
                skip_state_update: cr.rule.skip_state_update,
                matched_rule_id: Some(cr.rule.id.clone()),
                is_defaulted: false,
                background_busy,
            };
        }
        Detection { state: AgentStatus::Unknown, background_busy, ..Detection::default() }
    }

    /// What the agent is when no rule matched.
    pub fn default_status(&self) -> AgentStatus {
        status_from_manifest(&self.manifest.default_status)
    }

    /// The winning rule and the evidence it matched on, for `pane.explain`.
    /// Same order as [`evaluate`](CompiledManifest::evaluate).
    ///
    /// Evidence is narrowed to the one line responsible whenever one line is
    /// enough: reporting the whole region reads as "the rule matched this
    /// footer" when the real match was some transcript line higher up, which
    /// is how a false running gets blamed on the wrong rule.
    pub fn match_detail(&self, input: &DetectionInput) -> Option<MatchDetail<'_>> {
        self.rules.iter().find_map(|cr| {
            let text = region_text(cr.region, input);
            if !cr.gate.matches(&text) {
                return None;
            }
            Some(MatchDetail { rule: &cr.rule, evidence: narrow_evidence(&text, &cr.gate) })
        })
    }
}

fn is_space_or_tab(c: char) -> bool {
    c == ' ' || c == '\t'
}

/// Foundation's `.whitespaces`: whitespace other than line breaks.
pub(crate) fn trim_ws(s: &str) -> &str {
    s.trim_matches(|c: char| c.is_whitespace() && !matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}'))
}

fn narrow_evidence(text: &str, gate: &CompiledGate) -> String {
    text.split('\n')
        .filter(|l| !l.is_empty())
        .find(|l| gate.matches(l))
        .map(|l| trim_ws(l).to_string())
        .unwrap_or_else(|| text.to_string())
}

fn region_text(region: Region, input: &DetectionInput) -> String {
    match region {
        Region::OscTitle => input.osc_title.to_lowercase(),
        Region::OscProgress => input.osc_progress.to_lowercase(),
        Region::WholeRecent | Region::PromptBoxBody | Region::AfterLastPromptMarker | Region::BeforeCurrentPromptMarker => {
            input.screen.clone()
        }
        Region::BottomLines(n) => last_lines(&input.screen, n, false),
        Region::BottomNonEmptyLines(n) => last_lines(&input.screen, n, true),
        Region::AfterLastHorizontalRule => after_last_horizontal_rule(&input.screen),
    }
}

/// The last `count` lines (or last `count` lines with something on them).
/// A trailing newline counts as an empty last line, and an empty first line
/// is never counted: both as the Swift's backward scan did.
fn last_lines(text: &str, count: usize, non_empty: bool) -> String {
    let segments: Vec<&str> = text.split('\n').collect();
    let mut picked: Vec<&str> = Vec::new();
    for (i, line) in segments.iter().enumerate().rev() {
        if picked.len() >= count {
            break;
        }
        if i == 0 && line.is_empty() {
            break;
        }
        if non_empty && line.chars().all(is_space_or_tab) {
            continue;
        }
        picked.push(line);
    }
    picked.reverse();
    picked.join("\n")
}

/// Everything below the last line drawn only of rule characters; the whole
/// text when there is no such line or nothing follows it.
fn after_last_horizontal_rule(text: &str) -> String {
    const RULE: &[char] = &['─', '═', '━', '-', '_'];
    let lines: Vec<&str> = text.split('\n').collect();
    let last = lines.iter().rposition(|l| {
        let t = trim_ws(l);
        !t.is_empty() && t.chars().all(|c| RULE.contains(&c))
    });
    match last {
        Some(i) if i + 1 < lines.len() => lines[i + 1..].join("\n"),
        _ => text.to_string(),
    }
}

// MARK: - Store

struct Entry {
    compiled: CompiledManifest,
    from_user: bool,
}

/// The bundled manifests, overridden by id from a user directory. Lookup by
/// id or alias.
pub struct ManifestStore {
    /// User overrides first, then bundled, each sorted by id. Process
    /// identification takes the first manifest that matches, so this order
    /// decides it and must not depend on hashing.
    entries: Vec<Entry>,
    by_alias: HashMap<String, usize>,
    errors: Vec<String>,
}

impl ManifestStore {
    /// Only the manifests shipped with seahelm.
    pub fn bundled() -> Self {
        Self::build(Vec::new(), Vec::new())
    }

    /// Bundled manifests overridden, by id, by every `*.json` in `dir`
    /// (`~/.config/seahelm/agents` in production; see [`default_user_dir`]).
    /// A file that does not decode, validate or compile is left out and
    /// reported, and the bundled manifest of that id stays in force. A
    /// missing directory is not an error.
    ///
    /// [`default_user_dir`]: ManifestStore::default_user_dir
    pub fn with_user_dir(dir: &Path) -> (Self, Vec<String>) {
        let mut errors = Vec::new();
        let mut user = Vec::new();
        let mut files: Vec<PathBuf> = match std::fs::read_dir(dir) {
            Ok(rd) => rd
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.extension().is_some_and(|x| x == "json"))
                .collect(),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => {
                errors.push(format!("{}: {e}", dir.display()));
                Vec::new()
            }
        };
        files.sort();
        for path in files {
            let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            match std::fs::read_to_string(&path) {
                Ok(json) => match CompiledManifest::from_json(&json) {
                    Ok(cm) => user.push(cm),
                    Err(e) => errors.push(format!("{name}: {e}")),
                },
                Err(e) => errors.push(format!("{name}: {e}")),
            }
        }
        let store = Self::build(user, errors.clone());
        (store, errors)
    }

    /// `~/.config/seahelm/agents`, from `HOME` (or `USERPROFILE`).
    pub fn default_user_dir() -> Option<PathBuf> {
        let home = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE"))?;
        Some(PathBuf::from(home).join(".config").join("seahelm").join("agents"))
    }

    fn build(user: Vec<CompiledManifest>, mut errors: Vec<String>) -> Self {
        // Later user files with the same id replace earlier ones, as the
        // Swift's dictionary insert did.
        let mut user_by_id: BTreeMap<String, CompiledManifest> = BTreeMap::new();
        for cm in user {
            user_by_id.insert(cm.manifest.id.clone(), cm);
        }
        let mut bundled: BTreeMap<String, CompiledManifest> = BTreeMap::new();
        for (file, json) in BUNDLED {
            match CompiledManifest::from_json(json) {
                Ok(cm) => {
                    if !user_by_id.contains_key(&cm.manifest.id) {
                        bundled.insert(cm.manifest.id.clone(), cm);
                    }
                }
                // Covered by a test; reported rather than panicking so a
                // broken build still scans with the rest.
                Err(e) => errors.push(format!("bundled {file}: {e}")),
            }
        }
        let entries: Vec<Entry> = user_by_id
            .into_values()
            .map(|compiled| Entry { compiled, from_user: true })
            .chain(bundled.into_values().map(|compiled| Entry { compiled, from_user: false }))
            .collect();
        let mut by_alias = HashMap::new();
        for (i, e) in entries.iter().enumerate() {
            by_alias.entry(e.compiled.manifest.id.clone()).or_insert(i);
        }
        for (i, e) in entries.iter().enumerate() {
            for a in &e.compiled.manifest.aliases {
                by_alias.entry(a.to_lowercase()).or_insert(i);
            }
        }
        ManifestStore { entries, by_alias, errors }
    }

    /// By exact id first, then by id or alias case-insensitively.
    pub fn get(&self, id_or_alias: &str) -> Option<&CompiledManifest> {
        if let Some(e) = self.entries.iter().find(|e| e.compiled.manifest.id == id_or_alias) {
            return Some(&e.compiled);
        }
        self.by_alias.get(&id_or_alias.to_lowercase()).map(|&i| &self.entries[i].compiled)
    }

    /// Every loaded manifest in the store's deterministic order.
    pub fn all(&self) -> impl Iterator<Item = &CompiledManifest> {
        self.entries.iter().map(|e| &e.compiled)
    }

    /// Whether this id came from the user directory.
    pub fn is_user_override(&self, id: &str) -> bool {
        self.entries.iter().any(|e| e.from_user && e.compiled.manifest.id == id)
    }

    /// The pane's state authority (the manifest's `authority`; session_only
    /// when there is no manifest).
    pub fn authority(&self, agent: AgentType) -> Authority {
        self.get(agent.manifest_id()).map(|m| Authority::parse(&m.manifest.authority)).unwrap_or_default()
    }

    /// Whether a process probe can see this agent at all: its manifest names
    /// processes to look for. For one that does not, a probe finding nothing
    /// says nothing, so it must not be read as the agent having exited.
    pub fn can_identify(&self, agent: AgentType) -> bool {
        crate::process::can_identify(agent.manifest_id(), self.all().map(|c| &c.manifest))
    }

    /// The agent's message-stream policy.
    pub fn message_config(&self, agent: AgentType) -> MessageConfig {
        MessageConfig::resolve(agent, |id| self.get(id).map(|c| &c.manifest))
    }

    /// Manifests that failed to load, as `"<file>: <error>"`.
    pub fn load_errors(&self) -> &[String] {
        &self.errors
    }
}

impl Default for ManifestStore {
    fn default() -> Self {
        Self::bundled()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_bundled_manifest_compiles() {
        for (file, json) in BUNDLED {
            if let Err(e) = CompiledManifest::from_json(json) {
                panic!("{file}: {e}");
            }
        }
        let store = ManifestStore::bundled();
        assert!(store.load_errors().is_empty(), "{:?}", store.load_errors());
        assert_eq!(store.all().count(), BUNDLED.len());
    }

    #[test]
    fn bottom_lines_counts_a_trailing_newline_and_skips_a_leading_one() {
        assert_eq!(last_lines("a\nb\n", 2, false), "b\n");
        assert_eq!(last_lines("\nabc", 5, false), "abc");
        assert_eq!(last_lines("a\n  \nb", 2, true), "a\nb");
        assert_eq!(last_lines("", 3, false), "");
        assert_eq!(last_lines("a\nb", 0, false), "");
    }

    #[test]
    fn after_last_rule_takes_what_follows() {
        assert_eq!(after_last_horizontal_rule("x\n───\ny\nz"), "y\nz");
        assert_eq!(after_last_horizontal_rule("x\n───"), "x\n───");
        assert_eq!(after_last_horizontal_rule("plain"), "plain");
    }

    #[test]
    fn region_parse_reads_counts() {
        assert_eq!(Region::parse("bottom_lines:12"), Region::BottomLines(12));
        assert_eq!(Region::parse("bottom_lines"), Region::BottomLines(10));
        assert_eq!(Region::parse("bottom_non_empty_lines:x"), Region::BottomNonEmptyLines(10));
        assert_eq!(Region::parse("nonsense"), Region::WholeRecent);
    }
}

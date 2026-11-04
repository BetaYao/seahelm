//! Claude's and Codex's rate limits and today's tokens: the macOS app's
//! `Sources/Usage` (`ClaudeUsageSummaryProvider`, `CodexUsageSummaryProvider`,
//! `UsageSummaryStore`, `UsageSummaryFormatter.readouts`), as a core service
//! every client can ask (`usage.summary`).
//!
//! - Claude reports its limits only inside the statusline payload, so they
//!   are read from the cache the statusline bridge tees that payload into
//!   (`statusline_cache_path`; the app's bridge or `seahelm-core statusline`).
//!   `~/.claude/projects` is not scanned: a day of transcripts runs to
//!   hundreds of MB.
//! - Codex's limits come from `codex app-server` (`account/rateLimits/read`
//!   over stdio); today's tokens from its session logs.
//!
//! A background thread refreshes both every minute, never the RPC thread.
//! Each field falls back to its last reading for ten minutes (the store's
//! `ProviderSnapshotCache`), so one missed refresh does not blank it.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

pub const REFRESH: Duration = Duration::from_secs(60);
const CACHE_FALLBACK_MAX_AGE: f64 = 10.0 * 60.0;
const CLAUDE_STALE_INTERVAL: f64 = 6.0 * 60.0 * 60.0;
const SESSION_FILE_GRACE: f64 = 24.0 * 60.0 * 60.0;
const CODEX_TIMEOUT: Duration = Duration::from_secs(8);

// ---------------------------------------------------------------- model

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Provider {
    Claude,
    Codex,
}

impl Provider {
    pub fn id(self) -> &'static str {
        match self {
            Provider::Claude => "claude",
            Provider::Codex => "codex",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Provider::Claude => "Claude",
            Provider::Codex => "Codex",
        }
    }
}

/// `UsageRateLimitWindow`.
#[derive(Clone, Debug, PartialEq)]
pub struct Window {
    pub used_percent: i64,
    pub resets_at: Option<f64>,
    /// "5h", "7d", "quota"; none falls back to the caller's default.
    pub label: Option<String>,
}

impl Window {
    pub fn new(used_percent: i64, resets_at: Option<f64>) -> Self {
        Window { used_percent, resets_at, label: None }
    }
}

/// `UsageSnapshot`.
#[derive(Clone, Debug, PartialEq)]
pub struct Snapshot {
    pub provider: Provider,
    pub rate_limit: Option<Window>,
    pub weekly_rate_limit: Option<Window>,
    pub today_tokens: Option<i64>,
    pub updated_at: Option<f64>,
    pub is_stale: bool,
}

impl Snapshot {
    #[cfg(test)]
    pub fn empty(provider: Provider) -> Self {
        Snapshot { provider, rate_limit: None, weekly_rate_limit: None, today_tokens: None, updated_at: None, is_stale: true }
    }

    pub fn to_json(&self) -> Value {
        let w = |w: &Option<Window>| match w {
            Some(w) => json!({"used_percent": w.used_percent, "resets_at": w.resets_at, "label": w.label}),
            None => Value::Null,
        };
        json!({
            "provider": self.provider.id(),
            "rate_limit": w(&self.rate_limit),
            "weekly_rate_limit": w(&self.weekly_rate_limit),
            "today_tokens": self.today_tokens,
            "updated_at": self.updated_at,
            "is_stale": self.is_stale,
        })
    }
}

// ---------------------------------------------------------------- time

pub fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// RFC 3339 / ISO 8601 date-time to Unix seconds: `2026-04-27T12:19:00Z`,
/// with or without fractional seconds, `Z` or `±hh:mm`.
pub fn parse_iso8601(s: &str) -> Option<f64> {
    let s = s.trim();
    let b = s.as_bytes();
    if b.len() < 20 || b[4] != b'-' || b[7] != b'-' || !(b[10] == b'T' || b[10] == b't' || b[10] == b' ') {
        return None;
    }
    let num = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let (y, mo, d, h, mi, se) = (num(0..4)?, num(5..7)?, num(8..10)?, num(11..13)?, num(14..16)?, num(17..19)?);
    if b[13] != b':' || b[16] != b':' || !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || se > 60 {
        return None;
    }
    let mut rest = &s[19..];
    let mut frac = 0.0;
    if let Some(r) = rest.strip_prefix('.') {
        let digits: String = r.chars().take_while(|c| c.is_ascii_digit()).collect();
        if digits.is_empty() {
            return None;
        }
        frac = format!("0.{digits}").parse().ok()?;
        rest = &r[digits.len()..];
    }
    let offset = match rest {
        "Z" | "z" => 0,
        _ => {
            let sign = match rest.as_bytes().first()? {
                b'+' => 1,
                b'-' => -1,
                _ => return None,
            };
            let hm = rest[1..].replace(':', "");
            if hm.len() != 4 {
                return None;
            }
            let oh: i64 = hm[..2].parse().ok()?;
            let om: i64 = hm[2..].parse().ok()?;
            sign * (oh * 3600 + om * 60)
        }
    };
    let secs = days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se - offset;
    Some(secs as f64 + frac)
}

/// The local zone's offset from UTC at `at`, in seconds (east positive).
pub fn local_offset(at: f64) -> i64 {
    #[cfg(unix)]
    unsafe {
        let t = at as libc::time_t;
        let mut tm: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&t, &mut tm).is_null() {
            return 0;
        }
        tm.tm_gmtoff as i64
    }
    #[cfg(windows)]
    {
        let _ = at;
        use windows_sys::Win32::System::Time::{GetTimeZoneInformation, TIME_ZONE_INFORMATION};
        unsafe {
            let mut tz: TIME_ZONE_INFORMATION = std::mem::zeroed();
            // 2 = TIME_ZONE_ID_DAYLIGHT: the daylight bias applies now.
            let id = GetTimeZoneInformation(&mut tz);
            let bias = tz.Bias + if id == 2 { tz.DaylightBias } else { tz.StandardBias };
            -(bias as i64) * 60
        }
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = at;
        0
    }
}

/// The start of the day `at` falls in, in a zone `offset` seconds east of UTC.
pub fn day_start(at: f64, offset: i64) -> f64 {
    let local = at.floor() as i64 + offset;
    (local.div_euclid(86400) * 86400 - offset) as f64
}

fn same_local_day(a: f64, b: f64) -> bool {
    day_start(a, local_offset(a)) == day_start(b, local_offset(b))
}

fn int_value(v: Option<&Value>) -> Option<i64> {
    match v? {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        Value::String(s) => s.parse::<i64>().ok().or_else(|| s.parse::<f64>().ok().map(|f| f as i64)),
        _ => None,
    }
}

fn double_value(v: Option<&Value>) -> Option<f64> {
    match v? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.parse().ok(),
        _ => None,
    }
}

fn number_value(v: Option<&Value>) -> Option<f64> {
    match v? {
        Value::Number(n) => n.as_f64(),
        _ => None,
    }
}

fn file_mtime(path: &Path) -> Option<f64> {
    let m = std::fs::metadata(path).ok()?.modified().ok()?;
    m.duration_since(UNIX_EPOCH).ok().map(|d| d.as_secs_f64())
}

// ---------------------------------------------------------------- Claude

/// Where the statusline payload is cached: the app's macOS path, so the
/// app's own bridge keeps feeding it; the XDG cache on Linux; the local app
/// data on Windows.
pub fn statusline_cache_path() -> PathBuf {
    statusline_cache_dir().join("claude-statusline.json")
}

pub fn statusline_cache_dir() -> PathBuf {
    let home = crate::install::home();
    if cfg!(target_os = "macos") {
        return home.join("Library/Caches/seahelm");
    }
    if cfg!(windows) {
        let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_else(|| home.join("AppData/Local"));
        return base.join("seahelm").join("cache");
    }
    let base = std::env::var_os("XDG_CACHE_HOME").filter(|v| !v.is_empty()).map(PathBuf::from).unwrap_or_else(|| home.join(".cache"));
    base.join("seahelm")
}

/// `ClaudeStatuslineRateLimits`: the two windows, each optional.
#[derive(Clone, Debug, PartialEq)]
pub struct ClaudeRateLimits {
    pub five_hour: Option<Window>,
    pub seven_day: Option<Window>,
}

/// `ClaudeStatuslineCacheReader`: the cached payload's `rate_limits`, unless
/// the file is older than `stale_interval`.
pub struct ClaudeCacheReader {
    pub cache: PathBuf,
    pub stale_interval: f64,
}

impl ClaudeCacheReader {
    pub fn read(&self, now: f64) -> Option<ClaudeRateLimits> {
        let modified = file_mtime(&self.cache)?;
        if now - modified > self.stale_interval {
            return None;
        }
        let root: Value = serde_json::from_slice(&std::fs::read(&self.cache).ok()?).ok()?;
        let limits = root.get("rate_limits");
        let five_hour = parse_claude_window(limits.and_then(|l| l.get("five_hour")));
        let seven_day = parse_claude_window(limits.and_then(|l| l.get("seven_day")));
        if five_hour.is_none() && seven_day.is_none() {
            return None;
        }
        Some(ClaudeRateLimits { five_hour, seven_day })
    }
}

fn parse_claude_window(w: Option<&Value>) -> Option<Window> {
    let w = w?;
    let used = match w.get("used_percentage")? {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64))?,
        _ => return None,
    };
    let resets_at = match w.get("resets_at") {
        Some(Value::String(s)) => parse_iso8601(s).or_else(|| s.parse::<f64>().ok()),
        Some(Value::Number(n)) => n.as_f64(),
        _ => None,
    };
    Some(Window::new(used, resets_at))
}

/// `ClaudeUsageSummaryProvider.snapshot`.
pub fn claude_snapshot(reader: &ClaudeCacheReader, now: f64) -> Snapshot {
    let limits = reader.read(now);
    let five = limits.as_ref().and_then(|l| l.five_hour.clone());
    let seven = limits.as_ref().and_then(|l| l.seven_day.clone());
    let is_stale = five.is_none() && seven.is_none();
    Snapshot {
        provider: Provider::Claude,
        rate_limit: five,
        weekly_rate_limit: seven,
        today_tokens: None,
        updated_at: Some(now),
        is_stale,
    }
}

// ---------------------------------------------------------------- Codex

/// `CodexRateLimits`.
#[derive(Clone, Debug, PartialEq)]
pub struct CodexRateLimits {
    pub primary: Option<Window>,
    pub secondary: Option<Window>,
}

/// `CodexRateLimitParser.parseResponse`: the `codex` bucket, else the
/// account-wide one.
pub fn parse_codex_response(root: &Value) -> Option<CodexRateLimits> {
    let result = root.get("result");
    let codex = result.and_then(|r| r.get("rateLimitsByLimitId")).and_then(|b| b.get("codex"));
    let fallback = result.and_then(|r| r.get("rateLimits"));
    parse_codex_snapshot(codex).or_else(|| parse_codex_snapshot(fallback))
}

/// `parseResponseLine`: one stdout line, if it answers request `expected_id`.
pub fn parse_codex_response_line(line: &str, expected_id: i64) -> Option<CodexRateLimits> {
    let root: Value = serde_json::from_str(line).ok()?;
    if int_value(root.get("id")) != Some(expected_id) {
        return None;
    }
    parse_codex_response(&root)
}

fn parse_codex_snapshot(s: Option<&Value>) -> Option<CodexRateLimits> {
    let s = s.filter(|v| v.is_object())?;
    let primary = codex_window(s.get("primary"));
    let secondary = codex_window(s.get("secondary"));
    if primary.is_some() || secondary.is_some() {
        return Some(CodexRateLimits { primary, secondary });
    }
    // Plans without rolling windows (business seats) report one plan-wide
    // allowance instead.
    let individual = individual_limit(s.get("individualLimit"))?;
    Some(CodexRateLimits { primary: Some(individual), secondary: None })
}

fn codex_window(w: Option<&Value>) -> Option<Window> {
    let w = w.filter(|v| v.is_object())?;
    let used = int_value(w.get("usedPercent"))?;
    Some(Window {
        used_percent: used,
        resets_at: number_value(w.get("resetsAt")),
        label: int_value(w.get("windowDurationMins")).map(window_label),
    })
}

fn individual_limit(l: Option<&Value>) -> Option<Window> {
    let l = l.filter(|v| v.is_object())?;
    let used = if let Some(remaining) = int_value(l.get("remainingPercent")) {
        100 - remaining
    } else {
        let cap = double_value(l.get("limit")).filter(|c| *c > 0.0)?;
        let spent = double_value(l.get("used"))?;
        (spent / cap * 100.0).round() as i64
    };
    Some(Window { used_percent: used.clamp(0, 100), resets_at: number_value(l.get("resetsAt")), label: Some("quota".into()) })
}

/// 300 → "5h", 10080 → "7d".
pub fn window_label(minutes: i64) -> String {
    if minutes >= 1440 && minutes % 1440 == 0 {
        return format!("{}d", minutes / 1440);
    }
    if minutes >= 60 && minutes % 60 == 0 {
        return format!("{}h", minutes / 60);
    }
    format!("{minutes}m")
}

/// `CodexAppServerRateLimitClient.resolveExecutable`: a path as given if it
/// can be run; a bare name on PATH or in the usual install places (a
/// process started from a GUI may have a short PATH).
pub fn resolve_executable(name: &str) -> Option<PathBuf> {
    if name.contains('/') || name.contains('\\') {
        let p = PathBuf::from(name);
        return is_executable(&p).then_some(p);
    }
    let home = crate::install::home();
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    for extra in ["/opt/homebrew/bin", "/usr/local/bin"] {
        dirs.push(PathBuf::from(extra));
    }
    dirs.push(home.join(".local/bin"));
    dirs.push(home.join(".bun/bin"));
    if cfg!(windows) {
        if let Some(appdata) = std::env::var_os("APPDATA") {
            dirs.push(PathBuf::from(appdata).join("npm"));
        }
    }
    let names: Vec<String> = if cfg!(windows) {
        ["", ".exe", ".cmd", ".bat"].iter().map(|ext| format!("{name}{ext}")).collect()
    } else {
        vec![name.to_string()]
    };
    dirs.iter().flat_map(|d| names.iter().map(move |n| d.join(n))).find(|p| is_executable(p))
}

fn is_executable(p: &Path) -> bool {
    let Ok(meta) = std::fs::metadata(p) else { return false };
    if !meta.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        meta.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    true
}

/// `CodexAppServerRateLimitClient.readRateLimit`: ask `codex app-server`
/// over stdio. Its answer comes over the network and it exits the moment
/// stdin closes, so stdin stays open until the answer is in (or the
/// timeout), and the process is killed after.
pub fn read_codex_rate_limits(executable: &str, timeout: Duration) -> Option<CodexRateLimits> {
    let exe = resolve_executable(executable)?;
    let mut cmd = command_for(&exe);
    cmd.args(["app-server", "--listen", "stdio://"]).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
    let mut child = cmd.spawn().ok()?;
    let stdout = child.stdout.take()?;
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            if let Some(parsed) = parse_codex_response_line(&line, 2) {
                let _ = tx.send(Some(parsed));
                return;
            }
        }
        let _ = tx.send(None);
    });
    let mut stdin = child.stdin.take();
    let input = concat!(
        r#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"seahelm","version":"2.0.0"},"capabilities":{}}}"#,
        "\n",
        r#"{"method":"initialized"}"#,
        "\n",
        r#"{"id":2,"method":"account/rateLimits/read"}"#,
        "\n"
    );
    // A process that exits before reading gives EPIPE here; Rust ignores
    // SIGPIPE, so it is only an error.
    if let Some(s) = stdin.as_mut() {
        let _ = s.write_all(input.as_bytes());
        let _ = s.flush();
    }
    let answer = rx.recv_timeout(timeout).ok().flatten();
    // Killed while stdin is still open, then stdin goes.
    let _ = child.kill();
    drop(stdin);
    let _ = child.wait();
    answer
}

/// A `.cmd` / `.bat` shim (how npm installs codex on Windows) runs through
/// cmd; anything else directly.
fn command_for(exe: &Path) -> Command {
    let ext = exe.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
    if cfg!(windows) && (ext == "cmd" || ext == "bat") {
        let mut c = Command::new("cmd");
        c.arg("/C").arg(exe);
        c
    } else {
        Command::new(exe)
    }
}

/// `CodexSessionUsageAggregator`: today's tokens (local day, `offset`
/// seconds east of UTC) summed from every session log's `token_count`
/// events (`last_token_usage.total_tokens`). Files untouched since the day
/// before `grace` are skipped. A missing root is an error, not zero.
pub struct CodexSessions {
    pub root: PathBuf,
    pub grace: Option<f64>,
}

impl CodexSessions {
    pub fn today_tokens(&self, now: f64, offset: i64) -> Option<i64> {
        if !self.root.is_dir() {
            return None;
        }
        let start = day_start(now, offset);
        let end = start + 86400.0;
        let mut files = Vec::new();
        collect_jsonl(&self.root, &mut files);
        let mut total = 0;
        for file in files {
            if let (Some(grace), Some(modified)) = (self.grace, file_mtime(&file)) {
                if modified < start - grace {
                    continue;
                }
            }
            let Ok(text) = std::fs::read_to_string(&file) else { continue };
            for line in text.lines() {
                // Cheap filter before parsing: most lines are not token counts.
                if !line.contains("token_count") {
                    continue;
                }
                let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
                if v.get("type").and_then(Value::as_str) != Some("event_msg") {
                    continue;
                }
                let Some(at) = v.get("timestamp").and_then(Value::as_str).and_then(parse_iso8601) else { continue };
                if at < start || at >= end {
                    continue;
                }
                let payload = v.get("payload");
                if payload.and_then(|p| p.get("type")).and_then(Value::as_str) != Some("token_count") {
                    continue;
                }
                let tokens = payload
                    .and_then(|p| p.get("info"))
                    .and_then(|i| i.get("last_token_usage"))
                    .and_then(|u| u.get("total_tokens"))
                    .and_then(Value::as_i64);
                if let Some(t) = tokens {
                    total += t;
                }
            }
        }
        Some(total)
    }
}

fn collect_jsonl(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for e in entries.flatten() {
        let p = e.path();
        match e.file_type() {
            Ok(t) if t.is_dir() => collect_jsonl(&p, out),
            Ok(_) if p.extension().and_then(|x| x.to_str()) == Some("jsonl") => out.push(p),
            _ => {}
        }
    }
}

/// `CodexUsageSummaryProvider.snapshot`.
pub fn codex_snapshot(executable: &str, sessions: &CodexSessions, now: f64, timeout: Duration) -> Snapshot {
    let limits = read_codex_rate_limits(executable, timeout);
    let today = sessions.today_tokens(now, local_offset(now));
    let is_stale = limits.is_none() && today.is_none();
    Snapshot {
        provider: Provider::Codex,
        rate_limit: limits.as_ref().and_then(|l| l.primary.clone()),
        weekly_rate_limit: limits.and_then(|l| l.secondary),
        today_tokens: today,
        updated_at: Some(now),
        is_stale,
    }
}

// ---------------------------------------------------------------- cache

/// `UsageSummaryStore.ProviderSnapshotCache`: each field's last reading and
/// when, so a refresh that misses one keeps showing the last for a while.
#[derive(Clone, Debug, PartialEq)]
pub struct FieldCache {
    pub provider: Provider,
    rate_limit: Option<(Window, f64)>,
    weekly: Option<(Window, f64)>,
    today: Option<(i64, f64)>,
    is_stale: bool,
}

impl FieldCache {
    pub fn new(provider: Provider) -> Self {
        FieldCache { provider, rate_limit: None, weekly: None, today: None, is_stale: true }
    }

    pub fn ingest(&mut self, s: &Snapshot, now: f64) {
        let at = s.updated_at.unwrap_or(now);
        if let Some(w) = &s.rate_limit {
            self.rate_limit = Some((w.clone(), at));
        }
        if let Some(w) = &s.weekly_rate_limit {
            self.weekly = Some((w.clone(), at));
        }
        if let Some(t) = s.today_tokens {
            self.today = Some((t, at));
        }
        self.is_stale = s.is_stale;
    }

    pub fn display(&self, now: f64, max_age: f64) -> Snapshot {
        let fresh = |at: f64| now - at <= max_age;
        let rate = self.rate_limit.clone().filter(|(_, at)| fresh(*at));
        let weekly = self.weekly.clone().filter(|(_, at)| fresh(*at));
        let today = self.today.filter(|(_, at)| fresh(*at) && same_local_day(*at, now));
        let updated_at = [rate.as_ref().map(|r| r.1), weekly.as_ref().map(|w| w.1), today.map(|t| t.1)]
            .into_iter()
            .flatten()
            .fold(None, |m: Option<f64>, x| Some(m.map_or(x, |m| m.max(x))));
        Snapshot {
            provider: self.provider,
            rate_limit: rate.map(|r| r.0),
            weekly_rate_limit: weekly.map(|w| w.0),
            today_tokens: today.map(|t| t.0),
            updated_at,
            is_stale: self.is_stale || updated_at.is_none(),
        }
    }
}

/// `UsageSummaryStore.resolveSnapshotForDisplay`.
pub fn resolve_for_display(candidate: &Snapshot, cached: Option<&FieldCache>, now: f64, max_age: f64) -> (Snapshot, FieldCache) {
    let mut cache = cached.cloned().unwrap_or_else(|| FieldCache::new(candidate.provider));
    cache.ingest(candidate, now);
    (cache.display(now, max_age), cache)
}

// ---------------------------------------------------------------- readouts

/// `UsageReadoutSegment.Severity`: keyed to how much is used.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Severity {
    Unknown,
    Ok,
    Warn,
    Critical,
}

impl Severity {
    pub fn from_used(used: i64) -> Self {
        match used {
            ..=59 => Severity::Ok,
            60..=84 => Severity::Warn,
            _ => Severity::Critical,
        }
    }

    fn id(self) -> &'static str {
        match self {
            Severity::Unknown => "unknown",
            Severity::Ok => "ok",
            Severity::Warn => "warn",
            Severity::Critical => "critical",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Segment {
    pub label: String,
    pub percent_text: String,
    pub severity: Severity,
    pub reset_text: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Readout {
    pub provider: Provider,
    pub segments: Vec<Segment>,
}

impl Readout {
    pub fn to_json(&self) -> Value {
        json!({
            "provider": self.provider.id(),
            "name": self.provider.display_name(),
            "segments": self.segments.iter().map(|s| json!({
                "label": s.label,
                "percent_text": s.percent_text,
                "severity": s.severity.id(),
                "reset_text": s.reset_text,
            })).collect::<Vec<_>>(),
        })
    }
}

/// `UsageSummaryFormatter.readouts`.
pub fn readouts(claude: &Snapshot, codex: &Snapshot, now: f64) -> Vec<Readout> {
    vec![readout(claude, now), readout(codex, now)]
}

/// `UsageSummaryFormatter.readout(for:)`: one segment per window; a provider
/// with no current window shows a placeholder, Claude always both.
pub fn readout(s: &Snapshot, now: f64) -> Readout {
    let mut segments = Vec::new();
    match &s.rate_limit {
        Some(w) => segments.push(segment(w.label.clone().unwrap_or_else(|| "5h".into()), w, now)),
        None => segments.push(placeholder(if s.provider == Provider::Claude { "5h" } else { "quota" })),
    }
    match &s.weekly_rate_limit {
        Some(w) => segments.push(segment(w.label.clone().unwrap_or_else(|| "7d".into()), w, now)),
        None if s.provider == Provider::Claude => segments.push(placeholder("7d")),
        None => {}
    }
    Readout { provider: s.provider, segments }
}

fn segment(label: String, w: &Window, now: f64) -> Segment {
    Segment {
        label,
        percent_text: format!("{}%", w.used_percent),
        severity: Severity::from_used(w.used_percent),
        reset_text: w.resets_at.and_then(|r| compact_reset_text(r, now)),
    }
}

fn placeholder(label: &str) -> Segment {
    Segment { label: label.into(), percent_text: "--".into(), severity: Severity::Unknown, reset_text: None }
}

/// "4h 1m", "3d 23h 55m", "12m"; none once the reset has passed.
pub fn compact_reset_text(resets_at: f64, now: f64) -> Option<String> {
    let seconds = (resets_at - now).max(0.0) as i64;
    if seconds <= 0 {
        return None;
    }
    let (days, hours, minutes) = (seconds / 86400, (seconds % 86400) / 3600, (seconds % 3600) / 60);
    Some(if days > 0 {
        format!("{days}d {hours}h {minutes}m")
    } else if hours > 0 {
        format!("{hours}h {minutes}m")
    } else {
        format!("{}m", minutes.max(1))
    })
}

/// "985", "12.3K", "5.7M".
pub fn compact_token_count(n: i64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}K", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}

// ---------------------------------------------------------------- service

struct Latest {
    claude: FieldCache,
    codex: FieldCache,
    refreshed_at: Option<f64>,
}

fn latest() -> &'static Mutex<Latest> {
    static L: OnceLock<Mutex<Latest>> = OnceLock::new();
    L.get_or_init(|| {
        Mutex::new(Latest { claude: FieldCache::new(Provider::Claude), codex: FieldCache::new(Provider::Codex), refreshed_at: None })
    })
}

/// One refresh: read both providers (slow: a subprocess and the session
/// logs), then fold them into the caches under the lock.
pub fn refresh() {
    let started = now();
    let claude = claude_snapshot(
        &ClaudeCacheReader { cache: statusline_cache_path(), stale_interval: CLAUDE_STALE_INTERVAL },
        started,
    );
    let sessions = CodexSessions { root: crate::install::home().join(".codex").join("sessions"), grace: Some(SESSION_FILE_GRACE) };
    let codex_exe = std::env::var("SEAHELM_CODEX_BIN").unwrap_or_else(|_| "codex".into());
    let codex = codex_snapshot(&codex_exe, &sessions, started, CODEX_TIMEOUT);
    let at = now();
    let mut l = latest().lock().unwrap_or_else(|e| e.into_inner());
    let (_, c) = resolve_for_display(&claude, Some(&l.claude), at, CACHE_FALLBACK_MAX_AGE);
    let (_, x) = resolve_for_display(&codex, Some(&l.codex), at, CACHE_FALLBACK_MAX_AGE);
    l.claude = c;
    l.codex = x;
    l.refreshed_at = Some(at);
}

/// The refresh thread: now, then every `REFRESH`.
pub fn spawn() {
    let _ = std::thread::Builder::new().name("core-usage".into()).spawn(|| loop {
        let _ = std::panic::catch_unwind(refresh);
        std::thread::sleep(REFRESH);
    });
}

/// `usage.summary`: both snapshots as they are shown now (each field falls
/// back to its last reading for ten minutes), and the readouts, whose reset
/// countdowns are taken against `now`.
pub fn summary(now: f64) -> Value {
    let l = latest().lock().unwrap_or_else(|e| e.into_inner());
    let claude = l.claude.display(now, CACHE_FALLBACK_MAX_AGE);
    let codex = l.codex.display(now, CACHE_FALLBACK_MAX_AGE);
    json!({
        "claude": claude.to_json(),
        "codex": codex.to_json(),
        "readouts": readouts(&claude, &codex, now).iter().map(Readout::to_json).collect::<Vec<_>>(),
        "codex_today_tokens_text": codex.today_tokens.map(compact_token_count),
        "refreshed_at": l.refreshed_at,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp() -> tempfile::TempDir {
        tempfile::tempdir().unwrap()
    }

    fn set_mtime(path: &Path, at: f64) {
        let f = std::fs::File::options().write(true).open(path).unwrap();
        f.set_modified(UNIX_EPOCH + Duration::from_secs_f64(at)).unwrap();
    }

    // ClaudeUsageSummaryProviderTests

    #[test]
    fn reads_rate_limits_from_statusline_cache() {
        let dir = tmp();
        let cache = dir.path().join("claude-statusline.json");
        std::fs::write(&cache, r#"{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1777270800},"seven_day":{"used_percentage":13,"resets_at":1777759200}}}"#).unwrap();
        set_mtime(&cache, 1_772_516_000.0);
        let r = ClaudeCacheReader { cache, stale_interval: 3600.0 }.read(1_772_516_340.0).unwrap();
        assert_eq!(r.five_hour, Some(Window::new(10, Some(1_777_270_800.0))));
        assert_eq!(r.seven_day, Some(Window::new(13, Some(1_777_759_200.0))));
    }

    #[test]
    fn reads_fractional_second_rate_limit_reset() {
        let dir = tmp();
        let cache = dir.path().join("claude-statusline.json");
        std::fs::write(&cache, r#"{"rate_limits":{"five_hour":{"used_percentage":19,"resets_at":"2026-04-27T12:19:00.123Z"}}}"#).unwrap();
        set_mtime(&cache, 1_772_516_000.0);
        let r = ClaudeCacheReader { cache, stale_interval: 3600.0 }.read(1_772_516_340.0).unwrap();
        let at = r.five_hour.unwrap().resets_at.unwrap();
        assert!((at - (days_from_civil(2026, 4, 27) as f64 * 86400.0 + 12.0 * 3600.0 + 19.0 * 60.0 + 0.123)).abs() < 1e-6);
    }

    #[test]
    fn snapshot_includes_five_hour_and_weekly_rate_limits() {
        let dir = tmp();
        let cache = dir.path().join("claude-statusline.json");
        std::fs::write(&cache, r#"{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1777270800},"seven_day":{"used_percentage":13,"resets_at":1777759200}}}"#).unwrap();
        set_mtime(&cache, 1_772_516_000.0);
        let s = claude_snapshot(&ClaudeCacheReader { cache, stale_interval: 3600.0 }, 1_772_516_340.0);
        assert_eq!(s.rate_limit, Some(Window::new(10, Some(1_777_270_800.0))));
        assert_eq!(s.weekly_rate_limit, Some(Window::new(13, Some(1_777_759_200.0))));
        assert_eq!(s.today_tokens, None);
        assert!(!s.is_stale);
    }

    #[test]
    fn a_stale_cache_reads_as_nothing() {
        let dir = tmp();
        let cache = dir.path().join("claude-statusline.json");
        std::fs::write(&cache, r#"{"rate_limits":{"five_hour":{"used_percentage":10}}}"#).unwrap();
        set_mtime(&cache, 1_000.0);
        let s = claude_snapshot(&ClaudeCacheReader { cache, stale_interval: 3600.0 }, 1_000_000.0);
        assert!(s.is_stale);
        assert_eq!(s.rate_limit, None);
    }

    // CodexUsageSummaryProviderTests

    fn parse(s: &str) -> Option<CodexRateLimits> {
        parse_codex_response(&serde_json::from_str(s).unwrap())
    }

    #[test]
    fn parses_rate_limit_response_preferring_codex_bucket() {
        let p = parse(r#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":80,"resetsAt":1772532000}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":28,"resetsAt":1772532000}}}}}"#).unwrap();
        assert_eq!(p.primary, Some(Window::new(28, Some(1_772_532_000.0))));
    }

    #[test]
    fn falls_back_to_individual_limit_when_rolling_windows_are_null() {
        let p = parse(r#"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":null,"secondary":null,"individualLimit":{"limit":"7500","used":"7505.552985548973","remainingPercent":0,"resetsAt":1785542400},"planType":"business"}}}}"#).unwrap();
        let w = p.primary.unwrap();
        assert_eq!(w.used_percent, 100);
        assert_eq!(w.label.as_deref(), Some("quota"));
        assert_eq!(w.resets_at, Some(1_785_542_400.0));
        assert_eq!(p.secondary, None);
    }

    #[test]
    fn derives_individual_limit_percent_from_used_over_limit_when_remaining_is_absent() {
        let p = parse(r#"{"id":2,"result":{"rateLimits":{"individualLimit":{"limit":"400","used":"100"}}}}"#).unwrap();
        assert_eq!(p.primary.unwrap().used_percent, 25);
    }

    #[test]
    fn parses_secondary_window_and_labels_windows_by_duration() {
        let p = parse(r#"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1785171759},"secondary":{"usedPercent":3,"windowDurationMins":10080,"resetsAt":1785758559}}}}}"#).unwrap();
        assert_eq!(p.primary.unwrap().label.as_deref(), Some("5h"));
        let s = p.secondary.unwrap();
        assert_eq!(s.label.as_deref(), Some("7d"));
        assert_eq!(s.used_percent, 3);
    }

    #[test]
    fn parses_whitespace_json_rpc_response_line_by_id() {
        let p = parse_codex_response_line(r#"{ "id" : 2, "result": { "rateLimits": { "primary": { "usedPercent": 31, "resetsAt": 1772532000 } } } }"#, 2).unwrap();
        assert_eq!(p.primary, Some(Window::new(31, Some(1_772_532_000.0))));
    }

    #[test]
    fn ignores_unexpected_json_rpc_response_line_id() {
        assert_eq!(parse_codex_response_line(r#"{ "id" : 1, "result": { "rateLimits": { "primary": { "usedPercent": 31 } } } }"#, 2), None);
    }

    #[test]
    fn falls_back_to_primary_rate_limits_when_codex_bucket_is_incomplete() {
        let p = parse(r#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":80,"resetsAt":1772532000}},"rateLimitsByLimitId":{"codex":{"primary":{"resetsAt":1772532000}}}}}"#).unwrap();
        assert_eq!(p.primary, Some(Window::new(80, Some(1_772_532_000.0))));
    }

    fn write_lines(path: &Path, lines: &[&str]) {
        std::fs::write(path, lines.join("\n")).unwrap();
    }

    fn at(s: &str) -> f64 {
        parse_iso8601(s).unwrap()
    }

    #[test]
    fn aggregates_session_token_deltas_for_local_day() {
        let dir = tmp();
        write_lines(&dir.path().join("rollout-today.jsonl"), &[
            r#"{"timestamp":"2026-04-27T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":999999},"last_token_usage":{"total_tokens":100}}}}"#,
            r#"{"timestamp":"2026-04-27T02:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":50}}}}"#,
            r#"{"timestamp":"2026-04-27T03:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            r#"{"timestamp":"2026-04-26T23:59:59Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1000}}}}"#,
        ]);
        let s = CodexSessions { root: dir.path().into(), grace: None };
        assert_eq!(s.today_tokens(at("2026-04-27T08:00:00Z"), 0), Some(150));
    }

    #[test]
    fn aggregates_session_token_deltas_with_non_utc_local_day_bounds() {
        let dir = tmp();
        write_lines(&dir.path().join("rollout-today.jsonl"), &[
            r#"{"timestamp":"2026-04-26T15:59:59Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1000}}}}"#,
            r#"{"timestamp":"2026-04-26T16:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":25}}}}"#,
            r#"{"timestamp":"2026-04-27T15:59:59Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":75}}}}"#,
            r#"{"timestamp":"2026-04-27T16:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1000}}}}"#,
        ]);
        let s = CodexSessions { root: dir.path().into(), grace: None };
        assert_eq!(s.today_tokens(at("2026-04-27T08:00:00Z"), 8 * 3600), Some(100));
    }

    #[test]
    fn missing_session_root_throws_instead_of_reporting_zero() {
        let s = CodexSessions { root: PathBuf::from("/nonexistent/seahelm-test-sessions"), grace: None };
        assert_eq!(s.today_tokens(at("2026-04-27T08:00:00Z"), 0), None);
    }

    #[test]
    fn skips_session_files_older_than_modification_grace_interval() {
        let dir = tmp();
        let stale = dir.path().join("stale.jsonl");
        let current = dir.path().join("sub").join("current.jsonl");
        std::fs::create_dir_all(current.parent().unwrap()).unwrap();
        write_lines(&stale, &[r#"{"timestamp":"2026-04-27T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1000}}}}"#]);
        write_lines(&current, &[r#"{"timestamp":"2026-04-27T02:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":25}}}}"#]);
        set_mtime(&stale, at("2026-04-25T00:00:00Z"));
        set_mtime(&current, at("2026-04-27T02:00:00Z"));
        let s = CodexSessions { root: dir.path().into(), grace: Some(86400.0) };
        assert_eq!(s.today_tokens(at("2026-04-27T08:00:00Z"), 0), Some(25));
    }

    #[cfg(unix)]
    fn fake_codex(dir: &Path, body: &str) -> String {
        use std::os::unix::fs::PermissionsExt;
        let p = dir.join("codex");
        std::fs::write(&p, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        p.to_string_lossy().into_owned()
    }

    #[cfg(unix)]
    #[test]
    fn snapshot_does_not_report_missing_session_root_as_zero() {
        let dir = tmp();
        let exe = fake_codex(dir.path(), r#"printf '%s\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":42}}}}'
cat >/dev/null"#);
        let sessions = CodexSessions { root: dir.path().join("missing"), grace: None };
        let s = codex_snapshot(&exe, &sessions, at("2026-04-27T08:00:00Z"), Duration::from_secs(5));
        assert_eq!(s.rate_limit.map(|w| w.used_percent), Some(42));
        assert_eq!(s.today_tokens, None);
        assert!(!s.is_stale);
    }

    #[cfg(unix)]
    #[test]
    fn keeps_stdin_open_until_the_answer_arrives() {
        let dir = tmp();
        let marker = dir.path().join("stdin-closed");
        let exe = fake_codex(dir.path(), &format!(
            "exec 3<&0\n( cat <&3 >/dev/null; : > '{}' ) &\nsleep 0.5\nprintf '%s\\n' '{{\"id\":2,\"result\":{{\"rateLimits\":{{\"primary\":{{\"usedPercent\":42}}}}}}}}'\nsleep 5",
            marker.display()
        ));
        let started = now();
        let p = read_codex_rate_limits(&exe, Duration::from_secs(5));
        assert_eq!(p.and_then(|p| p.primary).map(|w| w.used_percent), Some(42));
        // Closing stdin once the answer is in lets the fake's drain finish;
        // what must not happen is stdin closing before it (0.5 s in).
        std::thread::sleep(Duration::from_millis(100));
        if let Some(closed) = file_mtime(&marker) {
            assert!(closed >= started + 0.4, "stdin was closed before the answer arrived");
        }
    }

    #[cfg(unix)]
    #[test]
    fn resolves_executable_outside_of_path() {
        assert_eq!(resolve_executable("/nonexistent/codex"), None);
        assert_eq!(resolve_executable("definitely-not-a-real-binary-xyz"), None);
        assert_eq!(resolve_executable("/bin/sh"), Some(PathBuf::from("/bin/sh")));
    }

    #[test]
    fn missing_executable_returns_nil_without_spawning() {
        assert_eq!(read_codex_rate_limits("definitely-not-a-real-binary-xyz", Duration::from_millis(100)), None);
    }

    #[cfg(unix)]
    #[test]
    fn read_rate_limit_times_out_and_terminates_slow_codex_process() {
        let dir = tmp();
        let exe = fake_codex(dir.path(), "sleep 5");
        let started = std::time::Instant::now();
        assert_eq!(read_codex_rate_limits(&exe, Duration::from_millis(100)), None);
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    // UsageReadoutTests

    fn claude(five: i64, seven: i64) -> Snapshot {
        Snapshot {
            provider: Provider::Claude,
            rate_limit: Some(Window::new(five, Some(14_460.0))),
            weekly_rate_limit: Some(Window::new(seven, Some(21_660.0))),
            today_tokens: Some(1_000),
            updated_at: Some(0.0),
            is_stale: false,
        }
    }

    #[test]
    fn claude_readout_carries_both_windows_with_reset_countdowns() {
        let r = readout(&claude(11, 2), 0.0);
        assert_eq!(r.provider, Provider::Claude);
        assert_eq!(r.segments.iter().map(|s| s.label.as_str()).collect::<Vec<_>>(), ["5h", "7d"]);
        assert_eq!(r.segments.iter().map(|s| s.percent_text.as_str()).collect::<Vec<_>>(), ["11%", "2%"]);
        assert_eq!(r.segments.iter().map(|s| s.reset_text.clone()).collect::<Vec<_>>(), [Some("4h 1m".into()), Some("6h 1m".into())]);
        assert_eq!(r.segments.iter().map(|s| s.severity).collect::<Vec<_>>(), [Severity::Ok, Severity::Ok]);
    }

    #[test]
    fn severity_escalates_with_usage() {
        assert_eq!(Severity::from_used(0), Severity::Ok);
        assert_eq!(Severity::from_used(59), Severity::Ok);
        assert_eq!(Severity::from_used(60), Severity::Warn);
        assert_eq!(Severity::from_used(84), Severity::Warn);
        assert_eq!(Severity::from_used(85), Severity::Critical);
        assert_eq!(Severity::from_used(100), Severity::Critical);
    }

    #[test]
    fn provider_without_rate_limits_uses_placeholder_readout() {
        let empty = Snapshot::empty(Provider::Codex);
        let r = readout(&empty, 0.0);
        assert_eq!(r.segments.len(), 1);
        assert_eq!(r.segments[0].label, "quota");
        assert_eq!(r.segments[0].percent_text, "--");
        assert_eq!(r.segments[0].severity, Severity::Unknown);
        let all = readouts(&claude(11, 2), &empty, 0.0);
        assert_eq!(all.iter().map(|r| r.provider).collect::<Vec<_>>(), [Provider::Claude, Provider::Codex]);
    }

    // UsageSummaryFormatterTests (the readout half; the island frames stay in the app)

    #[test]
    fn compacts_large_token_counts() {
        assert_eq!(compact_token_count(985), "985");
        assert_eq!(compact_token_count(12_340), "12.3K");
        assert_eq!(compact_token_count(5_745_705), "5.7M");
    }

    #[test]
    fn reset_text_reads_as_the_app_writes_it() {
        assert_eq!(compact_reset_text(1_772_532_000.0, 1_772_523_660.0).as_deref(), Some("2h 19m"));
        assert_eq!(compact_reset_text(11_460.0, 0.0).as_deref(), Some("3h 11m"));
        assert_eq!(compact_reset_text(0.0 + 3.0 * 86400.0 + 23.0 * 3600.0 + 55.0 * 60.0, 0.0).as_deref(), Some("3d 23h 55m"));
        assert_eq!(compact_reset_text(30.0, 0.0).as_deref(), Some("1m"));
        assert_eq!(compact_reset_text(10.0, 20.0), None);
    }

    // UsageSummaryStoreTests

    #[test]
    fn resolve_snapshot_keeps_cached_rate_limit_when_refresh_misses_it() {
        let mut cache = FieldCache::new(Provider::Claude);
        let cached = Snapshot {
            provider: Provider::Claude,
            rate_limit: Some(Window::new(19, Some(1_772_532_000.0))),
            weekly_rate_limit: None,
            today_tokens: Some(120_000),
            updated_at: Some(1_772_523_000.0),
            is_stale: false,
        };
        cache.ingest(&cached, 1_772_523_000.0);
        let candidate = Snapshot { rate_limit: None, today_tokens: Some(130_000), updated_at: Some(1_772_523_600.0), is_stale: true, ..cached.clone() };
        let (s, _) = resolve_for_display(&candidate, Some(&cache), 1_772_523_600.0, 600.0);
        assert_eq!(s.rate_limit, cached.rate_limit);
        assert_eq!(s.today_tokens, Some(130_000));
        assert_eq!(s.updated_at, candidate.updated_at);
        assert!(s.is_stale);
    }

    #[test]
    fn resolve_snapshot_keeps_cached_weekly_rate_limit_when_refresh_misses_it() {
        let mut cache = FieldCache::new(Provider::Claude);
        let cached = Snapshot {
            provider: Provider::Claude,
            rate_limit: Some(Window::new(10, Some(1_777_270_800.0))),
            weekly_rate_limit: Some(Window::new(13, Some(1_777_759_200.0))),
            today_tokens: None,
            updated_at: Some(1_772_523_000.0),
            is_stale: false,
        };
        cache.ingest(&cached, 1_772_523_000.0);
        let candidate = Snapshot { weekly_rate_limit: None, updated_at: Some(1_772_523_600.0), ..cached.clone() };
        let (s, _) = resolve_for_display(&candidate, Some(&cache), 1_772_523_600.0, 600.0);
        assert_eq!(s.rate_limit, candidate.rate_limit);
        assert_eq!(s.weekly_rate_limit, cached.weekly_rate_limit);
        assert_eq!(s.updated_at, candidate.updated_at);
        assert!(!s.is_stale);
    }

    #[test]
    fn resolve_snapshot_keeps_cached_today_tokens_when_refresh_misses_them() {
        let now = 1_772_523_600.0;
        // Same local day for both readings whatever the zone: ten minutes apart, mid-day.
        let noon = day_start(now, local_offset(now)) + 12.0 * 3600.0;
        let mut cache = FieldCache::new(Provider::Codex);
        let cached = Snapshot {
            provider: Provider::Codex,
            rate_limit: Some(Window::new(40, None)),
            weekly_rate_limit: None,
            today_tokens: Some(34_000),
            updated_at: Some(noon),
            is_stale: false,
        };
        cache.ingest(&cached, noon);
        let candidate = Snapshot { rate_limit: Some(Window::new(42, None)), today_tokens: None, updated_at: Some(noon + 600.0), ..cached.clone() };
        let (s, _) = resolve_for_display(&candidate, Some(&cache), noon + 600.0, 600.0);
        assert_eq!(s.rate_limit, candidate.rate_limit);
        assert_eq!(s.today_tokens, Some(34_000));
        assert_eq!(s.updated_at, candidate.updated_at);
        assert!(!s.is_stale);
    }

    #[test]
    fn resolve_snapshot_expires_cached_fields_after_max_age() {
        let mut cache = FieldCache::new(Provider::Claude);
        cache.ingest(
            &Snapshot {
                provider: Provider::Claude,
                rate_limit: Some(Window::new(19, None)),
                weekly_rate_limit: None,
                today_tokens: Some(120_000),
                updated_at: Some(1_772_523_000.0),
                is_stale: false,
            },
            1_772_523_000.0,
        );
        let candidate = Snapshot { updated_at: Some(1_772_524_000.0), ..Snapshot::empty(Provider::Claude) };
        let (s, _) = resolve_for_display(&candidate, Some(&cache), 1_772_524_000.0, 600.0);
        assert_eq!(s.rate_limit, None);
        assert_eq!(s.today_tokens, None);
        assert_eq!(s.updated_at, None);
        assert!(s.is_stale);
    }

    #[test]
    fn resolve_snapshot_does_not_carry_today_tokens_across_local_day_boundary() {
        let base = 1_772_524_800.0;
        let next_day = day_start(base, local_offset(base)) + 86400.0;
        let cached_at = next_day - 60.0;
        let now = next_day + 60.0;
        let mut cache = FieldCache::new(Provider::Codex);
        cache.ingest(
            &Snapshot {
                provider: Provider::Codex,
                rate_limit: Some(Window::new(40, None)),
                weekly_rate_limit: None,
                today_tokens: Some(34_000),
                updated_at: Some(cached_at),
                is_stale: false,
            },
            cached_at,
        );
        let candidate = Snapshot {
            provider: Provider::Codex,
            rate_limit: Some(Window::new(42, None)),
            weekly_rate_limit: None,
            today_tokens: None,
            updated_at: Some(now),
            is_stale: false,
        };
        let (s, _) = resolve_for_display(&candidate, Some(&cache), now, 600.0);
        assert_eq!(s.rate_limit, candidate.rate_limit);
        assert_eq!(s.today_tokens, None);
        assert_eq!(s.updated_at, Some(now));
        assert!(!s.is_stale);
    }

    #[test]
    fn iso8601_takes_zones_and_fractions() {
        assert_eq!(parse_iso8601("1970-01-01T00:00:00Z"), Some(0.0));
        assert_eq!(parse_iso8601("1970-01-01T08:00:00+08:00"), Some(0.0));
        assert_eq!(parse_iso8601("2026-04-27T08:00:00Z"), Some(days_from_civil(2026, 4, 27) as f64 * 86400.0 + 8.0 * 3600.0));
        assert_eq!(parse_iso8601("1970-01-01T00:00:01.5Z"), Some(1.5));
        assert_eq!(parse_iso8601("not a date"), None);
        assert_eq!(day_start(at("2026-04-27T08:00:00Z"), 8 * 3600), at("2026-04-26T16:00:00Z"));
    }
}

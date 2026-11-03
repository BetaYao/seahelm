//! The daemon end to end, through the real binary and its socket.

use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

use keep_vt::{Format, Terminal};
use seahelmd::proto::{self, Msg};

static NEXT: AtomicU32 = AtomicU32::new(0);

/// A socket directory of the test's own (short: socket paths cap near 104).
struct Dir(PathBuf);

impl Dir {
    fn new() -> Self {
        let dir = PathBuf::from(format!("/tmp/shd-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::SeqCst)));
        let _ = std::fs::remove_dir_all(&dir);
        Dir(dir)
    }

    fn cli(&self, args: &[&str], env: &[(&str, &str)]) -> std::process::Output {
        let mut c = Command::new(env!("CARGO_BIN_EXE_seahelmd"));
        c.args(args).env("SEAHELMD_DIR", &self.0).env_remove("SEAHELMD_FACTS");
        for (k, v) in env {
            c.env(k, v);
        }
        c.output().expect("run seahelmd")
    }

    fn connect(&self, name: &str) -> UnixStream {
        UnixStream::connect(self.0.join(name)).expect("connect")
    }

    fn history(&self, name: &str) -> String {
        String::from_utf8_lossy(&self.cli(&["history", name], &[]).stdout).into_owned()
    }

    fn wait_for(&self, name: &str, needle: &str) -> String {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let h = self.history(name);
            if h.contains(needle) {
                return h;
            }
            assert!(Instant::now() < deadline, "never saw {needle:?}; history:\n{h}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        if let Ok(entries) = std::fs::read_dir(&self.0) {
            for e in entries.flatten() {
                if let Some(name) = e.file_name().to_str() {
                    if !name.ends_with(".log") {
                        let _ = self.cli(&["kill", name], &[]);
                    }
                }
            }
        }
        std::thread::sleep(Duration::from_millis(200));
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A client that keeps its own copy of the screen from what it is sent,
/// exactly as the attach client writes it to its terminal.
struct Mirror {
    sock: UnixStream,
    term: Terminal,
    repaints: usize,
}

impl Mirror {
    fn attach(dir: &Dir, name: &str, cols: u16, rows: u16) -> Self {
        let mut sock = dir.connect(name);
        proto::write(&mut sock, &Msg::Attach { cols, rows }).unwrap();
        let mut m = Mirror { sock, term: Terminal::new(cols, rows).unwrap(), repaints: 0 };
        m.pump_one(Duration::from_secs(5)).expect("a repaint first");
        assert_eq!(m.repaints, 1, "the first thing an attach gets is the screen");
        m
    }

    /// Take one message into the mirror; None on timeout.
    fn pump_one(&mut self, timeout: Duration) -> Option<Msg> {
        self.sock.set_read_timeout(Some(timeout)).unwrap();
        let msg = proto::read(&mut self.sock).ok()??;
        match &msg {
            Msg::Repaint(data) => {
                self.repaints += 1;
                self.term.write(b"\x1b[H\x1b[2J");
                self.term.write(data);
            }
            Msg::Output(data) => self.term.write(data),
            _ => {}
        }
        Some(msg)
    }

    fn pump_until_quiet(&mut self) {
        while self.pump_one(Duration::from_millis(400)).is_some() {}
    }

    fn text(&self) -> String {
        self.term.text().unwrap()
    }

    fn html(&self) -> String {
        String::from_utf8(self.term.snapshot(Format::Html).unwrap()).unwrap()
    }
}

/// A screen only libghostty-vt gets right by replaying it: colours, a line
/// longer than the window (soft wrap), a scrolled history, then a full-screen
/// program on the alternate screen with its own colours and cursor position.
const DRAW: &str = r#"
sleep 0.8
for i in $(seq 1 60); do printf '\033[3%dmline %02d\033[0m %s\n' $((i % 7 + 1)) $i "$(printf 'x%.0s' $(seq 1 $((i * 3))))"; done
printf '\033[1;4mbold underline\033[0m \033]8;;https://seahelm.dev\033\\link\033]8;;\033\\\n'
printf '\033[?1049h\033[2J\033[H\033[44;97m FULL SCREEN \033[0m\n\n   \033[38;2;255;128;0mtruecolor\033[0m 中文宽字符 done-marker'
printf '\033[5;10H'
sleep 30
"#;

#[test]
fn a_late_attach_sees_exactly_what_an_early_one_saw() {
    let dir = Dir::new();
    let out = dir.cli(&["new", "fid", "bash", "--norc", "-c", DRAW], &[]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));

    let mut early = Mirror::attach(&dir, "fid", 100, 30);
    dir.wait_for("fid", "done-marker");
    early.pump_until_quiet();

    let late = Mirror::attach(&dir, "fid", 100, 30);
    assert!(early.text().contains("FULL SCREEN"), "early:\n{}", early.text());
    assert_eq!(late.text(), early.text(), "the text on screen");
    assert_eq!(late.html(), early.html(), "colours, styles and links on screen");
}

#[test]
fn leaving_the_full_screen_program_restores_the_history_under_it() {
    // The repaint must carry the main screen too, or the shell's history is
    // gone when the program exits.
    let dir = Dir::new();
    let script = "printf 'kept-before\\n'; sleep 0.8; printf '\\033[?1049hFULL'; sleep 1.5; printf '\\033[?1049lback-marker\\n'; sleep 30";
    dir.cli(&["new", "alt", "bash", "--norc", "-c", script], &[]);
    dir.wait_for("alt", "FULL");
    let mut late = Mirror::attach(&dir, "alt", 80, 24);
    let deadline = Instant::now() + Duration::from_secs(5);
    while !late.text().contains("back-marker") {
        assert!(Instant::now() < deadline, "never left the full screen:\n{}", late.text());
        late.pump_one(Duration::from_millis(500));
    }
    assert!(late.text().contains("kept-before"), "the main screen came back empty:\n{}", late.text());
}

/// Ask the terminal its background, wait for the answer, print what came.
const ASK_BG: &str = r#"
sleep 0.5
printf '\033]11;?\a'
IFS= read -r -s -t 2 -d $'\a' reply
printf '\nANSWER[%s]\n' "${reply#$'\033'}"
sleep 30
"#;

#[test]
fn a_program_started_with_nobody_attached_is_told_the_palette() {
    let dir = Dir::new();
    dir.cli(&["new", "bg", "bash", "--norc", "-c", ASK_BG], &[("SEAHELMD_FACTS", "fg=cdd6f4 bg=1e1e2e dark=1")]);
    let h = dir.wait_for("bg", "ANSWER[");
    assert!(h.contains("rgb:1e1e/1e1e/2e2e"), "history:\n{h}");
}

#[test]
fn with_a_client_attached_the_daemon_leaves_the_answer_to_it() {
    // Two answers to one question are one too many: the attached terminal
    // answers. This client does not, so the program must hear nothing.
    let dir = Dir::new();
    dir.cli(&["new", "quiet", "bash", "--norc", "-c", ASK_BG], &[("SEAHELMD_FACTS", "bg=1e1e2e")]);
    let mut client = Mirror::attach(&dir, "quiet", 80, 24);
    let h = dir.wait_for("quiet", "ANSWER[");
    client.pump_until_quiet();
    assert!(h.contains("ANSWER[]"), "the daemon answered over an attached client:\n{h}");
    let raw = client.html();
    assert!(raw.contains("ANSWER[]"), "the attached client saw the program's output:\n{raw}");
}

#[test]
fn a_client_that_stops_reading_is_repainted_not_flooded() {
    let dir = Dir::new();
    // ~20 MB of output, far past the 64-chunk backlog, then a final screen.
    let script = "sleep 0.5; yes 'flood flood flood flood flood flood flood flood' | head -c 20000000; printf '\\033[2J\\033[Hflood-done\\n'; sleep 30";
    dir.cli(&["new", "flood", "bash", "--norc", "-c", script], &[]);
    let mut slow = Mirror::attach(&dir, "flood", 80, 24);
    // Not reading while the flood runs.
    dir.wait_for("flood", "flood-done");
    let deadline = Instant::now() + Duration::from_secs(20);
    while !slow.text().contains("flood-done") {
        assert!(Instant::now() < deadline, "the slow client never caught up");
        slow.pump_one(Duration::from_millis(500));
    }
    assert!(slow.repaints >= 2, "caught up by streaming everything instead of a repaint");
}

#[test]
fn when_the_program_exits_the_client_hears_it_and_the_session_is_gone() {
    let dir = Dir::new();
    dir.cli(&["new", "brief", "bash", "--norc", "-c", "sleep 0.8; echo bye"], &[]);
    let mut client = Mirror::attach(&dir, "brief", 80, 24);
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match client.pump_one(Duration::from_millis(500)) {
            Some(Msg::Ended) => break,
            _ => assert!(Instant::now() < deadline, "never heard the end"),
        }
    }
    std::thread::sleep(Duration::from_millis(100));
    let list = String::from_utf8_lossy(&dir.cli(&["list"], &[]).stdout).into_owned();
    assert!(!list.contains("name=brief"), "{list}");
}

#[test]
fn run_types_the_command_into_the_session_shell_quoted() {
    let dir = Dir::new();
    // A new session is the user's shell, and the command is typed into it.
    dir.cli(&["run", "typed", "echo", "first run"], &[("SHELL", "/bin/bash")]);
    dir.wait_for("typed", "first run");
    // On a live session, the same: typed, each argument quoted only if needed.
    dir.cli(&["run", "typed", "printf", "%s|%s\\n", "a b", "it's"], &[]);
    dir.wait_for("typed", "a b|it's");
    // The shell outlives the command.
    let list = String::from_utf8_lossy(&dir.cli(&["list"], &[]).stdout).into_owned();
    assert!(list.contains("name=typed\t"), "{list}");
    assert!(list.trim_end().ends_with(&format!("start_dir={}", std::env::current_dir().unwrap().display())), "{list}");
}

#[test]
fn a_daemon_that_does_not_answer_is_listed_unreachable_and_kept() {
    let dir = Dir::new();
    dir.cli(&["new", "hung", "sleep", "30"], &[]);
    let socket = dir.0.join("hung");
    // Stop the daemon: its socket is there, nobody answers.
    let daemon_pid = std::process::Command::new("lsof").arg("-t").arg(&socket).output().unwrap();
    let pids: Vec<i32> = String::from_utf8_lossy(&daemon_pid.stdout).lines().filter_map(|l| l.trim().parse().ok()).collect();
    assert!(!pids.is_empty());
    for p in &pids {
        unsafe { libc::kill(*p, libc::SIGSTOP) };
    }
    let list = String::from_utf8_lossy(&dir.cli(&["list"], &[]).stdout).into_owned();
    for p in &pids {
        unsafe { libc::kill(*p, libc::SIGCONT) };
    }
    assert!(list.contains("name=hung\tstatus=unreachable"), "{list}");
    assert!(socket.exists(), "a busy daemon's socket was removed");
}

#[test]
fn a_late_attach_mid_full_screen_leaves_the_grid_where_the_program_thinks_it_is() {
    // The handover reads the main screen from under the alternate one and the
    // grid is rebuilt from it. The program, still on the alternate screen,
    // carries on drawing and leaves; every view must agree afterwards.
    let dir = Dir::new();
    let script = "printf 'shell-line\\n'; sleep 0.8; printf '\\033[?1049h\\033[Hfirst'; sleep 1.2; printf '\\033[3;1Hsecond'; sleep 0.5; printf '\\033[?1049lafter-marker\\n'; sleep 30";
    dir.cli(&["new", "mid", "bash", "--norc", "-c", script], &[]);
    let mut early = Mirror::attach(&dir, "mid", 80, 24);
    dir.wait_for("mid", "first");
    let mut middle = Mirror::attach(&dir, "mid", 80, 24); // rebuilds the grid
    dir.wait_for("mid", "after-marker");
    early.pump_until_quiet();
    middle.pump_until_quiet();
    let late = Mirror::attach(&dir, "mid", 80, 24);
    assert!(early.text().contains("after-marker") && early.text().contains("shell-line"), "{}", early.text());
    assert!(!early.text().contains("second"), "the alternate screen leaked onto the main one:\n{}", early.text());
    assert_eq!(middle.text(), early.text(), "a client attached mid full-screen");
    assert_eq!(late.text(), early.text(), "a client attached after the rebuild");
}

#[test]
fn attaching_to_a_long_history_is_quick() {
    let dir = Dir::new();
    // ~200k lines of scrollback, the size of a long agent session.
    let script = "seq 1 200000 | sed 's/^/history line /'; echo long-done; sleep 30";
    dir.cli(&["new", "long", "bash", "--norc", "-c", script], &[]);
    dir.wait_for("long", "long-done");
    let started = Instant::now();
    let mut sock = dir.connect("long");
    proto::write(&mut sock, &Msg::Attach { cols: 120, rows: 40 }).unwrap();
    let Some(Msg::Repaint(data)) = proto::read(&mut sock).unwrap() else { panic!("no repaint") };
    let took = started.elapsed();
    eprintln!("handover of {} bytes in {:?}", data.len(), took);
    assert!(took < Duration::from_secs(2), "attach took {took:?}");
}

fn pid_of(dir: &Dir, name: &str) -> Option<String> {
    let list = String::from_utf8_lossy(&dir.cli(&["list"], &[]).stdout).into_owned();
    let row = list.lines().find(|l| l.starts_with(&format!("name={name}\t")))?.to_string();
    let pid = row.split('\t').find_map(|f| f.strip_prefix("pid="))?.to_string();
    Some(pid)
}

#[test]
fn a_held_program_starts_when_the_pane_attaches_at_the_panes_size() {
    let dir = Dir::new();
    let out = dir.cli(&["new", "--hold", "10", "held", "--", "bash", "--norc", "-c", "echo \"size=$(stty size)\"; sleep 30"], &[]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    std::thread::sleep(Duration::from_millis(500));
    // Listed (so seahelm sees it exists) but nothing running yet.
    assert_eq!(pid_of(&dir, "held").as_deref(), Some(""), "the program started before anyone attached");
    let mut pane = Mirror::attach(&dir, "held", 132, 41);
    let deadline = Instant::now() + Duration::from_secs(5);
    while !pane.text().contains("size=") {
        assert!(Instant::now() < deadline, "never drew:\n{}", pane.text());
        pane.pump_one(Duration::from_millis(300));
    }
    assert!(pane.text().contains("size=41 132"), "first frame not at the pane's size:\n{}", pane.text());
}

#[test]
fn a_held_program_starts_anyway_when_nobody_comes() {
    let dir = Dir::new();
    dir.cli(&["new", "--hold", "0.5", "lonely", "--", "bash", "--norc", "-c", "echo started-alone; sleep 30"], &[]);
    let h = dir.wait_for("lonely", "started-alone");
    assert!(!h.is_empty());
    assert!(pid_of(&dir, "lonely").is_some_and(|p| !p.is_empty()));
}

#[test]
fn killing_a_held_session_leaves_nothing() {
    let dir = Dir::new();
    dir.cli(&["new", "--hold", "30", "never", "--", "sleep", "30"], &[]);
    std::thread::sleep(Duration::from_millis(300));
    assert!(dir.cli(&["kill", "never"], &[]).status.success());
    std::thread::sleep(Duration::from_millis(300));
    let list = String::from_utf8_lossy(&dir.cli(&["list"], &[]).stdout).into_owned();
    assert!(!list.contains("name=never"), "{list}");
    assert!(!dir.0.join("never").exists());
}

impl Dir {
    fn snapshot(&self, name: &str) -> String {
        String::from_utf8_lossy(&self.cli(&["snapshot", name], &[]).stdout).into_owned()
    }

    fn wait_for_snapshot(&self, name: &str, needle: &str) -> String {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let s = self.snapshot(name);
            if s.contains(needle) {
                return s;
            }
            assert!(Instant::now() < deadline, "snapshot never had {needle:?}:\n{s}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

/// The number after `"key":` in a snapshot.
fn snapshot_num(json: &str, key: &str) -> i64 {
    let at = json.find(&format!("\"{key}\":")).unwrap_or_else(|| panic!("no {key} in {json}"));
    json[at + key.len() + 3..].chars().take_while(|c| c.is_ascii_digit() || *c == '-').collect::<String>().parse().unwrap()
}

#[test]
fn a_snapshot_is_the_visible_screen_and_what_the_program_said_beside_it() {
    let dir = Dir::new();
    let script = "printf '\\033]2;my-title\\a'; for i in $(seq 1 80); do echo scrolled-$i; done; \
                  printf '\\033]9;4;1;40\\a'; echo visible-marker; sleep 30";
    dir.cli(&["new", "snap", "bash", "--norc", "-c", script], &[]);
    let s = dir.wait_for_snapshot("snap", "visible-marker");
    assert!(s.contains(r#""title":"my-title""#), "{s}");
    assert!(s.contains(r#""progress":{"state":1,"percent":40}"#), "{s}");
    assert!(s.contains(r#""alt_screen":false"#), "{s}");
    assert!(s.contains(r#""rows":24"#) && s.contains(r#""cols":80"#), "{s}");
    assert!(!s.contains("scrolled-1\\n"), "history is not the viewport: {s}");
    assert!(s.contains("scrolled-80"), "{s}");
    // Nothing new was drawn, so a poller can skip the screen.
    let g = snapshot_num(&s, "generation");
    assert!(g > 0, "{s}");
    assert_eq!(snapshot_num(&dir.snapshot("snap"), "generation"), g, "generation moves only with output");
}

#[test]
fn a_held_session_snapshots_as_not_started() {
    let dir = Dir::new();
    dir.cli(&["new", "--hold", "20", "held", "--", "bash", "--norc", "-c", "echo hi; sleep 30"], &[]);
    assert_eq!(dir.snapshot("held").trim(), r#"{"started":false}"#);
}

/// Ask for OSC 7501 support, print the answer, then report working; later
/// hand the terminal back (OSC 133 D).
const PROGRAM_STATUS: &str = r#"
sleep 0.3
printf '\033]7501;?\a'
IFS= read -r -s -t 2 -d $'\a' reply
printf '\nREPLY[%s]\n' "${reply#$'\033'}"
printf '\033]7501;state=working:app=claude-code:msg=UGxhbg\033\\'
printf 'reported\n'
sleep 1.5
printf '\033]133;D;0\a'
printf 'returned\n'
sleep 30
"#;

#[test]
fn program_status_is_answered_kept_and_ended_by_the_shell_returning() {
    let dir = Dir::new();
    dir.cli(&["new", "ps", "bash", "--norc", "-c", PROGRAM_STATUS], &[]);
    let h = dir.wait_for("ps", "REPLY[");
    assert!(h.contains("REPLY[]7501;?:states=idle,working,done,blocked,error"), "the daemon answers while nobody is attached:\n{h}");
    let s = dir.wait_for_snapshot("ps", r#""state":"working""#);
    assert!(s.contains(r#""app":"claude-code""#) && s.contains(r#""msg":"Plan""#), "{s}");
    let seq = snapshot_num(&s, "program_seq");
    let s = dir.wait_for_snapshot("ps", r#""program":null"#);
    assert!(snapshot_num(&s, "program_seq") > seq, "the end of the record is a change a poller sees: {s}");
}

#[test]
fn with_a_client_attached_the_daemon_leaves_the_7501_query_to_it() {
    let dir = Dir::new();
    dir.cli(&["new", "ps2", "bash", "--norc", "-c", PROGRAM_STATUS], &[]);
    let mut client = Mirror::attach(&dir, "ps2", 80, 24);
    let h = dir.wait_for("ps2", "REPLY[");
    client.pump_until_quiet();
    assert!(h.contains("REPLY[]"), "the daemon answered over an attached client:\n{h}");
}

/// Ask for 7501 support and DA1 in one write, as Claude Code does, and print
/// how the first answer starts.
const ASK_7501_AND_DA1: &str = r#"
sleep 0.3
printf '\033]7501;?\033\\\033[c'
IFS= read -r -s -n 3 first
printf '\nFIRST[%s]\n' "${first#$'\033'}"
sleep 30
"#;

#[test]
fn the_7501_answer_comes_before_da1_as_its_query_did() {
    let dir = Dir::new();
    dir.cli(&["new", "order", "bash", "--norc", "-c", ASK_7501_AND_DA1], &[]);
    let h = dir.wait_for("order", "FIRST[");
    assert!(h.contains("FIRST[]7]"), "DA1 was answered first, so the program gives up on 7501:\n{h}");
}

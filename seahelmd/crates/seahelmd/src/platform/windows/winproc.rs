// Taken from Keep (https://github.com/ttwwnn/keep @ e944802, `crates/keepd/src/winproc.rs`),
// MIT, Copyright (c) the Keep authors — see crates/keep-vt/LICENSE-keep.

//! What a tab is running, asked of Windows.
//!
//! Unix answers this with the terminal's foreground process group; Windows
//! has no such thing. What it has is the process tree: a shell waiting at its
//! prompt has no children, and a command it runs is its child. So the newest
//! child of the shell plays the part the foreground group plays elsewhere —
//! the command, while one runs, and nobody while the shell waits.
//!
//! The working directory has no system call either. Every process keeps its
//! own in its parameters block, reachable through its PEB, which is where
//! Process Explorer reads it from and where this does too: it needs no shell
//! setup, and it follows a `cd` the moment it happens.

use std::ffi::c_void;

use windows_sys::Wdk::System::Threading::{NtQueryInformationProcess, ProcessBasicInformation};
use windows_sys::Win32::Foundation::{CloseHandle, FILETIME, HANDLE, INVALID_HANDLE_VALUE};
use windows_sys::Win32::System::Diagnostics::Debug::ReadProcessMemory;
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW,
    TH32CS_SNAPPROCESS,
};
use windows_sys::Win32::System::Threading::{
    GetProcessTimes, IsWow64Process, OpenProcess, PROCESS_BASIC_INFORMATION,
    PROCESS_QUERY_INFORMATION, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_VM_READ,
};

struct Handle(HANDLE);

impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
    }
}

fn open(pid: u32, access: u32) -> Option<Handle> {
    let handle = unsafe { OpenProcess(access, 0, pid) };
    (!handle.is_null()).then_some(Handle(handle))
}

/// One row of the system's process list.
struct Entry {
    pid: u32,
    parent: u32,
    exe: String,
}

/// The process list, taken at most every quarter second: a workspace list
/// asks each tab three questions of it, and a list of twenty tabs would
/// otherwise take sixty snapshots of every process on the machine.
fn processes() -> std::sync::Arc<Vec<Entry>> {
    use std::sync::{Arc, Mutex, OnceLock};
    use std::time::{Duration, Instant};
    static CACHE: OnceLock<Mutex<Option<(Instant, Arc<Vec<Entry>>)>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(None));
    if let Ok(guard) = cache.lock() {
        if let Some((at, list)) = guard.as_ref() {
            if at.elapsed() < Duration::from_millis(250) {
                return Arc::clone(list);
            }
        }
    }
    let fresh = Arc::new(take_processes());
    if let Ok(mut guard) = cache.lock() {
        *guard = Some((Instant::now(), Arc::clone(&fresh)));
    }
    fresh
}

fn take_processes() -> Vec<Entry> {
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
    if snapshot == INVALID_HANDLE_VALUE {
        return Vec::new();
    }
    let snapshot = Handle(snapshot);
    let mut entry: PROCESSENTRY32W = unsafe { std::mem::zeroed() };
    entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
    let mut out = Vec::new();
    let mut more = unsafe { Process32FirstW(snapshot.0, &mut entry) } != 0;
    while more {
        let len = entry.szExeFile.iter().position(|&c| c == 0).unwrap_or(entry.szExeFile.len());
        out.push(Entry {
            pid: entry.th32ProcessID,
            parent: entry.th32ParentProcessID,
            exe: String::from_utf16_lossy(&entry.szExeFile[..len]),
        });
        more = unsafe { Process32NextW(snapshot.0, &mut entry) } != 0;
    }
    out
}

/// When a process started, in FILETIME ticks.
fn started(pid: u32) -> Option<u64> {
    let process = open(pid, PROCESS_QUERY_LIMITED_INFORMATION)?;
    let zero = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
    let (mut created, mut exited, mut kernel, mut user) = (zero, zero, zero, zero);
    let ok = unsafe { GetProcessTimes(process.0, &mut created, &mut exited, &mut kernel, &mut user) };
    (ok != 0).then(|| (u64::from(created.dwHighDateTime) << 32) | u64::from(created.dwLowDateTime))
}

/// The console hosts ConPTY starts beside a shell. They are plumbing, not
/// something the person ran.
fn is_console_host(exe: &str) -> bool {
    exe.eq_ignore_ascii_case("conhost.exe") || exe.eq_ignore_ascii_case("OpenConsole.exe")
}

/// The command the shell is running, or `None` while it waits at its prompt.
///
/// The newest child, not any child: a shell that started something in the
/// background and then a command in front of it is running the command. A
/// child must also have started after the shell — a pid's parent is a number
/// that outlives the parent, and an old process whose parent died can name a
/// new shell that happened to get the same pid.
pub fn foreground(shell: u32) -> Option<u32> {
    let born = started(shell)?;
    processes()
        .iter()
        .filter(|p| p.parent == shell && p.pid != shell && !is_console_host(&p.exe))
        .filter_map(|p| started(p.pid).filter(|&t| t >= born).map(|t| (t, p.pid)))
        .max()
        .map(|(_, pid)| pid)
}

/// What a process is called: its executable's name, without `.exe`, in
/// lower case, so a tab running `Claude.exe` reads the same as one running
/// `claude` anywhere else.
///
/// A launcher stands aside for what it launched: `cmd /c claude.cmd` is
/// `claude`, and `node …\node_modules\@openai\codex\bin\codex.js` is
/// `codex`. Packages installed with npm run that way on Windows, and a tab
/// called `node` says nothing about which of them it is. The same goes for
/// `keep ia confinar -- claude …`, which holds the AI of a workspace that is
/// confined to a folder: Windows has no `exec`, so it stays as the parent.
pub fn process_name(pid: u32) -> Option<String> {
    let exe = processes().iter().find(|p| p.pid == pid)?.exe.clone();
    let name = exe.strip_suffix(".exe").or_else(|| exe.strip_suffix(".EXE")).unwrap_or(&exe);
    let name = name.to_ascii_lowercase();
    if matches!(name.as_str(), "cmd" | "node" | "bun" | "deno" | "keep") {
        if let Some(line) = command_line(pid) {
            if let Some(better) = launched_name(&name, &line) {
                return Some(better);
            }
        }
    }
    (!name.is_empty()).then_some(name)
}

/// The program a launcher's command line names, if it names one.
fn launched_name(launcher: &str, line: &str) -> Option<String> {
    let args = split_command_line(line);
    if launcher == "keep" {
        // `keep ia confinar [--] <program> …`: the program is what the tab runs.
        let at = args.iter().position(|a| a == "confinar").filter(|&i| i > 0 && args[i - 1] == "ia")?;
        let program = match args.get(at + 1)?.as_str() {
            "--" => args.get(at + 2)?,
            other => other,
        };
        let file = program.rsplit(['\\', '/']).next()?;
        let stem = file.rsplit_once('.').map(|(s, _)| s).unwrap_or(file);
        return (!stem.is_empty()).then(|| stem.to_ascii_lowercase());
    }
    if launcher == "cmd" {
        // `cmd /c <script> …`: the script is the program.
        let at = args.iter().position(|a| a.eq_ignore_ascii_case("/c") || a.eq_ignore_ascii_case("/k"))?;
        let script = args.get(at + 1)?;
        let file = script.rsplit(['\\', '/']).next()?;
        let stem = file.rsplit_once('.').map(|(s, _)| s).unwrap_or(file);
        return (!stem.is_empty()).then(|| stem.to_ascii_lowercase());
    }
    // A JavaScript runtime: the first script it was handed.
    let script = args.iter().skip(1).find(|a| {
        let lower = a.to_ascii_lowercase();
        lower.ends_with(".js") || lower.ends_with(".mjs") || lower.ends_with(".cjs")
    })?;
    let parts: Vec<&str> = script.split(['\\', '/']).filter(|p| !p.is_empty()).collect();
    if let Some(at) = parts.iter().rposition(|p| p.eq_ignore_ascii_case("node_modules")) {
        let package = match parts.get(at + 1) {
            Some(scope) if scope.starts_with('@') => parts.get(at + 2).copied(),
            other => other.copied(),
        }?;
        // `@anthropic-ai/claude-code` is installed as `claude`.
        let package = package.to_ascii_lowercase();
        return Some(match package.as_str() {
            "claude-code" => "claude".into(),
            _ => package,
        });
    }
    let file = parts.last()?;
    file.rsplit_once('.').map(|(s, _)| s.to_ascii_lowercase())
}

/// Split a Windows command line the way the C runtime does: spaces separate,
/// double quotes group, and a backslash only means anything before a quote.
pub fn split_command_line(line: &str) -> Vec<String> {
    let mut args = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    let mut started = false;
    let mut slashes = 0usize;
    for c in line.chars() {
        match c {
            '\\' => {
                slashes += 1;
                started = true;
            }
            '"' => {
                current.extend(std::iter::repeat_n('\\', slashes / 2));
                if slashes % 2 == 1 {
                    current.push('"');
                } else {
                    quoted = !quoted;
                }
                slashes = 0;
                started = true;
            }
            ' ' | '\t' if !quoted => {
                current.extend(std::iter::repeat_n('\\', slashes));
                slashes = 0;
                if started {
                    args.push(std::mem::take(&mut current));
                    started = false;
                }
            }
            _ => {
                current.extend(std::iter::repeat_n('\\', slashes));
                slashes = 0;
                current.push(c);
                started = true;
            }
        }
    }
    current.extend(std::iter::repeat_n('\\', slashes));
    if started {
        args.push(current);
    }
    args
}

/// Read `len` bytes at `address` in another process.
fn read(process: &Handle, address: usize, len: usize) -> Option<Vec<u8>> {
    let mut buf = vec![0u8; len];
    let mut got = 0usize;
    let ok = unsafe {
        ReadProcessMemory(process.0, address as *const c_void, buf.as_mut_ptr().cast(), len, &mut got)
    };
    (ok != 0 && got == len).then_some(buf)
}

fn read_usize(process: &Handle, address: usize) -> Option<usize> {
    let bytes = read(process, address, std::mem::size_of::<usize>())?;
    Some(usize::from_le_bytes(bytes.try_into().ok()?))
}

/// A `UNICODE_STRING` in the other process: length, then a pointer to it.
fn read_unicode_string(process: &Handle, address: usize) -> Option<String> {
    let header = read(process, address, 16)?;
    let len = u16::from_le_bytes([header[0], header[1]]) as usize;
    let buffer = usize::from_le_bytes(header[8..16].try_into().ok()?);
    if len == 0 || buffer == 0 || len > 64 * 1024 {
        return None;
    }
    let bytes = read(process, buffer, len)?;
    let wide: Vec<u16> = bytes.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
    Some(String::from_utf16_lossy(&wide))
}

/// Offsets into a 64-bit process's PEB and its parameters block. Stable
/// since Windows XP x64; what a debugger reads.
const PEB_PROCESS_PARAMETERS: usize = 0x20;
const PARAMETERS_CURRENT_DIRECTORY: usize = 0x38;
const PARAMETERS_COMMAND_LINE: usize = 0x70;

/// The address of a process's parameters block, if it is a 64-bit process
/// this one may read.
fn parameters(pid: u32) -> Option<(Handle, usize)> {
    if std::mem::size_of::<usize>() != 8 {
        return None;
    }
    let process = open(pid, PROCESS_QUERY_INFORMATION | PROCESS_VM_READ)?;
    // A 32-bit process keeps its directory in the 32-bit PEB, which this
    // layout does not describe. Saying nothing beats saying something stale.
    let mut wow = 0;
    if unsafe { IsWow64Process(process.0, &mut wow) } == 0 || wow != 0 {
        return None;
    }
    let mut info: PROCESS_BASIC_INFORMATION = unsafe { std::mem::zeroed() };
    let mut got = 0u32;
    let status = unsafe {
        NtQueryInformationProcess(
            process.0,
            ProcessBasicInformation,
            (&mut info as *mut PROCESS_BASIC_INFORMATION).cast(),
            std::mem::size_of::<PROCESS_BASIC_INFORMATION>() as u32,
            &mut got,
        )
    };
    if status < 0 || info.PebBaseAddress.is_null() {
        return None;
    }
    let peb = info.PebBaseAddress as usize;
    let params = read_usize(&process, peb + PEB_PROCESS_PARAMETERS)?;
    (params != 0).then_some((process, params))
}

/// Where a process is working.
pub fn process_cwd(pid: u32) -> Option<String> {
    let (process, params) = parameters(pid)?;
    let dir = read_unicode_string(&process, params + PARAMETERS_CURRENT_DIRECTORY)?;
    // Windows keeps the directory with a trailing separator; nothing else
    // that reports a directory does, except for the root of a drive.
    let trimmed = match dir.strip_suffix('\\') {
        Some(rest) if !rest.ends_with(':') => rest.to_string(),
        _ => dir,
    };
    (!trimmed.is_empty()).then_some(trimmed)
}

/// How a process was started.
pub fn command_line(pid: u32) -> Option<String> {
    let (process, params) = parameters(pid)?;
    read_unicode_string(&process, params + PARAMETERS_COMMAND_LINE)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_lines_split_like_the_c_runtime() {
        assert_eq!(split_command_line(r#"cmd /c "C:\a b\claude.cmd" --x"#), [
            "cmd",
            "/c",
            r"C:\a b\claude.cmd",
            "--x"
        ]);
        assert_eq!(split_command_line(r#"a\\"b c" d"#), [r"a\b c", "d"]);
        assert_eq!(split_command_line(r#"x "" y"#), ["x", "", "y"]);
    }

    #[test]
    fn a_launcher_stands_aside_for_what_it_runs() {
        assert_eq!(
            launched_name("cmd", r#"C:\Windows\system32\cmd.exe /d /s /c "C:\Users\a\AppData\Roaming\npm\claude.cmd""#),
            Some("claude".into())
        );
        assert_eq!(
            launched_name("node", r#""C:\Program Files\nodejs\node.exe" C:\Users\a\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\cli.js"#),
            Some("claude".into())
        );
        assert_eq!(
            launched_name("node", r#"node C:\x\node_modules\@openai\codex\bin\codex.js resume"#),
            Some("codex".into())
        );
        assert_eq!(launched_name("node", "node server.js"), Some("server".into()));
        assert_eq!(launched_name("node", "node"), None);
        // The `keep` that holds a confined AI is the AI; any other `keep` is `keep`.
        assert_eq!(
            launched_name("keep", r#""C:\K\bin\keep.exe" ia confinar -- C:\u\.local\bin\claude.exe --effort max"#),
            Some("claude".into())
        );
        assert_eq!(
            launched_name("keep", r#"keep ia confinar -- "C:\npm\codex.cmd" resume x"#),
            Some("codex".into())
        );
        assert_eq!(launched_name("keep", "keep ls"), None);
        assert_eq!(launched_name("keep", "keep ia confinar"), None);
    }

    #[test]
    fn this_process_reads_as_itself() {
        let me = std::process::id();
        let name = process_name(me).expect("own name");
        assert!(!name.ends_with(".exe"), "{name}");
        let cwd = process_cwd(me).expect("own cwd");
        let expected = std::env::current_dir().unwrap();
        assert_eq!(
            cwd.to_ascii_lowercase(),
            expected.display().to_string().trim_end_matches('\\').to_ascii_lowercase()
        );
        assert!(command_line(me).is_some());
    }

    #[test]
    fn a_child_is_the_foreground_and_none_is_none() {
        // A shell of our own rather than this test process, which other tests
        // running beside this one give children of their own.
        let mut shell = std::process::Command::new("cmd.exe")
            .args(["/c", "ping -n 6 127.0.0.1 >nul"])
            .spawn()
            .expect("spawn");
        let mut fg = None;
        for _ in 0..40 {
            fg = foreground(shell.id());
            if fg.is_some() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        let fg = fg.expect("the shell's command is its foreground");
        assert_eq!(process_name(fg).as_deref(), Some("ping"));
        // The command itself runs nothing: it is the one waiting.
        assert_eq!(foreground(fg), None);
        shell.kill().ok();
        shell.wait().ok();
    }
}

// Taken from Keep (https://github.com/ttwwnn/keep @ e944802, `crates/keep-proto/src/pipe.rs`),
// MIT, Copyright (c) the Keep authors — see crates/keep-vt/LICENSE-keep.
// Changed: `default_name` dropped; seahelmd names its pipes (platform::address).

//! Named pipes that behave like the unix socket the rest of keep was written
//! against.
//!
//! Two things a unix socket gives for free are built here. Reads and writes on
//! one connection happen at once from different threads — the daemon's pump
//! writes output while the connection thread waits for keystrokes — and a pipe
//! opened for ordinary synchronous I/O serves those one at a time, so the read
//! waiting for a key would hold every write of output behind it. Opening the
//! pipe overlapped, and waiting on each operation's own event, keeps the
//! blocking interface while the two directions run side by side.
//!
//! And shutting a connection down from one thread has to wake whoever is
//! blocked on it in another, which is how the daemon lets go of a client.
//!
//! The pipe is the user's alone: its name carries their SID, its DACL admits
//! only them, it refuses remote clients, and a client checks that the process
//! serving it runs as the same user before it sends a single key — so another
//! account that got to the name first cannot read what is typed.

use std::ffi::c_void;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{
    CloseHandle, ERROR_BROKEN_PIPE, ERROR_IO_PENDING, ERROR_NO_DATA, ERROR_OPERATION_ABORTED,
    ERROR_PIPE_BUSY, ERROR_PIPE_CONNECTED, ERROR_PIPE_NOT_CONNECTED, GENERIC_READ, GENERIC_WRITE,
    GetLastError, HANDLE, INVALID_HANDLE_VALUE, LocalFree, WAIT_TIMEOUT,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
};
use windows_sys::Win32::Security::{
    GetLengthSid, GetTokenInformation, SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER, TokenUser,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_FLAG_OVERLAPPED, OPEN_EXISTING,
    PIPE_ACCESS_DUPLEX, ReadFile, SECURITY_IDENTIFICATION, SECURITY_SQOS_PRESENT, WriteFile,
};
use windows_sys::Win32::System::IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED};
use windows_sys::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, GetNamedPipeServerProcessId,
    PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_UNLIMITED_INSTANCES,
    PIPE_WAIT, WaitNamedPipeW,
};
use windows_sys::Win32::System::Threading::{
    CreateEventW, GetCurrentProcess, INFINITE, OpenProcess, OpenProcessToken,
    PROCESS_QUERY_LIMITED_INFORMATION, ResetEvent, WaitForSingleObject,
};

/// Where every pipe name starts.
const PREFIX: &str = r"\\.\pipe\";

/// Kernel buffer per direction. Advisory: the system grows it as needed.
const BUFFER: u32 = 64 * 1024;

/// A pipe name for whatever was given as the daemon's address.
///
/// The address is a path on unix, and tests and tools hand one over on
/// Windows too — a file in a temporary directory, say. Anything that is not
/// already a pipe name is folded into one, the same way every time, so both
/// ends that were given the same address meet on the same pipe.
pub fn name_for(address: &Path) -> PathBuf {
    let text = address.to_string_lossy();
    if text.starts_with(PREFIX) || text.starts_with(r"\\?\pipe\") {
        return PathBuf::from(text.into_owned());
    }
    let mut folded: String = text
        .chars()
        .map(|c| if matches!(c, '\\' | '/' | ':') { '-' } else { c })
        .collect();
    // A pipe name has room for 256 characters, prefix included.
    if folded.chars().count() > 200 {
        let hash = folded.bytes().fold(0xcbf2_9ce4_8422_2325u64, |h, b| {
            (h ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01b3)
        });
        let tail: String = folded.chars().rev().take(150).collect::<Vec<_>>().into_iter().rev().collect();
        folded = format!("{hash:016x}-{tail}");
    }
    PathBuf::from(format!("{PREFIX}{folded}"))
}

fn wide(path: &Path) -> Vec<u16> {
    name_for(path).to_string_lossy().encode_utf16().chain(std::iter::once(0)).collect()
}

fn last_error() -> io::Error {
    io::Error::from_raw_os_error(unsafe { GetLastError() } as i32)
}

/// A kernel handle, closed when the last owner lets go.
struct Handle(HANDLE);

// A handle is a number the kernel resolves; using it from another thread is
// what overlapped I/O is for.
unsafe impl Send for Handle {}
unsafe impl Sync for Handle {}

impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
    }
}

thread_local! {
    /// The event this thread waits on. A thread runs one blocking operation at
    /// a time, so one event each is enough, and creating it once saves a pair
    /// of system calls on every keystroke.
    static EVENT: Handle = Handle(unsafe { CreateEventW(null(), 1, 0, null()) });
}

fn millis(timeout: Option<Duration>) -> u32 {
    match timeout {
        None => INFINITE,
        Some(d) => d.as_millis().clamp(1, u128::from(INFINITE - 1)) as u32,
    }
}

/// Run one overlapped operation to its end, as a blocking call.
///
/// `start` issues it against the `OVERLAPPED` it is handed. The structure
/// lives on this stack frame, so nothing returns before the kernel is done
/// with it — after a timeout, the cancellation is waited out too.
fn complete(
    handle: HANDLE,
    shut: Option<&AtomicBool>,
    timeout: Option<Duration>,
    start: impl FnOnce(*mut OVERLAPPED) -> i32,
) -> io::Result<u32> {
    EVENT.with(|event| unsafe {
        if event.0.is_null() {
            return Err(io::Error::other("no event to wait on"));
        }
        let mut ov: OVERLAPPED = std::mem::zeroed();
        ov.hEvent = event.0;
        ResetEvent(event.0);
        if start(&mut ov) == 0 {
            let err = GetLastError();
            if err != ERROR_IO_PENDING {
                return Err(io::Error::from_raw_os_error(err as i32));
            }
            // In flight. A shutdown that ran before it was issued had nothing
            // of ours to cancel, so it is looked for again now; one that runs
            // after this finds the operation and cancels it itself.
            if shut.is_some_and(|s| s.load(Ordering::Acquire)) {
                CancelIoEx(handle, &ov);
            }
            if WaitForSingleObject(event.0, millis(timeout)) == WAIT_TIMEOUT {
                CancelIoEx(handle, &ov);
                let mut done = 0u32;
                if GetOverlappedResult(handle, &ov, &mut done, 1) != 0 {
                    // It finished in the same moment it was given up on.
                    return Ok(done);
                }
                let err = GetLastError();
                return Err(if err == ERROR_OPERATION_ABORTED {
                    io::Error::new(io::ErrorKind::TimedOut, "pipe operation timed out")
                } else {
                    io::Error::from_raw_os_error(err as i32)
                });
            }
        }
        let mut done = 0u32;
        if GetOverlappedResult(handle, &ov, &mut done, 1) == 0 {
            return Err(last_error());
        }
        Ok(done)
    })
}

struct Shared {
    handle: Handle,
    /// Set by `shutdown`: every later operation on any clone ends at once.
    shut: AtomicBool,
    /// Timeouts in milliseconds, zero for none. Shared by every clone, the
    /// way a socket's options are.
    read_timeout: AtomicU64,
    write_timeout: AtomicU64,
}

/// One end of a connection.
pub struct Stream {
    shared: Arc<Shared>,
}

impl Stream {
    fn from_handle(handle: Handle) -> Self {
        Stream {
            shared: Arc::new(Shared {
                handle,
                shut: AtomicBool::new(false),
                read_timeout: AtomicU64::new(0),
                write_timeout: AtomicU64::new(0),
            }),
        }
    }

    /// Connect to the daemon at `path`, and make sure it is ours.
    pub fn connect<P: AsRef<Path>>(path: P) -> io::Result<Stream> {
        let name = wide(path.as_ref());
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let handle = unsafe {
                CreateFileW(
                    name.as_ptr(),
                    GENERIC_READ | GENERIC_WRITE,
                    0,
                    null(),
                    OPEN_EXISTING,
                    // Identification only: the daemon may learn who is
                    // connecting, never act as them.
                    FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                    null_mut(),
                )
            };
            if handle != INVALID_HANDLE_VALUE {
                let handle = Handle(handle);
                verify_server(handle.0)?;
                return Ok(Stream::from_handle(handle));
            }
            let err = unsafe { GetLastError() };
            // Every instance taken: the daemon is between accepting one
            // client and opening the pipe to the next.
            if err == ERROR_PIPE_BUSY && Instant::now() < deadline {
                unsafe { WaitNamedPipeW(name.as_ptr(), 250) };
                continue;
            }
            return Err(io::Error::from_raw_os_error(err as i32));
        }
    }

    /// The process serving this connection, as the pipe reports it.
    pub fn server_process_id(&self) -> io::Result<u32> {
        let mut pid = 0u32;
        if unsafe { GetNamedPipeServerProcessId(self.shared.handle.0, &mut pid) } == 0 {
            return Err(last_error());
        }
        Ok(pid)
    }

    /// Another handle on the same connection, for another thread.
    pub fn try_clone(&self) -> io::Result<Stream> {
        Ok(Stream { shared: Arc::clone(&self.shared) })
    }

    /// End the connection for every clone: blocked reads and writes return,
    /// and later ones do not start.
    ///
    /// The handle itself closes when the last clone is dropped, which is
    /// what the other end sees as the end of the stream — data already
    /// written stays readable until then, as it would on a socket.
    pub fn shutdown(&self, _how: std::net::Shutdown) -> io::Result<()> {
        self.shared.shut.store(true, Ordering::Release);
        unsafe { CancelIoEx(self.shared.handle.0, null()) };
        Ok(())
    }

    pub fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        store_timeout(&self.shared.read_timeout, timeout)
    }

    pub fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        store_timeout(&self.shared.write_timeout, timeout)
    }

    fn timeout(cell: &AtomicU64) -> Option<Duration> {
        match cell.load(Ordering::Relaxed) {
            0 => None,
            ms => Some(Duration::from_millis(ms)),
        }
    }

    fn closed(&self) -> bool {
        self.shared.shut.load(Ordering::Acquire)
    }
}

fn store_timeout(cell: &AtomicU64, timeout: Option<Duration>) -> io::Result<()> {
    match timeout {
        Some(d) if d.is_zero() => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "cannot set a 0 duration timeout",
        )),
        Some(d) => {
            cell.store(d.as_millis().max(1) as u64, Ordering::Relaxed);
            Ok(())
        }
        None => {
            cell.store(0, Ordering::Relaxed);
            Ok(())
        }
    }
}

/// Errors that mean the other end has gone.
fn is_gone(err: &io::Error) -> bool {
    matches!(
        err.raw_os_error().map(|c| c as u32),
        Some(ERROR_BROKEN_PIPE | ERROR_PIPE_NOT_CONNECTED | ERROR_NO_DATA)
    )
}

fn is_aborted(err: &io::Error) -> bool {
    err.raw_os_error() == Some(ERROR_OPERATION_ABORTED as i32)
}

impl Read for Stream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.closed() || buf.is_empty() {
            return Ok(0);
        }
        let handle = self.shared.handle.0;
        let len = buf.len().min(u32::MAX as usize) as u32;
        let ptr = buf.as_mut_ptr();
        let timeout = Self::timeout(&self.shared.read_timeout);
        match complete(handle, Some(&self.shared.shut), timeout, |ov| unsafe {
            ReadFile(handle, ptr, len, null_mut(), ov)
        }) {
            Ok(n) => Ok(n as usize),
            Err(e) if is_gone(&e) => Ok(0),
            Err(e) if is_aborted(&e) && self.closed() => Ok(0),
            Err(e) => Err(e),
        }
    }
}

impl Write for Stream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if self.closed() {
            return Err(io::ErrorKind::BrokenPipe.into());
        }
        if buf.is_empty() {
            return Ok(0);
        }
        let handle = self.shared.handle.0;
        let len = buf.len().min(u32::MAX as usize) as u32;
        let ptr = buf.as_ptr();
        let timeout = Self::timeout(&self.shared.write_timeout);
        match complete(handle, Some(&self.shared.shut), timeout, |ov| unsafe {
            WriteFile(handle, ptr, len, null_mut(), ov)
        }) {
            Ok(n) => Ok(n as usize),
            Err(e) if is_gone(&e) || (is_aborted(&e) && self.closed()) => {
                Err(io::ErrorKind::BrokenPipe.into())
            }
            Err(e) => Err(e),
        }
    }

    /// One write for the whole frame. The default writes the first slice only
    /// and is called again for the rest, which costs a second trip through
    /// the kernel for every chunk of output.
    fn write_vectored(&mut self, bufs: &[io::IoSlice<'_>]) -> io::Result<usize> {
        let total: usize = bufs.iter().map(|b| b.len()).sum();
        if bufs.len() < 2 || total > 1024 * 1024 {
            let first = bufs.iter().find(|b| !b.is_empty()).map(|b| &b[..]).unwrap_or(&[]);
            return self.write(first);
        }
        let mut joined = Vec::with_capacity(total);
        for b in bufs {
            joined.extend_from_slice(b);
        }
        self.write_all(&joined)?;
        Ok(total)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// The security descriptor every instance of the pipe is created with: the
/// current user, and nobody else.
struct Security {
    descriptor: *mut c_void,
}

unsafe impl Send for Security {}
unsafe impl Sync for Security {}

impl Security {
    fn for_current_user() -> io::Result<Self> {
        let sid = current_user_sid_string()?;
        // Protected (`P`), so nothing is inherited from a parent; generic all
        // to the user's SID, and that is the whole list.
        let sddl: Vec<u16> =
            format!("D:P(A;;GA;;;{sid})").encode_utf16().chain(std::iter::once(0)).collect();
        let mut descriptor: *mut c_void = null_mut();
        let ok = unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                SDDL_REVISION_1,
                &mut descriptor,
                null_mut(),
            )
        };
        if ok == 0 {
            return Err(last_error());
        }
        Ok(Security { descriptor })
    }

    fn attributes(&self) -> SECURITY_ATTRIBUTES {
        SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: self.descriptor,
            bInheritHandle: 0,
        }
    }
}

impl Drop for Security {
    fn drop(&mut self) {
        unsafe { LocalFree(self.descriptor) };
    }
}

fn create_instance(name: &[u16], security: &Security, first: bool) -> io::Result<Handle> {
    let attributes = security.attributes();
    let mut mode = PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED;
    if first {
        // Fails if the name is taken — by an older daemon, or by somebody
        // else entirely. Either way this one must not serve it.
        mode |= FILE_FLAG_FIRST_PIPE_INSTANCE;
    }
    let handle = unsafe {
        CreateNamedPipeW(
            name.as_ptr(),
            mode,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            PIPE_UNLIMITED_INSTANCES,
            BUFFER,
            BUFFER,
            0,
            &attributes,
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        return Err(last_error());
    }
    Ok(Handle(handle))
}

/// The listening end.
///
/// A pipe is not one socket accepting many connections: each connection is
/// an instance of the pipe, and the name only answers while an instance is
/// waiting. So one is always kept waiting — the next is created the moment
/// the last one is taken.
pub struct Listener {
    name: Vec<u16>,
    security: Security,
    waiting: Mutex<Option<Handle>>,
}

impl Listener {
    pub fn bind<P: AsRef<Path>>(path: P) -> io::Result<Listener> {
        let name = wide(path.as_ref());
        let security = Security::for_current_user()?;
        let first = create_instance(&name, &security, true)?;
        Ok(Listener { name, security, waiting: Mutex::new(Some(first)) })
    }

    pub fn accept(&self) -> io::Result<(Stream, ())> {
        loop {
            let instance = match self.waiting.lock().map(|mut w| w.take()).unwrap_or(None) {
                Some(handle) => handle,
                None => create_instance(&self.name, &self.security, false)?,
            };
            let handle = instance.0;
            match complete(handle, None, None, |ov| unsafe { ConnectNamedPipe(handle, ov) }) {
                Ok(_) => {}
                // A client got there between creating the instance and
                // waiting on it.
                Err(e) if e.raw_os_error() == Some(ERROR_PIPE_CONNECTED as i32) => {}
                // A client came and went before it was seen. The instance is
                // reusable once disconnected.
                Err(e) if e.raw_os_error() == Some(ERROR_NO_DATA as i32) => {
                    unsafe { DisconnectNamedPipe(handle) };
                    if let Ok(mut waiting) = self.waiting.lock() {
                        *waiting = Some(instance);
                    }
                    continue;
                }
                Err(e) => return Err(e),
            }
            // The name keeps answering while this connection is handed over.
            if let Ok(next) = create_instance(&self.name, &self.security, false) {
                if let Ok(mut waiting) = self.waiting.lock() {
                    *waiting = Some(next);
                }
            }
            return Ok((Stream::from_handle(instance), ()));
        }
    }

    pub fn incoming(&self) -> Incoming<'_> {
        Incoming { listener: self }
    }
}

pub struct Incoming<'a> {
    listener: &'a Listener,
}

impl Iterator for Incoming<'_> {
    type Item = io::Result<Stream>;

    fn next(&mut self) -> Option<io::Result<Stream>> {
        Some(self.listener.accept().map(|(stream, _)| stream))
    }
}

/// The SID of the user a token belongs to, as bytes.
fn token_user_sid(token: HANDLE) -> io::Result<Vec<u8>> {
    let mut needed = 0u32;
    unsafe { GetTokenInformation(token, TokenUser, null_mut(), 0, &mut needed) };
    if needed == 0 {
        return Err(last_error());
    }
    // u64s, so the buffer is aligned for the pointer at the head of TOKEN_USER.
    let mut buf = vec![0u64; (needed as usize).div_ceil(8)];
    let ok = unsafe {
        GetTokenInformation(token, TokenUser, buf.as_mut_ptr().cast(), needed, &mut needed)
    };
    if ok == 0 {
        return Err(last_error());
    }
    let user = unsafe { &*(buf.as_ptr() as *const TOKEN_USER) };
    let sid = user.User.Sid;
    let len = unsafe { GetLengthSid(sid) } as usize;
    Ok(unsafe { std::slice::from_raw_parts(sid as *const u8, len) }.to_vec())
}

fn process_user_sid(process: HANDLE) -> io::Result<Vec<u8>> {
    let mut token: HANDLE = null_mut();
    if unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) } == 0 {
        return Err(last_error());
    }
    let token = Handle(token);
    token_user_sid(token.0)
}

fn current_user_sid() -> io::Result<Vec<u8>> {
    process_user_sid(unsafe { GetCurrentProcess() })
}

/// The current user's SID in its `S-1-5-21-…` spelling.
pub fn current_user_sid_string() -> io::Result<String> {
    let mut sid = current_user_sid()?;
    let mut text: *mut u16 = null_mut();
    if unsafe { ConvertSidToStringSidW(sid.as_mut_ptr().cast(), &mut text) } == 0 {
        return Err(last_error());
    }
    let len = (0..).take_while(|&i| unsafe { *text.add(i) } != 0).count();
    let out = String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(text, len) });
    unsafe { LocalFree(text.cast()) };
    Ok(out)
}

/// Refuse a pipe served by anybody but the current user.
fn verify_server(pipe: HANDLE) -> io::Result<()> {
    let mut pid = 0u32;
    if unsafe { GetNamedPipeServerProcessId(pipe, &mut pid) } == 0 {
        return Err(last_error());
    }
    let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if process.is_null() {
        return Err(last_error());
    }
    let process = Handle(process);
    if process_user_sid(process.0)? != current_user_sid()? {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "the keep pipe is served by another user",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};

    fn unique(tag: &str) -> PathBuf {
        PathBuf::from(format!(r"{PREFIX}keep-test-{tag}-{}", std::process::id()))
    }

    #[test]
    fn a_path_becomes_a_pipe_name_and_a_pipe_name_stays_one() {
        let named = name_for(Path::new(r"\\.\pipe\keep-x"));
        assert_eq!(named, PathBuf::from(r"\\.\pipe\keep-x"));
        let folded = name_for(Path::new(r"C:\Users\a\AppData\Local\Temp\keep.sock"));
        assert_eq!(folded, PathBuf::from(r"\\.\pipe\C--Users-a-AppData-Local-Temp-keep.sock"));
        let long = "x".repeat(400);
        assert!(name_for(Path::new(&long)).to_string_lossy().len() < 256);
    }

    #[test]
    fn bytes_go_both_ways_at_once() {
        let name = unique("both");
        let listener = Listener::bind(&name).expect("bind");
        let server = std::thread::spawn(move || {
            let (mut conn, _) = listener.accept().expect("accept");
            let mut reader = conn.try_clone().unwrap();
            // A read parked on one clone must not hold up a write on another.
            let parked = std::thread::spawn(move || {
                let mut buf = [0u8; 5];
                reader.read_exact(&mut buf).map(|_| buf)
            });
            std::thread::sleep(Duration::from_millis(200));
            conn.write_all(b"hello").unwrap();
            parked.join().unwrap().unwrap()
        });
        let mut client = Stream::connect(&name).expect("connect");
        let mut got = [0u8; 5];
        client.read_exact(&mut got).unwrap();
        assert_eq!(&got, b"hello");
        client.write_all(b"world").unwrap();
        assert_eq!(&server.join().unwrap(), b"world");
    }

    #[test]
    fn shutdown_wakes_a_blocked_reader() {
        let name = unique("shut");
        let listener = Listener::bind(&name).expect("bind");
        let accepted = std::thread::spawn(move || listener.accept().map(|(s, _)| s).unwrap());
        let _client = Stream::connect(&name).expect("connect");
        let conn = accepted.join().unwrap();
        let mut reader = conn.try_clone().unwrap();
        let blocked = std::thread::spawn(move || {
            let mut buf = [0u8; 1];
            reader.read(&mut buf)
        });
        std::thread::sleep(Duration::from_millis(200));
        conn.shutdown(std::net::Shutdown::Both).unwrap();
        assert_eq!(blocked.join().unwrap().unwrap(), 0, "a shut connection reads as ended");
    }

    #[test]
    fn a_read_timeout_times_out() {
        let name = unique("timeout");
        let listener = Listener::bind(&name).expect("bind");
        let accepted = std::thread::spawn(move || listener.accept().map(|(s, _)| s).unwrap());
        let mut client = Stream::connect(&name).expect("connect");
        let _conn = accepted.join().unwrap();
        client.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
        let started = Instant::now();
        let mut buf = [0u8; 1];
        let err = client.read(&mut buf).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn the_end_of_the_other_side_reads_as_eof() {
        let name = unique("eof");
        let listener = Listener::bind(&name).expect("bind");
        let accepted = std::thread::spawn(move || listener.accept().map(|(s, _)| s).unwrap());
        let mut client = Stream::connect(&name).expect("connect");
        let mut conn = accepted.join().unwrap();
        conn.write_all(b"last").unwrap();
        drop(conn);
        let mut got = Vec::new();
        client.read_to_end(&mut got).unwrap();
        assert_eq!(got, b"last", "what was written before the close still arrives");
    }

    #[test]
    fn a_second_daemon_cannot_take_the_name() {
        let name = unique("twice");
        let _first = Listener::bind(&name).expect("bind");
        assert!(Listener::bind(&name).is_err(), "the name is already served");
    }

    #[test]
    fn several_clients_are_served_one_after_another() {
        let name = unique("many");
        let listener = Listener::bind(&name).expect("bind");
        let server = std::thread::spawn(move || {
            for _ in 0..3 {
                let (mut conn, _) = listener.accept().unwrap();
                let mut b = [0u8; 1];
                conn.read_exact(&mut b).unwrap();
                conn.write_all(&[b[0] + 1]).unwrap();
            }
        });
        for i in 0..3u8 {
            let mut c = Stream::connect(&name).expect("connect");
            c.write_all(&[i]).unwrap();
            let mut b = [0u8; 1];
            c.read_exact(&mut b).unwrap();
            assert_eq!(b[0], i + 1);
        }
        server.join().unwrap();
    }
}

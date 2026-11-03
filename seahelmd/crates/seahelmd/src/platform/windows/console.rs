// Taken from Keep (https://github.com/ttwwnn/keep @ e944802, `crates/keep/src/console.rs`),
// MIT, Copyright (c) the Keep authors — see crates/keep-vt/LICENSE-keep.

//! The Windows console, set up the way a unix terminal in raw mode already is.
//!
//! A unix terminal in raw mode hands over keys as the bytes a terminal writes
//! and shows whatever bytes it is given. A Windows console does neither until
//! asked: keys arrive as key events unless virtual terminal input is on, and
//! escape sequences print as text unless processing is on. Both are switched
//! on here, the code pages set to UTF-8, and all of it put back on the way
//! out.
//!
//! Reading and writing go around the standard library as well. Its console
//! writer refuses bytes that are not UTF-8 — a program printing a binary file
//! would end the attach — and its reader takes Ctrl+Z at the start of a read
//! for the end of input, where a terminal must hand it on as a key.

use std::io::{self, Read, Write};
use std::ptr::null;

use windows_sys::Win32::Foundation::{HANDLE, INVALID_HANDLE_VALUE};
use windows_sys::Win32::Storage::FileSystem::WriteFile;
use windows_sys::Win32::System::Console::{
    CONSOLE_MODE, DISABLE_NEWLINE_AUTO_RETURN, ENABLE_ECHO_INPUT, ENABLE_LINE_INPUT,
    ENABLE_PROCESSED_INPUT, ENABLE_PROCESSED_OUTPUT, ENABLE_VIRTUAL_TERMINAL_INPUT,
    ENABLE_VIRTUAL_TERMINAL_PROCESSING, GetConsoleCP, GetConsoleMode, GetConsoleOutputCP,
    GetStdHandle, ReadConsoleW, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, SetConsoleCP,
    SetConsoleMode, SetConsoleOutputCP,
};

const UTF8: u32 = 65001;

/// What the console was set to before, put back when this is dropped.
pub struct Modes {
    input: Option<(HANDLE, CONSOLE_MODE)>,
    output: Option<(HANDLE, CONSOLE_MODE)>,
    input_cp: u32,
    output_cp: u32,
}

// The handles are the process's own standard input and output.
unsafe impl Send for Modes {}

fn mode_of(handle: HANDLE) -> Option<CONSOLE_MODE> {
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        return None;
    }
    let mut mode: CONSOLE_MODE = 0;
    (unsafe { GetConsoleMode(handle, &mut mode) } != 0).then_some(mode)
}

/// Put the console in raw, VT mode. Called before crossterm's own raw mode,
/// so what is saved here is what the person had.
pub fn enter() -> Modes {
    unsafe {
        let input = GetStdHandle(STD_INPUT_HANDLE);
        let output = GetStdHandle(STD_OUTPUT_HANDLE);
        let modes = Modes {
            input: mode_of(input).map(|m| (input, m)),
            output: mode_of(output).map(|m| (output, m)),
            input_cp: GetConsoleCP(),
            output_cp: GetConsoleOutputCP(),
        };
        if let Some((handle, mode)) = modes.input {
            let raw = (mode | ENABLE_VIRTUAL_TERMINAL_INPUT)
                & !(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT);
            SetConsoleMode(handle, raw);
        }
        if let Some((handle, mode)) = modes.output {
            SetConsoleMode(
                handle,
                mode | ENABLE_PROCESSED_OUTPUT
                    | ENABLE_VIRTUAL_TERMINAL_PROCESSING
                    | DISABLE_NEWLINE_AUTO_RETURN,
            );
        }
        SetConsoleCP(UTF8);
        SetConsoleOutputCP(UTF8);
        modes
    }
}

impl Drop for Modes {
    fn drop(&mut self) {
        unsafe {
            if let Some((handle, mode)) = self.input {
                SetConsoleMode(handle, mode);
            }
            if let Some((handle, mode)) = self.output {
                SetConsoleMode(handle, mode);
            }
            if self.input_cp != 0 {
                SetConsoleCP(self.input_cp);
            }
            if self.output_cp != 0 {
                SetConsoleOutputCP(self.output_cp);
            }
        }
    }
}

/// Standard output, written as bytes.
pub struct Output(HANDLE);

// The handle is the process's own standard output.
unsafe impl Send for Output {}

impl Output {
    pub fn stdout() -> Self {
        Output(unsafe { GetStdHandle(STD_OUTPUT_HANDLE) })
    }
}

impl Write for Output {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let len = buf.len().min(u32::MAX as usize) as u32;
        let mut written = 0u32;
        let ok = unsafe {
            WriteFile(self.0, buf.as_ptr(), len, &mut written, std::ptr::null_mut())
        };
        if ok == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(written as usize)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Standard input, read as the UTF-8 a terminal would have written.
pub struct Input {
    handle: HANDLE,
    console: bool,
    /// A high surrogate whose partner has not been read yet.
    surrogate: Option<u16>,
    /// Converted bytes the caller has not taken yet.
    ready: Vec<u8>,
}

// The handle is the process's own standard input, read from one thread.
unsafe impl Send for Input {}

impl Input {
    pub fn stdin() -> Self {
        let handle = unsafe { GetStdHandle(STD_INPUT_HANDLE) };
        Input { handle, console: mode_of(handle).is_some(), surrogate: None, ready: Vec::new() }
    }

    fn fill(&mut self) -> io::Result<()> {
        let mut units = [0u16; 2048];
        let mut got = 0u32;
        let ok = unsafe {
            ReadConsoleW(
                self.handle,
                units.as_mut_ptr().cast(),
                units.len() as u32,
                &mut got,
                null(),
            )
        };
        if ok == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut wide: Vec<u16> = Vec::with_capacity(got as usize + 1);
        wide.extend(self.surrogate.take());
        wide.extend_from_slice(&units[..got as usize]);
        // A pair split across two reads: hold the first half for the next.
        if let Some(&last) = wide.last() {
            if (0xD800..0xDC00).contains(&last) {
                self.surrogate = wide.pop();
            }
        }
        self.ready.extend_from_slice(String::from_utf16_lossy(&wide).as_bytes());
        Ok(())
    }
}

impl Read for Input {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if !self.console {
            return io::stdin().read(buf);
        }
        while self.ready.is_empty() {
            self.fill()?;
        }
        let n = buf.len().min(self.ready.len());
        buf[..n].copy_from_slice(&self.ready[..n]);
        self.ready.drain(..n);
        Ok(n)
    }
}

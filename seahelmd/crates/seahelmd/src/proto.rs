//! What goes over a session's socket.
//!
//! Frames are `[tag: u8][len: u32 be][payload]`, the same dull shape keep
//! uses: a local socket carrying keystrokes and screen bytes wants framing
//! that cannot desynchronise, not extensibility.

use std::io::{self, Read, Write};

/// A frame bigger than this is a broken peer, not a screen.
const MAX_FRAME: usize = 64 << 20;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Msg {
    // Client → daemon.
    /// Watch the session at this size: answered with `Repaint`, then `Output`
    /// for as long as the connection lasts.
    Attach { cols: u16, rows: u16 },
    /// Keystrokes from an attached client.
    Input(Vec<u8>),
    /// The attached client's window changed size.
    Resize { cols: u16, rows: u16 },
    /// One line of facts for `list`.
    Info,
    /// The screen and scrollback as plain text.
    History,
    /// Bytes for the session's input, from a client that is not attached.
    Send(Vec<u8>),
    /// End the session.
    Kill,

    // Daemon → client.
    Repaint(Vec<u8>),
    Output(Vec<u8>),
    Text(String),
    Ok,
    /// The program exited; nothing more will come.
    Ended,
    Error(String),
}

impl Msg {
    fn encode(&self) -> (u8, Vec<u8>) {
        let size = |cols: u16, rows: u16| {
            let mut v = cols.to_be_bytes().to_vec();
            v.extend_from_slice(&rows.to_be_bytes());
            v
        };
        match self {
            Msg::Attach { cols, rows } => (1, size(*cols, *rows)),
            Msg::Input(b) => (2, b.clone()),
            Msg::Resize { cols, rows } => (3, size(*cols, *rows)),
            Msg::Info => (4, vec![]),
            Msg::History => (5, vec![]),
            Msg::Send(b) => (6, b.clone()),
            Msg::Kill => (7, vec![]),
            Msg::Repaint(b) => (64, b.clone()),
            Msg::Output(b) => (65, b.clone()),
            Msg::Text(s) => (66, s.as_bytes().to_vec()),
            Msg::Ok => (67, vec![]),
            Msg::Ended => (68, vec![]),
            Msg::Error(s) => (69, s.as_bytes().to_vec()),
        }
    }

    fn decode(tag: u8, payload: Vec<u8>) -> io::Result<Msg> {
        let size = |p: &[u8]| -> io::Result<(u16, u16)> {
            if p.len() != 4 {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "bad size frame"));
            }
            Ok((u16::from_be_bytes([p[0], p[1]]), u16::from_be_bytes([p[2], p[3]])))
        };
        let text = |p: Vec<u8>| String::from_utf8_lossy(&p).into_owned();
        Ok(match tag {
            1 => {
                let (cols, rows) = size(&payload)?;
                Msg::Attach { cols, rows }
            }
            2 => Msg::Input(payload),
            3 => {
                let (cols, rows) = size(&payload)?;
                Msg::Resize { cols, rows }
            }
            4 => Msg::Info,
            5 => Msg::History,
            6 => Msg::Send(payload),
            7 => Msg::Kill,
            64 => Msg::Repaint(payload),
            65 => Msg::Output(payload),
            66 => Msg::Text(text(payload)),
            67 => Msg::Ok,
            68 => Msg::Ended,
            69 => Msg::Error(text(payload)),
            _ => return Err(io::Error::new(io::ErrorKind::InvalidData, format!("unknown tag {tag}"))),
        })
    }
}

pub fn write(w: &mut impl Write, msg: &Msg) -> io::Result<()> {
    let (tag, payload) = msg.encode();
    let mut frame = Vec::with_capacity(5 + payload.len());
    frame.push(tag);
    frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    frame.extend_from_slice(&payload);
    w.write_all(&frame)?;
    w.flush()
}

/// The next message, or None at a clean end of stream.
pub fn read(r: &mut impl Read) -> io::Result<Option<Msg>> {
    let mut head = [0u8; 5];
    match r.read_exact(&mut head) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_be_bytes([head[1], head[2], head[3], head[4]]) as usize;
    if len > MAX_FRAME {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "frame too large"));
    }
    let mut payload = vec![0u8; len];
    r.read_exact(&mut payload)?;
    Msg::decode(head[0], payload).map(Some)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_message_survives_the_wire() {
        let all = [
            Msg::Attach { cols: 120, rows: 40 },
            Msg::Input(b"ls\r".to_vec()),
            Msg::Resize { cols: 80, rows: 24 },
            Msg::Info,
            Msg::History,
            Msg::Send(b"\x1b[A".to_vec()),
            Msg::Kill,
            Msg::Repaint(b"\x1b[2J".to_vec()),
            Msg::Output(vec![0, 255, 7]),
            Msg::Text("name=x".into()),
            Msg::Ok,
            Msg::Ended,
            Msg::Error("nope".into()),
        ];
        let mut wire = Vec::new();
        for m in &all {
            write(&mut wire, m).unwrap();
        }
        let mut r = &wire[..];
        for m in &all {
            assert_eq!(read(&mut r).unwrap().as_ref(), Some(m));
        }
        assert_eq!(read(&mut r).unwrap(), None);
    }
}

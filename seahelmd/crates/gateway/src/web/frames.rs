//! Binary frames, as seahelm-web reads and writes them (unchanged from the
//! app's gateway).
//!
//! VT (gateway → page):
//! `u8 version=1, u8 flags (bit 0: zlib), u8 kind (1 data, 2 snapshot),
//!  u8 key length, key, [u16 BE cols, u16 BE rows for a snapshot], payload`.
//! Keys (page → gateway): `u8 version=1, u8 kind=1, u8 key length, key, utf8`.

use std::io::Write;

pub const KIND_SNAPSHOT: u8 = 2;
pub const KIND_DATA: u8 = 1;
/// Smaller payloads are not worth deflating.
const MIN_COMPRESSED: usize = 512;

/// One piece of a pane's terminal, for one page.
#[derive(Debug, Clone, PartialEq)]
pub struct VtEvent {
    pub kind: u8,
    pub pane: String,
    pub payload: Vec<u8>,
    pub cols: u16,
    pub rows: u16,
}

pub fn encode_vt(e: &VtEvent, allow_deflate: bool) -> Option<Vec<u8>> {
    let key = e.pane.as_bytes();
    if key.len() > 255 {
        return None;
    }
    let mut flags = 0u8;
    let mut payload: std::borrow::Cow<[u8]> = std::borrow::Cow::Borrowed(&e.payload);
    if allow_deflate && e.payload.len() >= MIN_COMPRESSED {
        if let Some(z) = deflate(&e.payload).filter(|z| z.len() < e.payload.len()) {
            payload = std::borrow::Cow::Owned(z);
            flags |= 1;
        }
    }
    let mut out = Vec::with_capacity(8 + key.len() + payload.len());
    out.extend_from_slice(&[1, flags, e.kind, key.len() as u8]);
    out.extend_from_slice(key);
    if e.kind == KIND_SNAPSHOT {
        out.extend_from_slice(&e.cols.to_be_bytes());
        out.extend_from_slice(&e.rows.to_be_bytes());
    }
    out.extend_from_slice(&payload);
    Some(out)
}

/// The text form for a page that did not negotiate binary VT.
pub fn legacy_notify(e: &VtEvent) -> serde_json::Value {
    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD.encode(&e.payload);
    if e.kind == KIND_SNAPSHOT {
        serde_json::json!({"type": "notify", "method": "vt.snapshot",
            "params": {"pane_session_key": e.pane, "b64": b64, "cols": e.cols, "rows": e.rows}})
    } else {
        serde_json::json!({"type": "notify", "method": "vt.data", "params": {"pane_session_key": e.pane, "b64": b64}})
    }
}

pub fn decode_keys(frame: &[u8]) -> Option<(String, Vec<u8>)> {
    let [1, 1, len, rest @ ..] = frame else { return None };
    let len = *len as usize;
    if rest.len() < len {
        return None;
    }
    let key = std::str::from_utf8(&rest[..len]).ok()?.to_string();
    Some((key, rest[len..].to_vec()))
}

/// Raw deflate (RFC 1951), no zlib header: what the page inflates with
/// `DecompressionStream('deflate-raw')` (seahelm-web's vt-frame.js), and what
/// the macOS app sent before the gateway — Apple's `COMPRESSION_ZLIB` is raw
/// deflate despite its name. A zlib-wrapped frame fails to inflate there, and
/// the page drops it: every frame of 512 bytes or more, snapshots included.
fn deflate(input: &[u8]) -> Option<Vec<u8>> {
    let mut z = flate2::write::DeflateEncoder::new(Vec::with_capacity(input.len() / 2), flate2::Compression::fast());
    z.write_all(input).ok()?;
    z.finish().ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    #[test]
    fn snapshot_frame_layout() {
        let e = VtEvent { kind: KIND_SNAPSHOT, pane: "p".into(), payload: b"hi".to_vec(), cols: 80, rows: 24 };
        assert_eq!(encode_vt(&e, true).unwrap(), vec![1, 0, 2, 1, b'p', 0, 80, 0, 24, b'h', b'i']);
    }

    #[test]
    fn big_data_is_deflated() {
        let e = VtEvent { kind: KIND_DATA, pane: "k".into(), payload: vec![b'a'; 4000], cols: 0, rows: 0 };
        let f = encode_vt(&e, true).unwrap();
        assert_eq!(f[1], 1);
        // Raw deflate, as `DecompressionStream('deflate-raw')` takes it: a
        // zlib stream would not inflate this way.
        let mut out = Vec::new();
        flate2::read::DeflateDecoder::new(&f[5..]).read_to_end(&mut out).unwrap();
        assert!(flate2::read::ZlibDecoder::new(&f[5..]).read_to_end(&mut Vec::new()).is_err());
        assert_eq!(out, e.payload);
        assert_eq!(encode_vt(&e, false).unwrap()[1], 0);
    }

    #[test]
    fn keys() {
        assert_eq!(decode_keys(&[1, 1, 2, b'a', b'b', b'x']), Some(("ab".into(), b"x".to_vec())));
        assert_eq!(decode_keys(&[1, 2, 0]), None);
        assert_eq!(decode_keys(&[1, 1, 5, b'a']), None);
    }
}

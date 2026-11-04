//! seahelm-web's files: ETags, gzip when asked, and the page's own scripts
//! referenced as `./x.js?v=<etag prefix>` so a fresh page never runs a stale
//! script. HTML is `no-cache`; versioned assets are immutable; anything else
//! revalidates.

use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

use sha2::{Digest, Sha256};

pub struct Response {
    pub status: u16,
    pub content_type: &'static str,
    pub body: Vec<u8>,
    pub cache_control: &'static str,
    pub content_encoding: Option<&'static str>,
    pub etag: Option<String>,
}

#[derive(Clone)]
struct Entry {
    stamp: (u64, Option<SystemTime>),
    data: Vec<u8>,
    etag: String,
    gzip: Option<Vec<u8>>,
    /// For a page: the assets it versioned and the ETags they had.
    versioned: Vec<(PathBuf, String)>,
}

#[derive(Default)]
pub struct StaticFiles {
    cache: Mutex<HashMap<PathBuf, Entry>>,
}

impl StaticFiles {
    pub fn response(&self, root: Option<&Path>, method: &str, target: &str, accept_encoding: Option<&str>, if_none_match: Option<&str>) -> Response {
        if method != "GET" && method != "HEAD" {
            return plain(405, "method not allowed\n");
        }
        let Some(root) = root else { return plain(404, "web client not bundled\n") };
        let Some(file) = resolve(target, root) else { return plain(404, "not found\n") };
        let ext = file.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
        let want_gzip = accepts_gzip(accept_encoding) && gzipable(&ext);
        let is_page = matches!(ext.as_str(), "html" | "htm");
        let Some(entry) = self.served(&file, root, is_page, want_gzip) else { return plain(404, "not found\n") };
        let content_type = content_type(&ext);
        let cache_control = if is_page {
            "no-cache"
        } else if target.contains("?v=") {
            "public, max-age=31536000, immutable"
        } else {
            "no-cache"
        };
        if if_none_match == Some(entry.etag.as_str()) {
            return Response { status: 304, content_type, body: Vec::new(), cache_control, content_encoding: None, etag: Some(entry.etag) };
        }
        let (body, content_encoding) = match (want_gzip, entry.gzip) {
            (true, Some(gz)) => (gz, Some("gzip")),
            _ => (entry.data, None),
        };
        Response { status: 200, content_type, body, cache_control, content_encoding, etag: Some(entry.etag) }
    }

    fn served(&self, file: &Path, root: &Path, is_page: bool, gzip: bool) -> Option<Entry> {
        let mut cache = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        let mut entry = if is_page { page(&mut cache, file, root)? } else { asset(&mut cache, file)? };
        if gzip && entry.gzip.is_none() {
            entry.gzip = gzip_bytes(&entry.data);
            cache.insert(file.to_path_buf(), entry.clone());
        }
        Some(entry)
    }
}

fn stamp(file: &Path) -> Option<(u64, Option<SystemTime>)> {
    let m = std::fs::metadata(file).ok()?;
    (!m.is_dir()).then(|| (m.len(), m.modified().ok()))
}

fn asset(cache: &mut HashMap<PathBuf, Entry>, file: &Path) -> Option<Entry> {
    let Some(stamp) = stamp(file) else {
        cache.remove(file);
        return None;
    };
    if let Some(hit) = cache.get(file).filter(|e| e.stamp == stamp) {
        return Some(hit.clone());
    }
    let data = std::fs::read(file).ok()?;
    let entry = Entry { stamp, etag: etag(&data), data, gzip: None, versioned: Vec::new() };
    cache.insert(file.to_path_buf(), entry.clone());
    Some(entry)
}

fn page(cache: &mut HashMap<PathBuf, Entry>, file: &Path, root: &Path) -> Option<Entry> {
    let Some(stamp) = stamp(file) else {
        cache.remove(file);
        return None;
    };
    if let Some(hit) = cache.get(file).filter(|e| e.stamp == stamp).cloned() {
        if hit.versioned.iter().all(|(f, tag)| asset(cache, f).is_some_and(|a| &a.etag == tag)) {
            return Some(hit);
        }
    }
    let raw = std::fs::read(file).ok()?;
    let mut versioned = Vec::new();
    let data = version_assets(&raw, file, root, |url| {
        let tag = asset(cache, url)?.etag;
        versioned.push((url.to_path_buf(), tag.clone()));
        Some(tag)
    });
    let entry = Entry { stamp, etag: etag(&data), data, gzip: None, versioned };
    cache.insert(file.to_path_buf(), entry.clone());
    Some(entry)
}

/// Quoted `./…​.js|.mjs|.css` references with nothing after the extension
/// become `./name.js?v=<first 12 hex of its ETag>`.
fn version_assets(page: &[u8], file: &Path, root: &Path, mut tag: impl FnMut(&Path) -> Option<String>) -> Vec<u8> {
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let re = RE.get_or_init(|| regex::Regex::new(r#"(["'])(\./[A-Za-z0-9_\-./]+\.(?:js|mjs|css))["']"#).unwrap());
    let Ok(text) = std::str::from_utf8(page) else { return page.to_vec() };
    let base = file.parent().unwrap_or(root);
    let root = std::fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf());
    let mut out = String::with_capacity(text.len() + 256);
    let mut cursor = 0;
    for caps in re.captures_iter(text) {
        let (Some(open), Some(m)) = (caps.get(1), caps.get(2)) else { continue };
        // The closing quote must match the opening one.
        if text.as_bytes().get(m.end()) != Some(&open.as_str().as_bytes()[0]) {
            continue;
        }
        let Ok(url) = std::fs::canonicalize(base.join(&m.as_str()[2..])) else { continue };
        if !url.starts_with(&root) {
            continue;
        }
        let Some(t) = tag(&url) else { continue };
        out.push_str(&text[cursor..m.end()]);
        out.push_str("?v=");
        out.push_str(&t.trim_matches('"')[..12.min(t.trim_matches('"').len())]);
        cursor = m.end();
    }
    if cursor == 0 {
        return page.to_vec();
    }
    out.push_str(&text[cursor..]);
    out.into_bytes()
}

/// The file a request target names under `root`, confined to it.
pub fn resolve(target: &str, root: &Path) -> Option<PathBuf> {
    let path = target.split(['?', '#']).next().unwrap_or("/");
    let path = percent_encoding::percent_decode_str(path).decode_utf8().ok()?;
    let rel = path.strip_prefix('/')?;
    let rel = if rel.is_empty() || rel.ends_with('/') { format!("{rel}index.html") } else { rel.to_string() };
    if rel.split('/').any(|seg| seg == "..") {
        return None;
    }
    let root = std::fs::canonicalize(root).ok()?;
    let candidate = std::fs::canonicalize(root.join(&rel)).ok()?;
    if !candidate.starts_with(&root) {
        return None;
    }
    if candidate.is_dir() {
        let index = candidate.join("index.html");
        return index.is_file().then_some(index);
    }
    Some(candidate)
}

fn content_type(ext: &str) -> &'static str {
    match ext {
        "html" | "htm" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" | "map" => "application/json; charset=utf-8",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "ico" => "image/x-icon",
        "woff2" => "font/woff2",
        "woff" => "font/woff",
        "wasm" => "application/wasm",
        "txt" | "md" => "text/plain; charset=utf-8",
        _ => "application/octet-stream",
    }
}

fn gzipable(ext: &str) -> bool {
    matches!(ext, "html" | "htm" | "js" | "mjs" | "css" | "svg" | "json" | "map" | "txt" | "md" | "wasm")
}

fn accepts_gzip(header: Option<&str>) -> bool {
    header.is_some_and(|h| {
        h.split(',').any(|tok| {
            let mut parts = tok.split(';').map(str::trim);
            parts.next().is_some_and(|n| n.eq_ignore_ascii_case("gzip")) && !parts.any(|p| p.replace(' ', "") == "q=0")
        })
    })
}

fn etag(data: &[u8]) -> String {
    format!("\"{}\"", hex::encode(Sha256::digest(data)))
}

fn gzip_bytes(data: &[u8]) -> Option<Vec<u8>> {
    if data.is_empty() {
        return None;
    }
    let mut z = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    z.write_all(data).ok()?;
    z.finish().ok()
}

fn plain(status: u16, body: &str) -> Response {
    Response { status, content_type: "text/plain; charset=utf-8", body: body.as_bytes().to_vec(), cache_control: "no-cache", content_encoding: None, etag: None }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pages_version_their_scripts_and_paths_stay_inside() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("index.html"), r#"<script src="./a.js"></script><script src='./missing.js'></script>"#).unwrap();
        std::fs::write(dir.path().join("a.js"), "x").unwrap();
        let s = StaticFiles::default();
        let r = s.response(Some(dir.path()), "GET", "/", Some("gzip"), None);
        assert_eq!(r.status, 200);
        assert_eq!(r.content_encoding, Some("gzip"));
        let plain = s.response(Some(dir.path()), "GET", "/index.html", None, None);
        let body = String::from_utf8(plain.body).unwrap();
        assert!(body.contains("./a.js?v="), "{body}");
        assert!(body.contains("'./missing.js'"));
        let again = s.response(Some(dir.path()), "GET", "/", None, plain.etag.as_deref());
        assert_eq!(again.status, 304);
        assert_eq!(s.response(Some(dir.path()), "GET", "/../etc/passwd", None, None).status, 404);
        assert_eq!(s.response(Some(dir.path()), "GET", "/a.js?v=abc", None, None).cache_control, "public, max-age=31536000, immutable");
        assert_eq!(s.response(Some(dir.path()), "POST", "/", None, None).status, 405);
    }
}

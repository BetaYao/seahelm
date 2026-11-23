//! Dropped images attached to an agent's prompt the way the agent pastes
//! them itself — the image on the clipboard, then its paste-image key — so a
//! drop lands as an attachment (Claude Code's `[Image #1]`) rather than a
//! path, as the macOS app's `AgentImagePaste` does.
//!
//! macOS only. Claude Code, Codex and OpenCode take a clipboard PNG on
//! ctrl+v there (Claude Code reads it through `osascript … «class PNGf»`,
//! which GPUI's `public.png` write satisfies). GPUI's X11 and Wayland
//! clipboards write text only, and on Windows it writes the registered
//! "PNG" format but no CF_DIB, which Claude Code's PowerShell read does not
//! see: there, and for every other agent and every non-image, paths are
//! typed as before.

use std::path::{Path, PathBuf};
use std::time::Duration;

/// How long the agent gets to read the clipboard before the next image
/// replaces it. Claude Code shells out to osascript for every paste.
pub const PASTE_INTERVAL: Duration = Duration::from_millis(800);
/// After the last image, before the user's clipboard comes back.
pub const RESTORE_AFTER: Duration = Duration::from_millis(1500);

/// The paste-image key, as typed: ctrl+v.
pub const PASTE_KEY: &str = "ctrl-v";

/// Whether drops on a pane running `agent` (seahelm-core's agent type) are
/// attached rather than typed. The macOS app's set; Cursor Agent attaches
/// from a typed path instead.
pub fn supports(agent: &str) -> bool {
    crate::platform::MAC && matches!(agent, "claudeCode" | "codex" | "opencode")
}

/// An image by its extension; PDFs and other documents are not.
pub fn is_image(path: &Path) -> bool {
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or_default().to_ascii_lowercase();
    matches!(ext.as_str(), "png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp" | "tif" | "tiff" | "heic" | "heif")
}

const PNG_SIGNATURE: &[u8] = &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// PNG bytes for an image file: the file itself when it is a PNG, else
/// re-encoded with its EXIF orientation applied. HEIC, which the `image`
/// crate does not read, goes through macOS's `sips`. None when it cannot be
/// decoded.
pub fn png_for(path: &Path) -> Option<Vec<u8>> {
    let data = std::fs::read(path).ok().filter(|d| !d.is_empty())?;
    if data.starts_with(PNG_SIGNATURE) {
        return Some(data);
    }
    reencode(&data).or_else(|| sips(path))
}

fn reencode(data: &[u8]) -> Option<Vec<u8>> {
    use image::ImageDecoder;
    let mut decoder = image::ImageReader::new(std::io::Cursor::new(data)).with_guessed_format().ok()?.into_decoder().ok()?;
    let orientation = decoder.orientation().ok();
    let mut img = image::DynamicImage::from_decoder(decoder).ok()?;
    if let Some(o) = orientation {
        img.apply_orientation(o);
    }
    let mut out = Vec::new();
    img.write_to(&mut std::io::Cursor::new(&mut out), image::ImageFormat::Png).ok()?;
    Some(out)
}

fn sips(path: &Path) -> Option<Vec<u8>> {
    if !crate::platform::MAC {
        return None;
    }
    let out = std::env::temp_dir().join(format!("seahelm-drop-{}-{:x}.png", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).ok()?.as_nanos()));
    let ok = std::process::Command::new("sips")
        .args(["-s", "format", "png"])
        .arg(path)
        .arg("--out")
        .arg(&out)
        .output()
        .is_ok_and(|o| o.status.success());
    let png = ok.then(|| std::fs::read(&out).ok()).flatten();
    let _ = std::fs::remove_file(&out);
    png.filter(|p| p.starts_with(PNG_SIGNATURE))
}

/// The drop, split: PNGs to attach, in order, and the files that follow as
/// paths (non-images, undecodable images). Reads files: off the UI thread.
pub fn split(paths: &[PathBuf]) -> (Vec<Vec<u8>>, Vec<PathBuf>) {
    let mut images = Vec::new();
    let mut rest = Vec::new();
    for p in paths {
        match is_image(p).then(|| png_for(p)).flatten() {
            Some(png) => images.push(png),
            None => rest.push(p.clone()),
        }
    }
    (images, rest)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn images_by_extension() {
        assert!(is_image(Path::new("/a/shot.PNG")));
        assert!(is_image(Path::new("/a/photo.heic")));
        assert!(!is_image(Path::new("/a/doc.pdf")));
        assert!(!is_image(Path::new("/a/noext")));
    }

    #[test]
    fn only_agents_that_paste_images_take_them() {
        assert_eq!(supports("claudeCode"), crate::platform::MAC);
        assert!(!supports("cursor"));
        assert!(!supports(""));
    }

    #[test]
    fn a_drop_splits_into_pngs_and_paths() {
        let dir = std::env::temp_dir().join(format!("gpui-image-paste-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // A 2×1 JPEG, made here, comes back as a PNG; a PNG as itself.
        let jpeg = dir.join("a.jpg");
        image::RgbImage::from_pixel(2, 1, image::Rgb([200, 10, 10])).save(&jpeg).unwrap();
        let png = dir.join("b.png");
        image::RgbImage::from_pixel(1, 1, image::Rgb([0, 0, 0])).save(&png).unwrap();
        let broken = dir.join("c.png");
        std::fs::write(&broken, b"not an image").unwrap();
        let pdf = dir.join("d.pdf");
        std::fs::write(&pdf, b"%PDF").unwrap();
        let (images, rest) = split(&[jpeg, png.clone(), broken.clone(), pdf.clone()]);
        assert_eq!(images.len(), 2);
        assert!(images.iter().all(|i| i.starts_with(PNG_SIGNATURE)));
        assert_eq!(images[1], std::fs::read(&png).unwrap());
        assert_eq!(image::load_from_memory(&images[0]).unwrap().width(), 2);
        assert_eq!(rest, vec![broken, pdf]);
        let _ = std::fs::remove_dir_all(&dir);
    }
}

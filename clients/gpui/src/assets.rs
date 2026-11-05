//! Icons, compiled in. Lucide (ISC) stands in for the SF Symbols the macOS
//! app uses, which only Apple platforms may draw; `spinner-arc` and the
//! Windows caption glyphs (`caption-*`) are our own.

use std::borrow::Cow;

use gpui::{AssetSource, Result, SharedString};

macro_rules! icons {
    ($($name:literal),* $(,)?) => {
        &[$(($name, include_bytes!(concat!("../assets/icons/", $name, ".svg")) as &[u8])),*]
    };
}

const ICONS: &[(&str, &[u8])] = icons![
    "contrast", "sailboat", "folder", "diff", "panel-left", "folder-plus", "group", "plus", "x",
    "git-merge", "ship-wheel", "chevron-right", "pause", "play", "share", "columns-2", "git-branch",
    "trash-2", "spinner-arc", "merge", "chevron-down", "chevron-left", "refresh-cw", "caption-min", "caption-max", "caption-restore", "caption-close",
];

pub struct Assets;

impl AssetSource for Assets {
    fn load(&self, path: &str) -> Result<Option<Cow<'static, [u8]>>> {
        let name = path.trim_start_matches("icons/").trim_end_matches(".svg");
        Ok(ICONS.iter().find(|(n, _)| *n == name).map(|(_, bytes)| Cow::Borrowed(*bytes)))
    }

    fn list(&self, _path: &str) -> Result<Vec<SharedString>> {
        Ok(ICONS.iter().map(|(n, _)| SharedString::from(format!("icons/{n}.svg"))).collect())
    }
}

pub fn icon(name: &str) -> SharedString {
    SharedString::from(format!("icons/{name}.svg"))
}

//! seahelm-gpui: a prototype seahelm client drawn with GPUI.
//!
//!   seahelm-gpui [--session NAME] [-- CMD...]
//!
//! Attaches to (creating if needed) one seahelmd session and draws it.
//! `SEAHELM_GPUI_STATS=1` prints frame times and input throughput.

mod assets;
mod core_client;
mod fleet;
mod fonts;
mod keys;
mod platform;
mod session;
mod split;
mod terminal_view;
mod theme;
mod tokens;
mod workspace;

use std::borrow::Cow;

use gpui::{
    point, prelude::*, px, size, App, Application, Bounds, Focusable, TitlebarOptions, WindowBounds, WindowDecorations, WindowOptions,
};

use terminal_view::TerminalView;
use workspace::Workspace;

fn main() {
    let mut args = std::env::args().skip(1);
    let mut name: Option<String> = None;
    let mut cmd = Vec::new();
    while let Some(a) = args.next() {
        match a.as_str() {
            "--session" => name = args.next(),
            "--" => cmd = args.by_ref().collect(),
            other => {
                eprintln!("seahelm-gpui: unknown argument {other}");
                std::process::exit(2);
            }
        }
    }
    // `--session NAME`: one bare terminal, for measuring; otherwise the
    // whole window.
    if let Some(name) = &name {
        if let Err(e) = session::ensure(name, &cmd) {
            eprintln!("seahelm-gpui: {e:#}");
            std::process::exit(1);
        }
    }

    Application::new().with_assets(assets::Assets).run(move |cx: &mut App| {
        load_fonts(cx);
        // Start as the system is, as the app's `terminal_theme_mode = app`
        // does; the contrast button flips it.
        theme::set_dark(!matches!(cx.window_appearance(), gpui::WindowAppearance::Light | gpui::WindowAppearance::VibrantLight));
        workspace::bind_keys(cx);
        let bounds = Bounds::centered(None, size(px(1200.), px(800.)), cx);
        let options = WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(bounds)),
            titlebar: Some(TitlebarOptions {
                title: Some("Seahelm".into()),
                // macOS: the traffic lights over our header. Windows: no
                // caption at all; the header draws its own buttons
                // (`workspace::caption_buttons`). Linux: the window
                // manager's decorations, header below them.
                appears_transparent: !cfg!(target_os = "linux"),
                traffic_light_position: Some(point(px(12.), px(13.))),
            }),
            window_decorations: Some(WindowDecorations::Server),
            window_min_size: Some(size(px(600.), px(400.))),
            ..Default::default()
        };
        match name.clone() {
            Some(name) => {
                let window = cx
                    .open_window(options, |_, cx| {
                        cx.new(|cx| {
                            let mut v = TerminalView::new(name, cx);
                            v.font_size = px(fonts::terminal_size());
                            v
                        })
                    })
                    .expect("open window");
                window.update(cx, |v, window, cx| window.focus(&v.focus_handle(cx))).ok();
            }
            None => {
                cx.open_window(options, |_, cx| cx.new(Workspace::new)).expect("open window");
            }
        }
        cx.activate(true);
    });
}

/// The app's own face, bundled as the macOS app bundles it.
fn load_fonts(cx: &mut App) {
    let fonts: Vec<Cow<'static, [u8]>> = vec![
        Cow::Borrowed(include_bytes!("../../../Resources/Fonts/JetBrainsMono-Regular.ttf")),
        Cow::Borrowed(include_bytes!("../../../Resources/Fonts/JetBrainsMono-Medium.ttf")),
        Cow::Borrowed(include_bytes!("../../../Resources/Fonts/JetBrainsMono-Bold.ttf")),
    ];
    if let Err(e) = cx.text_system().add_fonts(fonts) {
        eprintln!("seahelm-gpui: fonts: {e:#}");
    }
}

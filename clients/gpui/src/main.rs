//! seahelm-gpui: a prototype seahelm client drawn with GPUI.
//!
//!   seahelm-gpui [--session NAME] [-- CMD...]
//!
//! Attaches to (creating if needed) one seahelmd session and draws it.
//! `SEAHELM_GPUI_STATS=1` prints frame times and input throughput.

// A release build on Windows is a window, not a console program: started from
// the Start menu it would otherwise open a console beside itself. Its child
// processes are started with `platform::command`, which keeps them from
// opening consoles of their own.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod agents;
mod assets;
mod core_client;
mod fleet;
mod fonts;
mod gateway_client;
mod gateway_page;
mod keys;
mod labels;
mod notify;
mod platform;
mod session;
mod settings_page;
mod side_panel;
mod split;
mod terminal_text;
mod terminal_view;
mod text_input;
mod theme;
mod tokens;
mod updater;
mod user_config;
mod workspace;
mod worktree_git;

use std::borrow::Cow;

use gpui::{
    point, prelude::*, px, size, App, Application, Bounds, Focusable, TitlebarOptions, WindowBounds, WindowDecorations, WindowOptions,
};

use terminal_view::TerminalView;
use workspace::Workspace;

fn main() {
    // Before any thread or child: the sessions we start must not report as
    // the pane this client was launched from.
    seahelmd::inherited::scrub();
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
        text_input::bind_keys(cx);
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
                updater::start();
            }
        }
        // The last window closed is the client done: with no Dock icon to
        // bring a window back, staying up would only leave an invisible
        // process. Sessions live on in seahelmd.
        cx.on_window_closed(|cx| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();
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

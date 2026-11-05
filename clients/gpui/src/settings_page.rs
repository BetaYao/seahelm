//! Settings, in the main area (the sidebar header's gear): what this client
//! can set of what seahelm-core reads from `config.json` (`user_config`),
//! the same keys the macOS app's Settings write, so the two agree.
//!
//! - First Mate: `autopilot_enabled`. The core re-reads it and starts or
//!   stops First Mate on its own.
//! - Agents seahelm starts (new worktrees, forks): `agent_yolo`, without
//!   permission prompts.
//! - Agent hooks: `seahelm-core install-hooks` again (it also runs at
//!   launch), with what it said.

use gpui::{div, prelude::*, px, ClickEvent, Context, FontWeight, Window};
use serde_json::json;

use crate::core_client;
use crate::gateway_page::{button, card, muted, section_head};
use crate::theme;
use crate::tokens::{self, SYSTEM};
use crate::user_config;

pub struct SettingsPage {
    first_mate: bool,
    yolo: bool,
    /// The last thing done here, and whether it went well.
    note: Option<(String, bool)>,
    busy: bool,
}

impl SettingsPage {
    pub fn new(_cx: &mut Context<Self>) -> Self {
        let mut p = Self { first_mate: false, yolo: false, note: None, busy: false };
        p.reload();
        p
    }

    /// From the file again: the macOS app may have changed it meanwhile.
    pub fn reload(&mut self) {
        self.first_mate = user_config::flag("autopilot_enabled");
        self.yolo = user_config::flag("agent_yolo");
    }

    fn set(&mut self, key: &'static str, on: bool, done: &str, cx: &mut Context<Self>) {
        match user_config::set(key, json!(on)) {
            Ok(()) => self.note = Some((done.to_string(), true)),
            Err(e) => self.note = Some((format!("Not saved: {e}"), false)),
        }
        self.reload();
        cx.notify();
    }

    fn toggle_first_mate(&mut self, _: &ClickEvent, _: &mut Window, cx: &mut Context<Self>) {
        let on = !self.first_mate;
        self.set("autopilot_enabled", on, if on { "First Mate will start in a moment." } else { "First Mate will stop in a moment." }, cx);
    }

    fn toggle_yolo(&mut self, _: &ClickEvent, _: &mut Window, cx: &mut Context<Self>) {
        let on = !self.yolo;
        self.set("agent_yolo", on, "Applies to the next agent seahelm starts.", cx);
    }

    fn install_hooks(&mut self, _: &ClickEvent, _: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        self.busy = true;
        cx.spawn(async move |this, cx| {
            let r = cx.background_executor().spawn(async { core_client::install_hooks() }).await;
            let _ = this.update(cx, |p, cx| {
                p.busy = false;
                p.note = Some(match r {
                    Ok(said) => (said, true),
                    Err(e) => (format!("install-hooks failed: {e}"), false),
                });
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
}

impl Render for SettingsPage {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let state = |on: bool, yes: &str, no: &str| if on { (tokens::running(), yes.to_string()) } else { (tokens::idle(), no.to_string()) };
        let mut column = div()
            .w_full()
            .max_w(px(680.))
            .flex()
            .flex_col()
            .gap(px(18.))
            .px(px(28.))
            .py(px(24.))
            .font_family(SYSTEM)
            .child(div().text_size(px(17.)).font_weight(FontWeight::SEMIBOLD).text_color(tokens::ink()).child("Settings"))
            .child(muted("Kept in ~/.config/seahelm/config.json with the macOS app's settings; seahelm-core reads them as it goes."))
            .child(card().child(section_head(
                "First Mate",
                "The agent that watches the fleet, answers what it may, and asks you the rest (its cards appear beside the worktrees).",
                self.first_mate,
                state(self.first_mate, "On", "Off"),
                cx.listener(Self::toggle_first_mate),
                "settings-first-mate",
            )))
            .child(card().child(section_head(
                "Skip permission prompts",
                "For agents seahelm starts itself: a new worktree's agent and a fork. Agents you start by hand are not affected.",
                self.yolo,
                state(self.yolo, "Agents start without prompts", "Agents ask before acting"),
                cx.listener(Self::toggle_yolo),
                "settings-yolo",
            )))
            .child(
                card()
                    .child(div().text_size(px(13.)).font_weight(FontWeight::SEMIBOLD).text_color(tokens::ink()).child("Agent hooks"))
                    .child(muted("Claude Code and Codex report to seahelm-core through hooks, installed at launch. Install them again after reinstalling an agent."))
                    .child(
                        div().flex().flex_row().child(
                            button("settings-hooks", if self.busy { "Installing…" } else { "Install hooks again" }, false, self.busy)
                                .on_click(cx.listener(Self::install_hooks)),
                        ),
                    ),
            );
        if let Some((text, ok)) = &self.note {
            column = column.child(div().text_size(px(11.5)).text_color(if *ok { tokens::running() } else { tokens::danger() }).child(text.clone()));
        }
        div()
            .id("settings-page")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .bg(theme::rgb(theme::bg()))
            .flex()
            .flex_col()
            .items_center()
            .child(column)
    }
}

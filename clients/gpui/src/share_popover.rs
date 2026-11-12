//! The main header's share button, as the macOS app has it
//! (`SharePopoverController`): a click mints a link to the focused pane
//! through seahelm-gateway (`share.create`), puts it on the clipboard and
//! opens a popover with the link, how long it lives, and the way to take it
//! back. Settings ▸ Pairing stays one click away for everything else.

use gpui::{anchored, deferred, div, point, prelude::*, px, ClickEvent, Context, FontWeight, MouseButton, Pixels, Point, Window};

use super::Workspace;
use crate::fleet;
use crate::gateway_client::{self as gw, Lifetime, Shared};
use crate::settings_page::SettingsSection;
use crate::tokens::{self, MONO, SYSTEM};

const WIDTH: f32 = 340.;

pub struct SharePopover {
    pane: String,
    at: Point<Pixels>,
    phase: Phase,
    copied: bool,
}

enum Phase {
    Creating,
    Ready(Shared),
    Failed(String),
}

impl Workspace {
    /// A link to the focused pane, on the clipboard, and the popover over it.
    pub(super) fn share_focused_pane(&mut self, e: &ClickEvent, cx: &mut Context<Self>) {
        if self.share.is_some() {
            self.share = None;
            cx.notify();
            return;
        }
        let Some(pane) = self.focused_session() else { return };
        let label = self.share_label(&pane);
        let lifetime = self.share_lifetime;
        self.share = Some(SharePopover { pane: pane.clone(), at: e.position(), phase: Phase::Creating, copied: false });
        cx.notify();
        cx.spawn(async move |this, cx| {
            let p = pane.clone();
            let result = cx.background_executor().spawn(async move { gw::create_share(&p, &label, lifetime) }).await;
            let _ = this.update(cx, |w, cx| {
                let Some(s) = w.share.as_mut().filter(|s| s.pane == pane) else { return };
                match result {
                    Ok(link) => {
                        cx.write_to_clipboard(gpui::ClipboardItem::new_string(link.url.clone()));
                        s.copied = true;
                        s.phase = Phase::Ready(link);
                    }
                    Err(e) => s.phase = Phase::Failed(failure(&e)),
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// What the link is called in Settings ▸ Pairing: the pane's name or
    /// title, else its worktree.
    fn share_label(&self, pane: &str) -> String {
        let facts = self.pane_facts.get(pane);
        let named = facts.and_then(|f| f.custom_title.clone().or(f.display_title.clone())).map(|t| t.trim().to_string());
        if let Some(t) = named.filter(|t| !t.is_empty()) {
            return t;
        }
        self.selected.as_deref().and_then(|id| self.fleet.find(id)).map(|i| i.title.clone()).unwrap_or_else(|| pane.to_string())
    }

    fn close_share(&mut self, cx: &mut Context<Self>) {
        if self.share.take().is_some() {
            cx.notify();
        }
    }

    fn set_share_lifetime(&mut self, lifetime: Lifetime, cx: &mut Context<Self>) {
        self.share_lifetime = lifetime;
        let Some(SharePopover { pane, phase: Phase::Ready(link), .. }) = self.share.as_ref() else { return };
        let (pane, link) = (pane.clone(), link.clone());
        cx.spawn(async move |this, cx| {
            let p = pane.clone();
            let result = cx.background_executor().spawn(async move { gw::set_share_lifetime(&link, &p, lifetime) }).await;
            let _ = this.update(cx, |w, cx| {
                let Some(s) = w.share.as_mut().filter(|s| s.pane == pane) else { return };
                if let Ok(link) = result {
                    s.phase = Phase::Ready(link);
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }

    fn revoke_share(&mut self, all: bool, cx: &mut Context<Self>) {
        let Some(SharePopover { pane, phase: Phase::Ready(link), .. }) = self.share.take() else { return };
        cx.background_executor()
            .spawn(async move {
                let r = if all { gw::revoke_pane_shares(&pane) } else { gw::revoke_share(&link.id) };
                if let Err(e) = r {
                    eprintln!("[share] revoke failed: {e}");
                }
            })
            .detach();
        cx.notify();
    }

    pub(super) fn share_popover(&self, cx: &mut Context<Self>) -> Option<gpui::AnyElement> {
        let s = self.share.as_ref()?;
        let mut body = div()
            .id("share-popover")
            .w(px(WIDTH + 28.))
            .p(px(14.))
            .rounded(px(10.))
            .bg(tokens::sidebar_tint())
            .border_1()
            .border_color(tokens::separator())
            .shadow_lg()
            .flex()
            .flex_col()
            .gap(px(10.))
            .font_family(SYSTEM)
            .text_size(px(12.))
            .text_color(tokens::ink())
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation());
        let title = |t: &str| div().font_weight(FontWeight::SEMIBOLD).text_size(px(13.)).child(t.to_string());
        let small = |t: String, color| div().text_size(px(11.)).text_color(color).child(t);
        match &s.phase {
            Phase::Creating => body = body.child(title("Creating link…")),
            Phase::Failed(e) => body = body.child(title("Could not share this pane")).child(small(e.clone(), tokens::danger())),
            Phase::Ready(link) => {
                body = body.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(2.))
                        .child(title("Link copied"))
                        .child(if link.listening {
                            small("Anyone with it can see and type into this pane, and nothing else.".into(), tokens::ink_dim())
                        } else {
                            small("seahelm-gateway's web access is off, so nothing is listening yet.".into(), tokens::attention())
                        }),
                );
                let url = link.url.clone();
                body = body.child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(px(8.))
                        .pl(px(8.))
                        .pr(px(4.))
                        .py(px(4.))
                        .rounded(px(6.))
                        .border_1()
                        .border_color(tokens::hairline())
                        .child(div().flex_1().min_w_0().overflow_hidden().whitespace_nowrap().text_ellipsis().font_family(MONO).text_size(px(11.)).child(link.url.clone()))
                        .child(small_button("share-copy", if s.copied { "Copied" } else { "Copy" }, false).on_click(cx.listener(move |w, _: &ClickEvent, _, cx| {
                            cx.write_to_clipboard(gpui::ClipboardItem::new_string(url.clone()));
                            if let Some(s) = w.share.as_mut() {
                                s.copied = true;
                            }
                            cx.notify();
                        }))),
                );
                let mut chips = div().flex().flex_row().gap(px(4.));
                for lifetime in Lifetime::ALL {
                    chips = chips.child(
                        small_button(lifetime_id(lifetime), lifetime.label(), lifetime == self.share_lifetime)
                            .on_click(cx.listener(move |w, _: &ClickEvent, _, cx| w.set_share_lifetime(lifetime, cx))),
                    );
                }
                body = body.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(4.))
                        .child(div().flex().flex_row().items_center().child("Expires after").child(div().flex_1()).child(chips))
                        .child(
                            div().flex().flex_row().child(div().flex_1()).child(small(
                                match link.expires_at {
                                    Some(_) => format!("Stops working {}", gw::expires(link.expires_at, fleet::now())),
                                    None => "Works until you revoke it".into(),
                                },
                                tokens::ink_dim(),
                            )),
                        ),
                );
                let others = link.others;
                body = body.child(div().h(px(1.)).bg(tokens::hairline())).child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .when(others > 0, |d| {
                            d.child(
                                text_button("share-revoke-all", &format!("Revoke all {} links to this pane", others + 1), tokens::danger())
                                    .on_click(cx.listener(|w, _: &ClickEvent, _, cx| w.revoke_share(true, cx))),
                            )
                        })
                        .child(div().flex_1())
                        .child(text_button("share-revoke", "Revoke link", tokens::danger()).on_click(cx.listener(|w, _: &ClickEvent, _, cx| w.revoke_share(false, cx)))),
                );
            }
        }
        body = body.child(
            text_button("share-settings", "Pairing settings…", tokens::accent()).on_click(cx.listener(|w, _: &ClickEvent, window: &mut Window, cx| {
                w.share = None;
                w.open_settings(SettingsSection::Pairing, window, cx);
            })),
        );
        Some(
            deferred(
                div()
                    .id("share-backdrop")
                    .absolute()
                    .inset_0()
                    .on_mouse_down(MouseButton::Left, cx.listener(|w, _, _, cx| w.close_share(cx)))
                    .child(anchored().position(point(s.at.x, s.at.y + px(10.))).snap_to_window().child(body)),
            )
            .with_priority(1)
            .into_any_element(),
        )
    }
}

/// The gateway's answer when it is not running reads as a socket error.
fn failure(e: &str) -> String {
    if e.contains("connect") || e.contains("No such file") || e.contains("refused") || e.contains("pipe") {
        "seahelm-gateway is not running.".into()
    } else {
        e.to_string()
    }
}

fn lifetime_id(l: Lifetime) -> &'static str {
    match l {
        Lifetime::Hour => "share-life-hour",
        Lifetime::Day => "share-life-day",
        Lifetime::Week => "share-life-week",
        Lifetime::Never => "share-life-never",
    }
}

fn small_button(id: &'static str, label: &str, selected: bool) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .px(px(8.))
        .h(px(22.))
        .rounded(px(5.))
        .flex()
        .items_center()
        .cursor_pointer()
        .text_size(px(11.))
        .border_1()
        .when(selected, |d| d.border_color(tokens::accent()).bg(tokens::alpha(tokens::accent(), 0.16)))
        .when(!selected, |d| d.border_color(tokens::hairline()).hover(|s| s.bg(tokens::row_hover())))
        .child(label.to_string())
}

fn text_button(id: &'static str, label: &str, color: gpui::Rgba) -> gpui::Stateful<gpui::Div> {
    div().id(id).cursor_pointer().text_size(px(11.)).text_color(color).hover(|s| s.opacity(0.75)).child(label.to_string())
}

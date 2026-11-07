//! seahelm-gateway's settings: the Telegram and Pairing pages of Settings
//! (`settings_page::SettingsSection`), as the macOS app has them under
//! Settings ▸ Pairing and ▸ Telegram, so a Windows or Linux machine can turn
//! on the web client and the Telegram bot without the macOS app. One page
//! entity shows either (`set_section`):
//!
//! - Pairing ▸ Web: on/off, the address, port and public URL, the pairing code, the
//!   devices signed in.
//! - Telegram: on/off, the bot token (checked before it is saved), who may
//!   give orders, and pairing a Telegram account by code.
//! - Pairing ▸ Share links: what is shared, and revoking it.
//!
//! Everything is the gateway's (`gateway.sock`, `gateway_client`); this page
//! keeps nothing but what is being typed.

use std::time::Duration;

use gpui::{div, prelude::*, px, ClickEvent, ClipboardItem, Context, Entity, FontWeight, Rgba, SharedString, Subscription, Window};
use serde_json::json;

use crate::fleet;
use crate::gateway_client::{self as gw, Snapshot};
use crate::settings_page::SettingsSection;
use crate::text_input::{Submitted, TextInput};
use crate::theme;
use crate::tokens::{self, MONO, SYSTEM};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Section {
    Web,
    Telegram,
    Shares,
}

/// A line under a section: what the last action did.
#[derive(Clone)]
struct Note {
    text: String,
    ok: bool,
}

/// A field, and what the page last put in it from the gateway: a refresh
/// overwrites the field only while it still holds that, so typing survives.
struct Field {
    input: Entity<TextInput>,
    synced: String,
}

impl Field {
    fn new(placeholder: &str, cx: &mut Context<GatewayPage>) -> Self {
        let placeholder = placeholder.to_string();
        Self { input: cx.new(|cx| TextInput::new(placeholder, cx)), synced: String::new() }
    }

    fn text(&self, cx: &gpui::App) -> String {
        self.input.read(cx).text().trim().to_string()
    }

    fn sync(&mut self, value: &str, cx: &mut Context<GatewayPage>) {
        if self.input.read(cx).text() == self.synced {
            let v = value.to_string();
            self.input.update(cx, |i, cx| i.set_text(&v, cx));
        }
        self.synced = value.to_string();
    }

    /// After a save: the field holds what was saved, and counts as synced.
    fn saved(&mut self, value: &str, cx: &mut Context<GatewayPage>) {
        self.synced = value.to_string();
        let v = value.to_string();
        self.input.update(cx, |i, cx| i.set_text(&v, cx));
    }
}

pub struct GatewayPage {
    /// Telegram or Pairing.
    section: SettingsSection,
    snap: Snapshot,
    loaded: bool,
    /// Polled only while on screen.
    visible: bool,
    port: Field,
    public_url: Field,
    token: Field,
    users: Field,
    chat: Field,
    notes: [Option<Note>; 3],
    /// A Telegram pairing in progress: (code, deep link).
    pairing: Option<(String, String)>,
    /// "Sign out all devices" was clicked once; the second click does it.
    confirm_revoke_all: bool,
    busy: bool,
    _subscriptions: Vec<Subscription>,
}

fn idx(s: Section) -> usize {
    match s {
        Section::Web => 0,
        Section::Telegram => 1,
        Section::Shares => 2,
    }
}

impl GatewayPage {
    pub fn new(cx: &mut Context<Self>) -> Self {
        let port = Field::new("2783", cx);
        let public_url = Field::new("http://<this machine's LAN address>:<port>", cx);
        let token = Field::new("From @BotFather, e.g. 123456:ABC…", cx);
        token.input.update(cx, |i, cx| i.set_masked(true, cx));
        let users = Field::new("Telegram ids or @usernames, comma-separated", cx);
        let chat = Field::new("Chat id for notices (empty: the first allowed user)", cx);
        let subs = vec![
            cx.subscribe(&port.input, |p, _, _: &Submitted, cx| p.save_web(cx)),
            cx.subscribe(&public_url.input, |p, _, _: &Submitted, cx| p.save_web(cx)),
            cx.subscribe(&token.input, |p, _, _: &Submitted, cx| p.save_token(cx)),
            cx.subscribe(&users.input, |p, _, _: &Submitted, cx| p.save_users(cx)),
            cx.subscribe(&chat.input, |p, _, _: &Submitted, cx| p.save_users(cx)),
        ];
        let this = Self {
            section: SettingsSection::Pairing,
            snap: Snapshot::default(),
            loaded: false,
            visible: false,
            port,
            public_url,
            token,
            users,
            chat,
            notes: [None, None, None],
            pairing: None,
            confirm_revoke_all: false,
            busy: false,
            _subscriptions: subs,
        };
        Self::poll(cx);
        this
    }

    /// Shown or hidden by the workspace; shown reads at once.
    /// Show the Telegram page or the Pairing page (web access, share links).
    pub fn set_section(&mut self, section: SettingsSection, cx: &mut Context<Self>) {
        if self.section != section {
            self.section = section;
            self.confirm_revoke_all = false;
            cx.notify();
        }
    }

    pub fn set_visible(&mut self, visible: bool, cx: &mut Context<Self>) {
        self.visible = visible;
        if visible {
            self.refresh(cx);
        } else {
            self.confirm_revoke_all = false;
        }
    }

    fn poll(cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| loop {
            let visible = match this.read_with(cx, |p, _| p.visible) {
                Ok(v) => v,
                Err(_) => break,
            };
            if visible {
                let snap = cx.background_executor().spawn(async { gw::read() }).await;
                if this.update(cx, |p, cx| p.apply(snap, cx)).is_err() {
                    break;
                }
            }
            cx.background_executor().timer(Duration::from_secs(2)).await;
        })
        .detach();
    }

    fn refresh(&mut self, cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| {
            let snap = cx.background_executor().spawn(async { gw::read() }).await;
            let _ = this.update(cx, |p, cx| p.apply(snap, cx));
        })
        .detach();
    }

    fn apply(&mut self, snap: Snapshot, cx: &mut Context<Self>) {
        if snap.reachable() {
            let c = &snap.config;
            self.port.sync(&c.web.port.to_string(), cx);
            self.public_url.sync(c.web.public_url.as_deref().unwrap_or(""), cx);
            self.users.sync(&c.telegram.allowed_users.join(", "), cx);
            self.chat.sync(c.telegram.default_chat_id.as_deref().unwrap_or(""), cx);
            let ph = if c.telegram.bot_token_set { "A token is set; paste a new one to replace it" } else { "From @BotFather, e.g. 123456:ABC…" };
            self.token.input.update(cx, |i, cx| i.set_placeholder(ph, cx));
            // Someone sent /start <code>: the pairing is done.
            if self.pairing.is_some() && c.telegram.allowed_users.len() > self.snap.config.telegram.allowed_users.len() && self.loaded {
                self.pairing = None;
                self.note(Section::Telegram, "Paired: that account may now give orders.", true);
            }
        }
        if self.snap != snap || !self.loaded {
            self.snap = snap;
            self.loaded = true;
            cx.notify();
        }
    }

    fn note(&mut self, s: Section, text: &str, ok: bool) {
        self.notes[idx(s)] = Some(Note { text: text.to_string(), ok });
    }

    /// Run a gateway call off the UI thread, then say how it went and read
    /// the gateway again. `done` gets the result on the UI thread.
    fn run<T: Send + 'static>(
        &mut self,
        section: Section,
        work: impl FnOnce() -> Result<T, String> + Send + 'static,
        done: impl FnOnce(&mut Self, Result<T, String>, &mut Context<Self>) + 'static,
        cx: &mut Context<Self>,
    ) {
        self.busy = true;
        self.notes[idx(section)] = None;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let result = cx.background_executor().spawn(async move { work() }).await;
            let snap = cx.background_executor().spawn(async { gw::read() }).await;
            let _ = this.update(cx, |p, cx| {
                p.busy = false;
                done(p, result, cx);
                p.apply(snap, cx);
                cx.notify();
            });
        })
        .detach();
    }

    fn start_gateway(&mut self, cx: &mut Context<Self>) {
        self.run(
            Section::Web,
            || {
                crate::core_client::ensure_gateway();
                Ok(())
            },
            |p, _, _| {
                if !p.snap.reachable() {
                    p.note(Section::Web, "Started; waiting for it to answer.", true);
                }
            },
            cx,
        );
    }

    fn set_web_enabled(&mut self, on: bool, cx: &mut Context<Self>) {
        self.run(Section::Web, move || gw::set_config(json!({"web": {"enabled": on}})), |p, r, _| {
            if let Err(e) = r {
                p.note(Section::Web, &e, false)
            }
        }, cx);
    }

    fn save_web(&mut self, cx: &mut Context<Self>) {
        let port_text = self.port.text(cx);
        let Some(port) = gw::parse_port(&port_text) else {
            self.note(Section::Web, "The port is a number from 1 to 65535.", false);
            cx.notify();
            return;
        };
        let url = self.public_url.text(cx);
        let url_value = if url.is_empty() { serde_json::Value::Null } else { json!(url.trim_end_matches('/')) };
        self.run(
            Section::Web,
            move || gw::set_config(json!({"web": {"port": port, "public_url": url_value}})),
            move |p, r, cx| match r {
                Ok(()) => {
                    p.port.saved(&port.to_string(), cx);
                    p.public_url.saved(url.trim_end_matches('/'), cx);
                    p.note(Section::Web, "Saved. The web server restarts on the new address.", true)
                }
                Err(e) => p.note(Section::Web, &e, false),
            },
            cx,
        );
    }

    fn refresh_code(&mut self, cx: &mut Context<Self>) {
        self.run(Section::Web, gw::refresh_code, |p, r, _| match r {
            Ok(()) => p.note(Section::Web, "New code. Devices already signed in stay signed in.", true),
            Err(e) => p.note(Section::Web, &e, false),
        }, cx);
    }

    fn revoke_all(&mut self, cx: &mut Context<Self>) {
        if !self.confirm_revoke_all {
            self.confirm_revoke_all = true;
            cx.notify();
            return;
        }
        self.confirm_revoke_all = false;
        self.run(Section::Web, gw::revoke_all, |p, r, _| match r {
            Ok(()) => p.note(Section::Web, "Every device is signed out, and the code is new.", true),
            Err(e) => p.note(Section::Web, &e, false),
        }, cx);
    }

    fn revoke_device(&mut self, id: String, cx: &mut Context<Self>) {
        self.run(Section::Web, move || gw::revoke_device(&id), |p, r, _| {
            if let Err(e) = r {
                p.note(Section::Web, &e, false)
            }
        }, cx);
    }

    fn set_telegram_enabled(&mut self, on: bool, cx: &mut Context<Self>) {
        self.run(Section::Telegram, move || gw::set_config(json!({"telegram": {"enabled": on}})), |p, r, _| {
            if let Err(e) = r {
                p.note(Section::Telegram, &e, false)
            }
        }, cx);
    }

    /// Checked with Telegram first: a wrong token is never saved.
    fn save_token(&mut self, cx: &mut Context<Self>) {
        let token = self.token.text(cx);
        if token.is_empty() {
            self.note(Section::Telegram, "Paste the bot token from @BotFather first.", false);
            cx.notify();
            return;
        }
        self.run(
            Section::Telegram,
            move || {
                let username = gw::validate_token(&token)?;
                gw::set_config(json!({"telegram": {"bot_token": token}}))?;
                Ok(username)
            },
            |p, r, cx| match r {
                Ok(username) => {
                    p.token.saved("", cx);
                    p.note(Section::Telegram, &format!("Saved: the bot is @{username}."), true)
                }
                Err(e) => p.note(Section::Telegram, &format!("Not saved: {e}"), false),
            },
            cx,
        );
    }

    fn save_users(&mut self, cx: &mut Context<Self>) {
        let users = gw::parse_users(&self.users.text(cx));
        let chat = self.chat.text(cx);
        let chat_value = if chat.is_empty() { serde_json::Value::Null } else { json!(chat) };
        let joined = users.join(", ");
        self.run(
            Section::Telegram,
            move || gw::set_config(json!({"telegram": {"allowed_users": users, "default_chat_id": chat_value}})),
            move |p, r, cx| match r {
                Ok(()) => {
                    p.users.saved(&joined, cx);
                    p.chat.saved(&chat, cx);
                    p.note(Section::Telegram, if joined.is_empty() { "Saved. Nobody may give orders until someone is added." } else { "Saved." }, true)
                }
                Err(e) => p.note(Section::Telegram, &e, false),
            },
            cx,
        );
    }

    fn pair_telegram(&mut self, cx: &mut Context<Self>) {
        self.run(Section::Telegram, gw::pair_begin, |p, r, _| match r {
            Ok(pair) => p.pairing = Some(pair),
            Err(e) => p.note(Section::Telegram, &e, false),
        }, cx);
    }

    fn cancel_pairing(&mut self, cx: &mut Context<Self>) {
        self.pairing = None;
        cx.background_executor().spawn(async { gw::pair_cancel() }).detach();
        cx.notify();
    }

    fn revoke_share(&mut self, id: String, cx: &mut Context<Self>) {
        self.run(Section::Shares, move || gw::revoke_share(&id), |p, r, _| {
            if let Err(e) = r {
                p.note(Section::Shares, &e, false)
            }
        }, cx);
    }

    fn copy(&mut self, section: Section, text: String, what: &str, cx: &mut Context<Self>) {
        cx.write_to_clipboard(ClipboardItem::new_string(text));
        self.note(section, &format!("{what} copied."), true);
        cx.notify();
    }
}

// MARK: drawing

impl Render for GatewayPage {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let mut column = div().w_full().max_w(px(680.)).flex().flex_col().gap(px(18.)).px(px(28.)).py(px(24.)).font_family(SYSTEM);
        column = column.child(self.intro(cx));
        if self.loaded && self.snap.reachable() {
            column = match self.section {
                SettingsSection::Telegram => column.child(self.telegram(cx)),
                _ => column.child(self.web(cx)).child(self.shares(cx)),
            };
        }
        div()
            .id("gateway-page")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .bg(theme::rgb(theme::bg()))
            .flex()
            .flex_col()
            .items_start()
            .child(column)
    }
}

impl GatewayPage {
    fn intro(&self, cx: &mut Context<Self>) -> gpui::AnyElement {
        let head = div()
            .flex()
            .flex_col()
            .gap(px(4.))
            .child(div().text_size(px(17.)).font_weight(FontWeight::SEMIBOLD).text_color(tokens::ink()).child(self.section.title()))
            .child(
                div()
                    .text_size(px(12.))
                    .line_height(px(17.))
                    .text_color(tokens::ink_dim())
                    .child(match self.section {
                        SettingsSection::Telegram => "seahelm-gateway runs your Telegram bot from this machine. Settings take effect at once.",
                        _ => "seahelm-gateway serves the web client from this machine: pair a browser or a phone, and see what is shared. Settings take effect at once.",
                    }),
            );
        if !self.loaded {
            return head.child(muted("Asking seahelm-gateway…")).into_any_element();
        }
        if let Some(err) = &self.snap.error {
            return head
                .child(
                    card()
                        .child(div().text_size(px(12.5)).font_weight(FontWeight::SEMIBOLD).text_color(tokens::danger()).child("seahelm-gateway is not running"))
                        .child(muted(&format!("It did not answer on {} ({err}).", crate::platform::gateway_socket().display())))
                        .child(div().flex().flex_row().child(button("start-gateway", "Start it", true, self.busy).on_click(cx.listener(|p, _: &ClickEvent, _, cx| p.start_gateway(cx)))))
                        .when_some(self.notes[idx(Section::Web)].clone(), |d, n| d.child(note_line(&n))),
                )
                .into_any_element();
        }
        let core = if self.snap.status.core.reachable {
            (tokens::running(), "seahelm-core connected")
        } else {
            (tokens::attention(), "seahelm-core not answering: statuses and cards stop until it does")
        };
        head.child(div().flex().flex_row().items_center().gap(px(6.)).child(dot(core.0)).child(muted(core.1))).into_any_element()
    }

    fn web(&self, cx: &mut Context<Self>) -> gpui::AnyElement {
        let st = &self.snap.status.web;
        let on = self.snap.config.web.enabled;
        let state: (Rgba, String) = match () {
            _ if !on => (tokens::idle(), "Off".into()),
            _ if st.listening => (
                tokens::running(),
                format!("On · {} browser{} connected", st.clients, if st.clients == 1 { "" } else { "s" }),
            ),
            _ => (tokens::danger(), format!("Not listening{}", st.error.as_ref().map(|e| format!(": {e}")).unwrap_or_default())),
        };
        let mut c = card().child(section_head("Web", "Open the fleet from a phone or another computer's browser.", on, state, cx.listener(move |p, _: &ClickEvent, _, cx| p.set_web_enabled(!on, cx)), "toggle-web"));
        if on {
            let address = st.public_url.clone().unwrap_or_default();
            c = c.child(
                row("Address")
                    .child(div().flex_1().min_w_0().font_family(MONO).text_size(px(12.)).text_color(tokens::ink()).child(address.clone()))
                    .when(!address.is_empty(), |d| {
                        d.child(button("copy-address", "Copy", false, false).on_click(cx.listener(move |p, _: &ClickEvent, _, cx| p.copy(Section::Web, address.clone(), "Address", cx))))
                    }),
            );
            // Pairing code: what a new browser types once.
            let code = self.snap.code.clone();
            c = c.child(
                row("Pairing code")
                    .child(
                        div()
                            .flex_1()
                            .font_family(MONO)
                            .text_size(px(18.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens::accent())
                            .child(spaced(&code)),
                    )
                    .child(button("copy-code", "Copy", false, false).on_click(cx.listener(move |p, _: &ClickEvent, _, cx| p.copy(Section::Web, code.clone(), "Code", cx))))
                    .child(button("new-code", "New code", false, self.busy).on_click(cx.listener(|p, _: &ClickEvent, _, cx| p.refresh_code(cx)))),
            );
        }
        c = c
            .child(row("Port").child(div().w(px(90.)).child(self.port.input.clone())).child(div().w(px(8.))).child(muted("Public URL")).child(div().flex_1().min_w_0().child(self.public_url.input.clone())))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(8.))
                    .child(muted("Set a public URL when a tunnel or proxy serves this machine (https://gw.example.com)."))
                    .child(div().flex_1())
                    .child(button("save-web", "Save", true, self.busy).on_click(cx.listener(|p, _: &ClickEvent, _, cx| p.save_web(cx)))),
            );
        // Devices.
        let now = fleet::now();
        let mut devices = div().flex().flex_col().gap(px(2.));
        if self.snap.devices.is_empty() {
            devices = devices.child(muted("No device has signed in yet."));
        }
        for d in &self.snap.devices {
            let id = d.id.clone();
            let seen = d.last_seen_at.map(|t| gw::ago(t, now)).unwrap_or_else(|| "never".into());
            devices = devices.child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(8.))
                    .py(px(4.))
                    .child(dot(if d.connected { tokens::running() } else { tokens::idle() }))
                    .child(div().text_size(px(12.)).text_color(tokens::ink()).child(if d.label.is_empty() { "Device".to_string() } else { d.label.clone() }))
                    .child(muted(&format!("{} · seen {seen}", via(&d.via))))
                    .child(div().flex_1())
                    .child(button(SharedString::from(format!("revoke-{}", d.id)), "Sign out", false, self.busy).on_click(cx.listener(move |p, _: &ClickEvent, _, cx| p.revoke_device(id.clone(), cx)))),
            );
        }
        let revoke_label = if self.confirm_revoke_all { "Click again to sign out every device" } else { "Sign out all devices" };
        c = c
            .child(div().h(px(1.)).bg(tokens::hairline()))
            .child(div().text_size(px(11.5)).font_weight(FontWeight::SEMIBOLD).text_color(tokens::ink_dim()).child(format!("Devices · {}", self.snap.devices.len())))
            .child(devices)
            .when(!self.snap.devices.is_empty(), |d| {
                d.child(div().flex().flex_row().child(danger_button("revoke-all", revoke_label, self.busy).on_click(cx.listener(|p, _: &ClickEvent, _, cx| p.revoke_all(cx)))))
            })
            .when_some(self.notes[idx(Section::Web)].clone(), |d, n| d.child(note_line(&n)));
        c.into_any_element()
    }

    fn telegram(&self, cx: &mut Context<Self>) -> gpui::AnyElement {
        let st = &self.snap.status.telegram;
        let cfg = &self.snap.config.telegram;
        let on = cfg.enabled;
        let state: (Rgba, String) = match () {
            _ if !on => (tokens::idle(), "Off".into()),
            _ if !cfg.bot_token_set => (tokens::attention(), "No bot token".into()),
            _ if st.connected => (tokens::running(), format!("Connected as @{}", st.bot_username.clone().unwrap_or_default())),
            _ => (tokens::danger(), format!("Not connected{}", st.error.as_ref().map(|e| format!(": {e}")).unwrap_or_default())),
        };
        let mut c = card()
            .child(section_head("Telegram", "Orders, notices and cards through a Telegram bot of your own.", on, state, cx.listener(move |p, _: &ClickEvent, _, cx| p.set_telegram_enabled(!on, cx)), "toggle-telegram"))
            .child(
                row("Bot token")
                    .child(div().flex_1().min_w_0().child(self.token.input.clone()))
                    .child(button("save-token", "Check & save", true, self.busy).on_click(cx.listener(|p, _: &ClickEvent, _, cx| p.save_token(cx)))),
            )
            .child(row("Allowed").child(div().flex_1().min_w_0().child(self.users.input.clone())))
            .child(
                row("Notices to")
                    .child(div().flex_1().min_w_0().child(self.chat.input.clone()))
                    .child(button("save-users", "Save", true, self.busy).on_click(cx.listener(|p, _: &ClickEvent, _, cx| p.save_users(cx)))),
            );
        if cfg.allowed_users.is_empty() {
            c = c.child(muted("Nobody is allowed yet, so the bot obeys nobody. Add yourself, or pair your account below."));
        }
        c = match &self.pairing {
            Some((code, link)) => {
                let bot = st.bot_username.clone().unwrap_or_else(|| "the bot".into());
                let link_copy = link.clone();
                c.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(6.))
                        .p(px(10.))
                        .rounded(px(8.))
                        .bg(tokens::alpha(tokens::accent(), 0.07))
                        .child(div().text_size(px(12.)).text_color(tokens::ink()).child(format!("Send this to @{bot} from the Telegram account to add:")))
                        .child(div().font_family(MONO).text_size(px(16.)).font_weight(FontWeight::SEMIBOLD).text_color(tokens::accent()).child(format!("/start {code}")))
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap(px(8.))
                                .child(div().flex_1().min_w_0().font_family(MONO).text_size(px(11.)).text_color(tokens::ink_dim()).child(link.clone()))
                                .child(button("copy-link", "Copy link", false, false).on_click(cx.listener(move |p, _: &ClickEvent, _, cx| p.copy(Section::Telegram, link_copy.clone(), "Link", cx))))
                                .child(button("cancel-pair", "Cancel", false, false).on_click(cx.listener(|p, _: &ClickEvent, _, cx| p.cancel_pairing(cx)))),
                        )
                        .child(muted("Waiting for it… this page updates when it arrives.")),
                )
            }
            None => c.child(
                div().flex().flex_row().child(
                    button("pair-telegram", "Pair my Telegram account", false, self.busy || !st.connected).on_click(cx.listener(|p, _: &ClickEvent, _, cx| p.pair_telegram(cx))),
                ),
            ),
        };
        c.when_some(self.notes[idx(Section::Telegram)].clone(), |d, n| d.child(note_line(&n))).into_any_element()
    }

    fn shares(&self, cx: &mut Context<Self>) -> gpui::AnyElement {
        let now = fleet::now();
        let mut list = div().flex().flex_col().gap(px(2.));
        if self.snap.shares.is_empty() {
            list = list.child(muted("Nothing is shared. A share link opens one pane to someone without a pairing code."));
        }
        for s in &self.snap.shares {
            let id = s.id.clone();
            let who = s.recipient.clone().or(s.label.clone()).unwrap_or_default();
            list = list.child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(8.))
                    .py(px(4.))
                    .child(div().font_family(MONO).text_size(px(11.5)).text_color(tokens::ink()).child(s.pane_session_key.clone()))
                    .when(!who.is_empty(), |d| d.child(muted(&format!("for {who}"))))
                    .child(muted(&gw::expires(s.expires_at, now)))
                    .child(div().flex_1())
                    .child(button(SharedString::from(format!("revoke-share-{}", s.id)), "Revoke", false, self.busy).on_click(cx.listener(move |p, _: &ClickEvent, _, cx| p.revoke_share(id.clone(), cx)))),
            );
        }
        card()
            .child(div().text_size(px(13.)).font_weight(FontWeight::SEMIBOLD).text_color(tokens::ink()).child(format!("Share links · {}", self.snap.shares.len())))
            .child(list)
            .when_some(self.notes[idx(Section::Shares)].clone(), |d, n| d.child(note_line(&n)))
            .into_any_element()
    }
}

pub(crate) fn card() -> gpui::Div {
    div()
        .flex()
        .flex_col()
        .gap(px(10.))
        .p(px(14.))
        .rounded(px(10.))
        .border_1()
        .border_color(tokens::hairline())
        .bg(tokens::sidebar_tint())
}

pub(crate) fn section_head(
    title: &str,
    blurb: &str,
    on: bool,
    state: (Rgba, String),
    toggle: impl Fn(&ClickEvent, &mut Window, &mut gpui::App) + 'static,
    id: &'static str,
) -> gpui::Div {
    div()
        .flex()
        .flex_row()
        .items_start()
        .gap(px(10.))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .flex_col()
                .gap(px(3.))
                .child(div().text_size(px(13.)).font_weight(FontWeight::SEMIBOLD).text_color(tokens::ink()).child(title.to_string()))
                .child(muted(blurb))
                .child(div().flex().flex_row().items_center().gap(px(6.)).child(dot(state.0)).child(div().text_size(px(11.5)).text_color(state.0).child(state.1))),
        )
        .child(switch(id, on).on_click(toggle))
}

fn row(label: &str) -> gpui::Div {
    div()
        .flex()
        .flex_row()
        .items_center()
        .gap(px(8.))
        .child(div().w(px(92.)).flex_none().text_size(px(12.)).text_color(tokens::ink_dim()).child(label.to_string()))
}

pub(crate) fn muted(text: &str) -> gpui::Div {
    div().text_size(px(11.5)).line_height(px(16.)).text_color(tokens::ink_faint()).child(text.to_string())
}

pub(crate) fn dot(c: Rgba) -> gpui::Div {
    div().size(px(7.)).flex_none().rounded_full().bg(c)
}

fn note_line(n: &Note) -> gpui::Div {
    div().text_size(px(11.5)).line_height(px(16.)).text_color(if n.ok { tokens::running() } else { tokens::danger() }).child(n.text.clone())
}

fn switch(id: &'static str, on: bool) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .flex_none()
        .w(px(34.))
        .h(px(20.))
        .rounded_full()
        .p(px(2.))
        .cursor_pointer()
        .bg(if on { tokens::accent() } else { tokens::alpha(tokens::ink(), 0.18) })
        .flex()
        .flex_row()
        .when(on, |d| d.justify_end())
        .child(div().size(px(16.)).rounded_full().bg(gpui::white()))
}

pub(crate) fn button(id: impl Into<SharedString>, label: &str, primary: bool, disabled: bool) -> gpui::Stateful<gpui::Div> {
    let id: SharedString = id.into();
    let tint = if primary { tokens::accent() } else { tokens::ink_dim() };
    div()
        .id(id)
        .flex_none()
        .px(px(10.))
        .h(px(26.))
        .rounded(px(6.))
        .flex()
        .items_center()
        .text_size(px(12.))
        .border_1()
        .border_color(tokens::alpha(tint, if primary { 0.6 } else { 0.35 }))
        .text_color(if disabled { tokens::ink_faint() } else { tint })
        .when(primary, |d| d.bg(tokens::alpha(tint, 0.1)))
        .when(!disabled, |d| d.cursor_pointer().hover(|s| s.bg(tokens::alpha(tint, 0.18))))
        .when(disabled, |d| d.opacity(0.6))
        .child(label.to_string())
}

fn danger_button(id: &'static str, label: &str, disabled: bool) -> gpui::Stateful<gpui::Div> {
    let tint = tokens::danger();
    div()
        .id(id)
        .px(px(10.))
        .h(px(26.))
        .rounded(px(6.))
        .flex()
        .items_center()
        .text_size(px(12.))
        .border_1()
        .border_color(tokens::alpha(tint, 0.4))
        .text_color(tint)
        .when(!disabled, |d| d.cursor_pointer().hover(|s| s.bg(tokens::alpha(tint, 0.12))))
        .child(label.to_string())
}

/// A sign-in route as a person would say it.
fn via(v: &str) -> &'static str {
    match v {
        "code" => "pairing code",
        "telegram" => "Telegram",
        "legacy" => "paired before the gateway",
        _ => "signed in",
    }
}

/// "25526063" → "2552 6063", easier to read off a screen.
fn spaced(code: &str) -> String {
    let chars: Vec<char> = code.chars().collect();
    chars.chunks(4).map(|c| c.iter().collect::<String>()).collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_read_in_fours() {
        assert_eq!(spaced("25526063"), "2552 6063");
        assert_eq!(spaced("1234567890"), "1234 5678 90");
        assert_eq!(spaced(""), "");
    }
}

//! Everything the bot says goes out through one queue, in order. In order
//! matters: a draft sent before a message already queued would be wiped the
//! moment that message lands. A draft is a snapshot, so a burst of them
//! queued behind a long send goes out as one call, the newest.

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::{mpsc, oneshot};

use super::api::{Bot, Button};
use super::{format, lock, Adapter};

/// Attempts per chunk before the rest of the message is given up.
const SEND_ATTEMPTS: usize = 3;

pub(super) enum Op {
    /// Markdown, rendered to HTML, chunked; buttons under the last chunk,
    /// whose id comes back.
    Send { chat: String, text: String, buttons: Vec<Button>, done: Option<oneshot::Sender<Option<i64>>> },
    Edit { chat: String, message: i64, text: String },
    Delete { chat: String, message: i64 },
    SetButtons { chat: String, message: i64, buttons: Vec<Button> },
    /// The newest pending draft for this chat.
    Draft { chat: String },
}

pub(super) struct PendingDraft {
    text: String,
    can_stop: bool,
}

impl Adapter {
    pub(super) async fn run_outbox(self: Arc<Self>, mut rx: mpsc::UnboundedReceiver<Op>) {
        while let Some(op) = rx.recv().await {
            let Some(live) = self.live() else {
                if let Op::Send { done: Some(done), .. } = op {
                    let _ = done.send(None);
                }
                continue;
            };
            let bot = live.bot;
            match op {
                Op::Send { chat, text, buttons, done } => {
                    let id = self.send_now(&bot, &chat, &text, &buttons).await;
                    if let Some(done) = done {
                        let _ = done.send(id);
                    }
                }
                Op::Edit { chat, message, text } => {
                    // Unretried and quiet: an edit to the same text and one
                    // that came too fast are both Telegram saying "no", and
                    // the next update replaces this one anyway.
                    let html = format::html(&text);
                    if let Err(e) = bot.edit_message_text(&chat, message, &html, true).await {
                        if e.is_bad_request() && !e.is_not_modified() {
                            let _ = bot.edit_message_text(&chat, message, &format::strip_html(&html), false).await;
                        }
                    }
                }
                Op::Delete { chat, message } => {
                    let _ = bot.delete_message(&chat, message).await;
                }
                Op::SetButtons { chat, message, buttons } => match bot.set_reply_markup(&chat, message, &buttons).await {
                    Ok(()) => {}
                    Err(e) if e.is_not_modified() => {}
                    Err(e) => eprintln!("seahelm-gateway: telegram: buttons on {chat}/{message}: {e}"),
                },
                Op::Draft { chat } => {
                    let Some(d) = lock(&self.drafts).remove(&chat) else { continue };
                    // One message's worth: a draft is a glance, never chunked.
                    let html: String = format::html(&d.text).chars().take(format::MAX_MESSAGE_LENGTH).collect();
                    match bot.send_message_draft(&chat, super::progress::BOARD_DRAFT_ID, &html, true, d.can_stop).await {
                        Ok(()) => {}
                        Err(e) if e.is_chat_gone() => self.chat_gone(&chat),
                        Err(e) if e.is_bad_request() => {
                            let _ = bot.send_message_draft(&chat, super::progress::BOARD_DRAFT_ID, &format::strip_html(&html), false, d.can_stop).await;
                        }
                        Err(e) => eprintln!("seahelm-gateway: telegram: draft to {chat}: {e}"),
                    }
                }
            }
        }
    }

    async fn send_now(&self, bot: &Bot, chat: &str, markdown: &str, buttons: &[Button]) -> Option<i64> {
        let chunks = format::chunk(&format::html(markdown), format::MAX_MESSAGE_LENGTH);
        let mut last = None;
        let n = chunks.len();
        for (i, chunk) in chunks.iter().enumerate() {
            // The keyboard belongs under the end of what it is about.
            let b: &[Button] = if i + 1 == n { buttons } else { &[] };
            match self.send_chunk(bot, chat, chunk, b).await {
                Some(id) => last = Some(id),
                None => {
                    // Say how much was lost: an answer cut short with nothing
                    // to mark the cut reads as all the agent said.
                    eprintln!("seahelm-gateway: telegram: gave up with {} of {n} chunk(s) unsent to {chat}", n - i);
                    return None;
                }
            }
        }
        last
    }

    /// One chunk, retried: a multi-part answer that loses its middle is
    /// worse than one that arrives late.
    async fn send_chunk(&self, bot: &Bot, chat: &str, chunk: &str, buttons: &[Button]) -> Option<i64> {
        for attempt in 1..=SEND_ATTEMPTS {
            match bot.send_message(chat, chunk, true, buttons).await {
                Ok(id) => return Some(id),
                Err(e) if e.is_chat_gone() => {
                    eprintln!("seahelm-gateway: telegram: {chat} is gone: {e}");
                    self.chat_gone(chat);
                    return None;
                }
                // Telegram is strict about its HTML: rather than lose the
                // message over a stray tag, resend the same words flat.
                Err(e) if e.is_bad_request() => {
                    return match bot.send_message(chat, &format::strip_html(chunk), false, buttons).await {
                        Ok(id) => Some(id),
                        Err(e) => {
                            eprintln!("seahelm-gateway: telegram: send to {chat} failed (flat): {e}");
                            None
                        }
                    };
                }
                Err(e) => {
                    eprintln!("seahelm-gateway: telegram: send attempt {attempt}/{SEND_ATTEMPTS} to {chat} failed: {e}");
                    if attempt < SEND_ATTEMPTS {
                        tokio::time::sleep(Duration::from_secs(1)).await;
                    }
                }
            }
        }
        None
    }

    /// Send, and wait for the id of the message the buttons hang under.
    pub(super) async fn send(&self, chat: &str, markdown: &str, buttons: Vec<Button>) -> Option<i64> {
        let (tx, rx) = oneshot::channel();
        self.outbox.send(Op::Send { chat: chat.to_string(), text: markdown.to_string(), buttons, done: Some(tx) }).ok()?;
        rx.await.ok().flatten()
    }

    pub(super) fn say(&self, chat: &str, markdown: &str) {
        let _ = self.outbox.send(Op::Send { chat: chat.to_string(), text: markdown.to_string(), buttons: Vec::new(), done: None });
    }

    pub(super) fn say_with(&self, chat: &str, markdown: &str, buttons: Vec<Button>) {
        let _ = self.outbox.send(Op::Send { chat: chat.to_string(), text: markdown.to_string(), buttons, done: None });
    }

    pub(super) fn edit(&self, chat: &str, message: i64, markdown: &str) {
        let _ = self.outbox.send(Op::Edit { chat: chat.to_string(), message, text: markdown.to_string() });
    }

    pub(super) fn delete(&self, chat: &str, message: i64) {
        let _ = self.outbox.send(Op::Delete { chat: chat.to_string(), message });
    }

    pub(super) fn set_buttons(&self, chat: &str, message: i64, buttons: Vec<Button>) {
        let _ = self.outbox.send(Op::SetButtons { chat: chat.to_string(), message, buttons });
    }

    pub(super) fn draft(&self, chat: &str, markdown: &str, can_stop: bool) {
        let queued = {
            let mut d = lock(&self.drafts);
            d.insert(chat.to_string(), PendingDraft { text: markdown.to_string(), can_stop }).is_some()
        };
        if !queued {
            let _ = self.outbox.send(Op::Draft { chat: chat.to_string() });
        }
    }
}

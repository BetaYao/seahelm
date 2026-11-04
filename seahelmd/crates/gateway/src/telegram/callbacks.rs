//! The short tokens chat buttons carry, and what each stands for.
//!
//! Telegram caps `callback_data` at 64 bytes and a button's meaning does not
//! fit (a card id, an option that is a whole sentence), so the button
//! carries a token and the meaning stays here. Memory only: a message lives
//! in the chat's history for good and its buttons with it, so a tap can come
//! from last week; tokens die with the run, and a tap that resolves to
//! nothing is answered as stale rather than replayed against a fleet that
//! has moved on.

use std::collections::{HashMap, VecDeque};

#[derive(Debug, Clone, PartialEq)]
pub enum Action {
    /// Run this line through the command language, as if typed.
    Command(String),
    /// Pick a card's option, by its index in the card's labels.
    CardOption { card: String, index: usize },
    /// Leave a card waiting without answering it.
    DismissCard { card: String },
}

impl Action {
    fn card(&self) -> Option<&str> {
        match self {
            Action::Command(_) => None,
            Action::CardOption { card, .. } | Action::DismissCard { card } => Some(card),
        }
    }
}

#[derive(Debug, Default)]
pub struct Registry {
    actions: HashMap<String, Action>,
    /// Mint order, so eviction takes the oldest.
    order: VecDeque<String>,
    next: u64,
}

/// Enough for a long session's live cards and listings; past it the oldest
/// token goes (its buttons have scrolled out of what anyone taps).
pub const CAPACITY: usize = 2000;

impl Registry {
    pub fn mint(&mut self, action: Action) -> String {
        self.next += 1;
        let token = radix36(self.next);
        self.actions.insert(token.clone(), action);
        self.order.push_back(token.clone());
        while self.order.len() > CAPACITY {
            if let Some(old) = self.order.pop_front() {
                self.actions.remove(&old);
            }
        }
        token
    }

    pub fn action(&self, token: &str) -> Option<&Action> {
        self.actions.get(token)
    }

    /// Retire every button of a card: once it is answered, the option text
    /// must not be typed into the pane a second time by a late tap.
    pub fn retire(&mut self, card: &str) {
        let stale: Vec<String> = self.actions.iter().filter(|(_, a)| a.card() == Some(card)).map(|(k, _)| k.clone()).collect();
        if stale.is_empty() {
            return;
        }
        for t in &stale {
            self.actions.remove(t);
        }
        self.order.retain(|t| !stale.contains(t));
    }
}

fn radix36(mut n: u64) -> String {
    const DIGITS: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut out = Vec::new();
    loop {
        out.push(DIGITS[(n % 36) as usize]);
        n /= 36;
        if n == 0 {
            break;
        }
    }
    out.reverse();
    String::from_utf8(out).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mints_short_unique_tokens() {
        let mut r = Registry::default();
        let a = r.mint(Action::Command("/go #1".into()));
        let b = r.mint(Action::CardOption { card: "c".into(), index: 0 });
        assert_ne!(a, b);
        assert_eq!(a, "1");
        assert_eq!(r.action(&a), Some(&Action::Command("/go #1".into())));
        assert_eq!(radix36(36), "10");
    }

    #[test]
    fn retires_a_cards_buttons_only() {
        let mut r = Registry::default();
        let cmd = r.mint(Action::Command("/status".into()));
        let opt = r.mint(Action::CardOption { card: "c1".into(), index: 1 });
        let dis = r.mint(Action::DismissCard { card: "c1".into() });
        let other = r.mint(Action::DismissCard { card: "c2".into() });
        r.retire("c1");
        assert!(r.action(&opt).is_none());
        assert!(r.action(&dis).is_none());
        assert!(r.action(&cmd).is_some());
        assert!(r.action(&other).is_some());
    }

    #[test]
    fn evicts_the_oldest_past_capacity() {
        let mut r = Registry::default();
        let first = r.mint(Action::Command("a".into()));
        for _ in 0..CAPACITY {
            r.mint(Action::Command("b".into()));
        }
        assert!(r.action(&first).is_none());
        assert_eq!(r.actions.len(), CAPACITY);
    }
}

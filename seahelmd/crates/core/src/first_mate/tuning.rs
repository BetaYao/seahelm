//! Bounded, persisted tuning of questions, never grants.
use super::lang::Text;
use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct State {
    pub n: usize,
    pub m: u32,
    pub expiry_days: u32,
    pub daily_cap: u32,
    pub accepted: u32,
    pub declined: u32,
    pub promotions_yes: u32,
    pub promotions_no: u32,
    pub fast: u32,
    pub late: u32,
    pub answered: u32,
    pub expired: u32,
}
impl Default for State {
    fn default() -> Self {
        Self {
            n: 3,
            m: 5,
            expiry_days: 3,
            daily_cap: 3,
            accepted: 0,
            declined: 0,
            promotions_yes: 0,
            promotions_no: 0,
            fast: 0,
            late: 0,
            answered: 0,
            expired: 0,
        }
    }
}
#[derive(Clone, Copy)]
pub enum Evidence {
    Suggestion(bool),
    Promotion(bool),
    Answer,
    Expired,
    Demotion,
}

impl State {
    pub fn clamp(&mut self) {
        self.n = self.n.clamp(2, 10);
        self.m = self.m.clamp(3, 20);
        self.expiry_days = self.expiry_days.clamp(1, 7);
        self.daily_cap = self.daily_cap.clamp(1, 5);
    }
    pub fn record(&mut self, evidence: Evidence, latency: Option<f64>) -> Vec<Text> {
        self.clamp();
        let mut notes = Vec::new();
        match evidence {
            Evidence::Expired => {
                self.expired += 1;
                self.answered = 0;
            }
            Evidence::Demotion => {
                self.promotions_no += 1;
                self.promotions_yes = 0;
            }
            evidence => {
                self.answered += 1;
                self.expired = 0;
                match evidence {
                    Evidence::Promotion(true) => {
                        self.promotions_yes += 1;
                        self.promotions_no = 0;
                    }
                    Evidence::Promotion(false) => {
                        self.promotions_no += 1;
                        self.promotions_yes = 0;
                    }
                    Evidence::Suggestion(true) => {
                        self.accepted += 1;
                        self.declined = 0;
                    }
                    Evidence::Suggestion(false) => {
                        self.declined += 1;
                        self.accepted = 0;
                    }
                    _ => {}
                }
                if let Some(age) = latency {
                    if age < 3600.0 {
                        self.fast += 1;
                        self.late = 0;
                    } else if age > 86400.0 {
                        self.late += 1;
                        self.fast = 0;
                    }
                }
            }
        }
        macro_rules! adjust {
            ($counter:ident, $field:ident, $delta:expr, $lo:expr, $hi:expr, $reason:expr, $zh:expr) => {
                if self.$counter >= 6 {
                    self.$counter = 0;
                    let old = self.$field;
                    self.$field = ((old as i64 + $delta).clamp($lo, $hi)) as _;
                    if old != self.$field {
                        notes.push(Text::new($reason, $zh));
                    }
                }
            };
        }
        adjust!(
            accepted,
            n,
            -1,
            2,
            10,
            "I'll suggest these clean-ups sooner: you accepted the last six suggestions.",
            "你接受了最近六次清理建议，以后我会更早提出这类建议。"
        );
        adjust!(
            declined,
            n,
            1,
            2,
            10,
            "I'll wait for more evidence before suggesting clean-ups: you declined the last six.",
            "最近六次清理建议你都没有采纳，以后我会等证据更多时再提议。"
        );
        adjust!(
            promotions_yes,
            m,
            -1,
            3,
            20,
            "I'll offer automation sooner: you accepted the last six promotions.",
            "你接受了最近六次升级，以后我会更早向你提议自动处理。"
        );
        adjust!(
            promotions_no,
            m,
            1,
            3,
            20,
            "I'll wait for more approvals before offering automation: you declined the last six promotions.",
            "最近六次升级未被采纳或后来降级，以后我会积累更多批准再提议自动处理。"
        );
        adjust!(
            fast,
            expiry_days,
            -1,
            1,
            7,
            "I'll withdraw unanswered cards sooner: you answered six within an hour.",
            "你都在一小时内回答了最近六张卡，以后未回答的卡片会早一些撤下。"
        );
        adjust!(
            late,
            expiry_days,
            1,
            1,
            7,
            "I'll leave cards open longer: you answered six after a day.",
            "你在一天后仍回答了六张卡，以后我会多留一些时间等你回复。"
        );
        adjust!(
            answered,
            daily_cap,
            1,
            1,
            5,
            "I'll allow one more suggestion a day: you answered the last six cards.",
            "你回答了最近六张卡，以后每天可以多提一条建议。"
        );
        adjust!(
            expired,
            daily_cap,
            -1,
            1,
            5,
            "I'll ask less often: six cards expired unanswered.",
            "六张卡未回答而过期，以后每天我会少问一次。"
        );
        notes
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn evidence_moves_questions_within_bounds() {
        let mut s = State::default();
        for _ in 0..120 {
            s.record(Evidence::Promotion(true), Some(1.0));
        }
        assert_eq!((s.m, s.expiry_days, s.daily_cap), (3, 1, 5));
        for _ in 0..120 {
            s.record(Evidence::Expired, None);
        }
        assert_eq!(s.daily_cap, 1);
    }
    #[test]
    fn sparse_or_opposing_evidence_does_not_move_n() {
        let mut s = State::default();
        for _ in 0..20 {
            s.record(Evidence::Suggestion(true), None);
            s.record(Evidence::Suggestion(false), None);
        }
        assert_eq!(s.n, 3);
    }
    #[test]
    fn tuning_round_trips_and_old_state_uses_initial_thresholds() {
        let old: State = serde_json::from_str("{}").unwrap();
        assert_eq!(old, State::default());
        let mut state = old;
        for _ in 0..6 {
            state.record(Evidence::Suggestion(true), Some(30.0));
        }
        let restored: State =
            serde_json::from_str(&serde_json::to_string(&state).unwrap()).unwrap();
        assert_eq!(restored, state);
        assert_eq!(
            (restored.n, restored.expiry_days, restored.daily_cap),
            (2, 2, 4)
        );
    }
    #[test]
    fn demotion_is_not_an_answer_and_does_not_reset_expiries() {
        let mut state = State::default();
        state.record(Evidence::Expired, None);
        state.record(Evidence::Demotion, None);
        assert_eq!(
            (
                state.expired,
                state.answered,
                state.fast,
                state.accepted,
                state.declined
            ),
            (1, 0, 0, 0, 0)
        );
        assert_eq!(state.promotions_no, 1);
        let notes: Vec<_> = (0..6)
            .flat_map(|_| state.record(Evidence::Suggestion(true), Some(10.0)))
            .collect();
        assert!(notes.iter().any(|note| note.zh.contains("更早提出")));
        assert!(notes
            .iter()
            .all(|note| !note.zh.contains("daily_cap") && !note.zh.contains("expiry_days")));
    }
}

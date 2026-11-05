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
impl State {
    pub fn clamp(&mut self) {
        self.n = self.n.clamp(2, 10);
        self.m = self.m.clamp(3, 20);
        self.expiry_days = self.expiry_days.clamp(1, 7);
        self.daily_cap = self.daily_cap.clamp(1, 5);
    }
    pub fn outcome(
        &mut self,
        accepted: bool,
        promotion: bool,
        latency: Option<f64>,
        expired: bool,
    ) -> Vec<Text> {
        self.clamp();
        let mut notes = Vec::new();
        if expired {
            self.expired += 1;
            self.answered = 0;
        } else {
            self.answered += 1;
            self.expired = 0;
            if promotion {
                if accepted {
                    self.promotions_yes += 1;
                    self.promotions_no = 0;
                } else {
                    self.promotions_no += 1;
                    self.promotions_yes = 0;
                }
            } else if accepted {
                self.accepted += 1;
                self.declined = 0;
            } else {
                self.declined += 1;
                self.accepted = 0;
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
        macro_rules! adjust {
            ($counter:ident, $field:ident, $delta:expr, $lo:expr, $hi:expr, $reason:expr, $zh:expr) => {
                if self.$counter >= 6 {
                    self.$counter = 0;
                    let old = self.$field;
                    self.$field = ((old as i64 + $delta).clamp($lo, $hi)) as _;
                    if old != self.$field {
                        notes.push(Text::new(
                            format!(
                                "First Mate tuning: {} {} → {}: {}",
                                stringify!($field),
                                old,
                                self.$field,
                                $reason
                            ),
                            format!(
                                "First Mate 调整：{} 从 {} 改为 {}：{}",
                                stringify!($field),
                                old,
                                self.$field,
                                $zh
                            ),
                        ));
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
            "you accepted the last six suggestions",
            "你接受了最近六次建议"
        );
        adjust!(
            declined,
            n,
            1,
            2,
            10,
            "you declined the last six suggestions",
            "你拒绝了最近六次建议"
        );
        adjust!(
            promotions_yes,
            m,
            -1,
            3,
            20,
            "you accepted the last six promotions",
            "你接受了最近六次升级"
        );
        adjust!(
            promotions_no,
            m,
            1,
            3,
            20,
            "you declined the last six promotions",
            "你拒绝了最近六次升级"
        );
        adjust!(
            fast,
            expiry_days,
            -1,
            1,
            7,
            "you answered six cards within an hour",
            "你在一小时内回答了六张卡"
        );
        adjust!(
            late,
            expiry_days,
            1,
            1,
            7,
            "you answered six cards after a day",
            "你在一天后回答了六张卡"
        );
        adjust!(
            answered,
            daily_cap,
            1,
            1,
            5,
            "you answered the last six cards",
            "你回答了最近六张卡"
        );
        adjust!(
            expired,
            daily_cap,
            -1,
            1,
            5,
            "six cards expired unanswered",
            "六张卡未回答而过期"
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
            s.outcome(true, true, Some(1.0), false);
        }
        assert_eq!((s.m, s.expiry_days, s.daily_cap), (3, 1, 5));
        for _ in 0..120 {
            s.outcome(false, false, None, true);
        }
        assert_eq!(s.daily_cap, 1);
    }
    #[test]
    fn sparse_or_opposing_evidence_does_not_move_n() {
        let mut s = State::default();
        for _ in 0..20 {
            s.outcome(true, false, None, false);
            s.outcome(false, false, None, false);
        }
        assert_eq!(s.n, 3);
    }
    #[test]
    fn tuning_round_trips_and_old_state_uses_initial_thresholds() {
        let old: State = serde_json::from_str("{}").unwrap();
        assert_eq!(old, State::default());
        let mut state = old;
        for _ in 0..6 {
            state.outcome(true, false, Some(30.0), false);
        }
        let restored: State =
            serde_json::from_str(&serde_json::to_string(&state).unwrap()).unwrap();
        assert_eq!(restored, state);
        assert_eq!(
            (restored.n, restored.expiry_days, restored.daily_cap),
            (2, 2, 4)
        );
    }
}

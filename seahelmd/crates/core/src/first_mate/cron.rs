//! A five-field cron expression for `on: { schedule: … }` rules
//! (`CronSchedule.swift`): minute, hour, day of month, month, day of week.
//! `*`, lists, ranges, steps; day of week 0–7 with 0 and 7 both Sunday. As in
//! cron, when both day fields are restricted either may match.

use std::collections::BTreeSet;

use super::clock::Local;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cron {
    minutes: BTreeSet<u32>,
    hours: BTreeSet<u32>,
    days_of_month: BTreeSet<u32>,
    months: BTreeSet<u32>,
    days_of_week: BTreeSet<u32>,
    dom_restricted: bool,
    dow_restricted: bool,
}

impl Cron {
    pub fn parse(expr: &str) -> Option<Self> {
        let f: Vec<&str> = expr.split_whitespace().collect();
        if f.len() != 5 {
            return None;
        }
        Some(Cron {
            minutes: field(f[0], 0, 59)?,
            hours: field(f[1], 0, 23)?,
            days_of_month: field(f[2], 1, 31)?,
            months: field(f[3], 1, 12)?,
            days_of_week: field(f[4], 0, 7)?.into_iter().map(|d| if d == 7 { 0 } else { d }).collect(),
            dom_restricted: f[2] != "*",
            dow_restricted: f[4] != "*",
        })
    }

    pub fn matches(&self, t: &Local) -> bool {
        if !self.minutes.contains(&t.minute) || !self.hours.contains(&t.hour) || !self.months.contains(&t.month) {
            return false;
        }
        let dom = self.days_of_month.contains(&t.day);
        let dow = self.days_of_week.contains(&t.weekday);
        if self.dom_restricted && self.dow_restricted {
            dom || dow
        } else {
            dom && dow
        }
    }
}

fn field(text: &str, lo: u32, hi: u32) -> Option<BTreeSet<u32>> {
    let mut out = BTreeSet::new();
    for part in text.split(',') {
        let (range, step) = match part.split_once('/') {
            Some((r, s)) => (r, s.parse::<u32>().ok().filter(|s| *s > 0)?),
            None => (part, 1),
        };
        let (a, b) = if range == "*" {
            (lo, hi)
        } else if let Some((a, b)) = range.split_once('-') {
            let (a, b) = (a.parse::<u32>().ok()?, b.parse::<u32>().ok()?);
            if a > b || a < lo || b > hi {
                return None;
            }
            (a, b)
        } else {
            let v = range.parse::<u32>().ok().filter(|v| (lo..=hi).contains(v))?;
            (v, if part.contains('/') { hi } else { v })
        };
        out.extend((a..=b).step_by(step as usize));
    }
    (!out.is_empty()).then_some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(month: u32, day: u32, weekday: u32, hour: u32, minute: u32) -> Local {
        Local { year: 2026, month, day, hour, minute, weekday }
    }

    #[test]
    fn weekday_mornings() {
        let c = Cron::parse("0 9 * * 1-5").unwrap();
        assert!(c.matches(&at(11, 3, 2, 9, 0)));
        assert!(!c.matches(&at(11, 8, 0, 9, 0)));
        assert!(!c.matches(&at(11, 3, 2, 9, 1)));
    }

    #[test]
    fn steps_lists_and_sunday_as_seven() {
        let c = Cron::parse("*/15 8,20 * * 7").unwrap();
        assert!(c.matches(&at(1, 4, 0, 20, 45)));
        assert!(!c.matches(&at(1, 4, 0, 20, 50)));
    }

    #[test]
    fn either_day_field_matches_when_both_are_restricted() {
        let c = Cron::parse("0 0 1 * 1").unwrap();
        assert!(c.matches(&at(6, 1, 3, 0, 0)));
        assert!(c.matches(&at(6, 8, 1, 0, 0)));
        assert!(!c.matches(&at(6, 9, 2, 0, 0)));
    }

    #[test]
    fn bad_expressions() {
        for bad in ["", "* * * *", "60 * * * *", "* * * * 8", "*/0 * * * *", "5-1 * * * *"] {
            assert!(Cron::parse(bad).is_none(), "{bad}");
        }
    }
}

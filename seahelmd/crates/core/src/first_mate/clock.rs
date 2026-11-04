//! Local wall-clock time from a Unix timestamp, for cron rules, quiet hours
//! and the ledger's day. The offset is the system's (`usage::local_offset`).

/// A moment as the user's clock shows it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Local {
    pub year: i64,
    pub month: u32,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    /// 0 = Sunday.
    pub weekday: u32,
}

impl Local {
    pub fn at(unix: f64) -> Self {
        Self::with_offset(unix, crate::usage::local_offset(unix))
    }

    pub fn with_offset(unix: f64, offset: i64) -> Self {
        let secs = unix.floor() as i64 + offset;
        let days = secs.div_euclid(86_400);
        let rem = secs.rem_euclid(86_400);
        let (year, month, day) = civil(days);
        Local {
            year,
            month,
            day,
            hour: (rem / 3600) as u32,
            minute: (rem % 3600 / 60) as u32,
            weekday: (days + 4).rem_euclid(7) as u32,
        }
    }

    /// "2026-11-03", the ledger's key.
    pub fn day_key(&self) -> String {
        format!("{:04}-{:02}-{:02}", self.year, self.month, self.day)
    }

    pub fn minute_of_day(&self) -> u32 {
        self.hour * 60 + self.minute
    }
}

/// Days since 1970-01-01 → (year, month, day). Howard Hinnant's algorithm.
fn civil(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = yoe + era * 400 + if month <= 2 { 1 } else { 0 };
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utc_and_offset() {
        // 2026-11-03 09:30 UTC is a Tuesday.
        let t = 1_793_698_200.0;
        let l = Local::with_offset(t, 0);
        assert_eq!((l.year, l.month, l.day, l.hour, l.minute, l.weekday), (2026, 11, 3, 9, 30, 2));
        let east = Local::with_offset(t, 8 * 3600);
        assert_eq!((east.day, east.hour), (3, 17));
        let west = Local::with_offset(t, -10 * 3600);
        assert_eq!((west.day, west.hour, west.weekday), (2, 23, 1));
        assert_eq!(l.day_key(), "2026-11-03");
    }
}

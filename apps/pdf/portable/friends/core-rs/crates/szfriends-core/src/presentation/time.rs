//! Calendar arithmetic for the words about time: a Gregorian calendar in the reader's time zone, computed here rather
//! than by a platform formatter, so the labels never depend on a computer's region settings and the golden fixtures
//! reproduce on every platform (`SZFriendsStrings.m` § Dates).
//!
//! Instants are Unix seconds (`f64`), as the store keeps them.

use std::fmt;
use std::sync::Arc;

/// Where the reader is: the UTC offset in force at each instant. A host gives its own zone's rules
/// ([`TimeZone::from_fn`]); a zone without daylight saving, such as Hong Kong's, is [`TimeZone::fixed`].
#[derive(Clone)]
pub struct TimeZone {
    offset: Arc<dyn Fn(f64) -> i32 + Send + Sync>,
}

impl TimeZone {
    /// A zone always `seconds` east of UTC.
    pub fn fixed(seconds: i32) -> Self {
        Self { offset: Arc::new(move |_| seconds) }
    }

    pub fn utc() -> Self {
        Self::fixed(0)
    }

    /// A zone whose offset east of UTC, in seconds, at a Unix instant is `offset(instant)`.
    pub fn from_fn(offset: impl Fn(f64) -> i32 + Send + Sync + 'static) -> Self {
        Self { offset: Arc::new(offset) }
    }

    pub fn offset_at(&self, instant: f64) -> i32 {
        (self.offset)(instant)
    }

    /// The wall-clock reading at `instant`.
    pub fn civil(&self, instant: f64) -> Civil {
        let local = instant.floor() as i64 + i64::from(self.offset_at(instant));
        Civil::from_unix(local)
    }

    /// Days since 1970-01-01 of the calendar day `instant` falls on here.
    pub fn day_number(&self, instant: f64) -> i64 {
        (instant.floor() as i64 + i64::from(self.offset_at(instant))).div_euclid(86_400)
    }

    /// Whole calendar days from `from` to `to` here: 0 the same day, 1 the next, negative backwards.
    pub fn days_between(&self, from: f64, to: f64) -> i64 {
        self.day_number(to) - self.day_number(from)
    }
}

impl fmt::Debug for TimeZone {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TimeZone").field("offset_now", &self.offset_at(crate::store::unix_now())).finish()
    }
}

impl Default for TimeZone {
    fn default() -> Self {
        Self::utc()
    }
}

/// A wall-clock reading: the date, the time to the second, and the weekday (1 Sunday to 7 Saturday, as
/// Foundation's Gregorian calendar numbers them and the catalog's `weekday.N` keys follow).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Civil {
    pub year: i64,
    pub month: u32,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    pub second: u32,
    pub weekday: u32,
}

impl Civil {
    fn from_unix(seconds: i64) -> Self {
        let days = seconds.div_euclid(86_400);
        let rest = seconds.rem_euclid(86_400);
        let (year, month, day) = civil_from_days(days);
        Self {
            year,
            month,
            day,
            hour: (rest / 3600) as u32,
            minute: (rest % 3600 / 60) as u32,
            second: (rest % 60) as u32,
            // 1970-01-01 was a Thursday (5).
            weekday: ((days + 4).rem_euclid(7) + 1) as u32,
        }
    }
}

/// Howard Hinnant's `civil_from_days`: the proleptic Gregorian date of a day number.
pub fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

/// The day number of a proleptic Gregorian date (`days_from_civil`).
pub fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let m = i64::from(month);
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + i64::from(day) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// RFC 3339 in UTC to the second, as `deadline` and `expires_at` carry instants ("2026-10-12T06:52:00Z").
pub fn rfc3339(instant: f64) -> String {
    let c = Civil::from_unix(instant.floor() as i64);
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", c.year, c.month, c.day, c.hour, c.minute, c.second)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates_round_trip_and_weekdays() {
        for days in [-800_000, -1, 0, 1, 20_738, 2_932_896] {
            let (y, m, d) = civil_from_days(days);
            assert_eq!(days_from_civil(y, m, d), days);
        }
        let hong_kong = TimeZone::fixed(8 * 3600);
        // Monday 12 October 2026, 14:47:48 in Hong Kong.
        let now = (days_from_civil(2026, 10, 12) * 86_400 + 14 * 3600 + 47 * 60 + 48 - 8 * 3600) as f64;
        let civil = hong_kong.civil(now);
        assert_eq!(
            (civil.year, civil.month, civil.day, civil.hour, civil.minute, civil.weekday),
            (2026, 10, 12, 14, 47, 2)
        );
        assert_eq!(rfc3339(now), "2026-10-12T06:47:48Z");
        assert_eq!(hong_kong.days_between(now - 15.0 * 3600.0, now), 1);
    }
}

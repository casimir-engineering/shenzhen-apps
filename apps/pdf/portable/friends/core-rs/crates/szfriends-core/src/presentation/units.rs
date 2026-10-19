//! Durations, countdowns, transfer estimates and sizes, worded as a person would say them (`SZFriendsStrings.m`
//! § Durations, countdowns and estimates, § Sizes).

use super::facts::RouteMethod;
use super::strings::Strings;

/// The relay holds each session to 5 Mbit/s (ADR 0010, 625,000 bytes a second): an estimate there never assumes more.
const RELAY_CAP_BYTES_PER_SECOND: f64 = 625_000.0;
/// What a transfer through the relay measured (about 4 Mbit/s of payload), assumed before a rate is measured.
const RELAY_PAYLOAD_BYTES_PER_SECOND: f64 = 500_000.0;

/// `lround`: half away from zero.
fn lround(value: f64) -> i64 {
    value.round() as i64
}

/// The nearest 5 seconds under a minute ("about" means nearest, not an upper bound), whole minutes under an hour,
/// then hours and minutes: (seconds, minutes, hours).
fn bucket(seconds: f64) -> (i64, i64, i64) {
    let seconds = if seconds > 0.0 { seconds } else { 0.0 };
    let fives = (lround(seconds / 5.0) * 5).max(5);
    if fives < 60 {
        return (fives, 0, 0);
    }
    let minutes = lround(seconds / 60.0).max(1);
    if minutes < 60 {
        return (0, minutes, 0);
    }
    (0, minutes % 60, minutes / 60)
}

/// Only routes slow enough that the person may want to wait for a better one get an estimate.
fn estimate_key(route: RouteMethod) -> Option<&'static str> {
    match route {
        RouteMethod::Bluetooth => Some("estimate.bluetooth"),
        RouteMethod::Relay => Some("estimate.relay"),
        _ => None,
    }
}

impl Strings {
    /// "about 20 s", "about 6 min", "about 1 h 20 min".
    pub fn duration_label(&self, seconds: f64) -> String {
        let (s, m, h) = bucket(seconds);
        if s != 0 {
            return self.text_with("duration.seconds", &[("n", &s.to_string())]);
        }
        if h == 0 {
            return self.text_with("duration.minutes", &[("n", &m.to_string())]);
        }
        if m == 0 {
            return self.text_with("duration.hours", &[("h", &h.to_string())]);
        }
        self.text_with("duration.hours_minutes", &[("h", &h.to_string()), ("m", &m.to_string())])
    }

    /// "about 20 seconds", "about 1 hour 20 minutes".
    pub fn duration_accessibility_label(&self, seconds: f64) -> String {
        let (s, m, h) = bucket(seconds);
        let spoken = if s != 0 {
            self.text_count("unit.second", s, &[])
        } else if h == 0 {
            self.text_count("unit.minute", m, &[])
        } else if m == 0 {
            self.text_count("unit.hour", h, &[])
        } else {
            let first = self.text_count("unit.hour", h, &[]);
            let second = self.text_count("unit.minute", m, &[]);
            self.text_with("unit.pair", &[("first", &first), ("second", &second)])
        };
        self.text_with("duration.about", &[("duration", &spoken)])
    }

    fn countdown_seconds(remaining: f64) -> i64 {
        if remaining > 0.0 {
            remaining.ceil() as i64
        } else {
            0
        }
    }

    /// "4:12", rounded up so it never shows 0:00 while still running.
    pub fn countdown_label(&self, remaining: f64) -> String {
        let total = Self::countdown_seconds(remaining);
        format!("{}:{:02}", total / 60, total % 60)
    }

    /// "4 minutes 12 seconds left".
    pub fn countdown_accessibility_label(&self, remaining: f64) -> String {
        let total = Self::countdown_seconds(remaining);
        let (minutes, seconds) = (total / 60, total % 60);
        let duration = if minutes != 0 && seconds != 0 {
            let first = self.text_count("unit.minute", minutes, &[]);
            let second = self.text_count("unit.second", seconds, &[]);
            self.text_with("unit.pair", &[("first", &first), ("second", &second)])
        } else if minutes != 0 {
            self.text_count("unit.minute", minutes, &[])
        } else {
            self.text_count("unit.second", seconds, &[])
        };
        self.text_with("countdown.left", &[("duration", &duration)])
    }

    /// The rate an estimate on `route` uses: the measured one, except on the relay, where it never exceeds the cap and
    /// is assumed until measured (0 elsewhere: no estimate yet).
    pub fn estimate_bytes_per_second(&self, measured: f64, route: RouteMethod) -> f64 {
        let measured = if measured > 0.0 { measured } else { 0.0 };
        if route != RouteMethod::Relay {
            return measured;
        }
        if measured > 0.0 {
            measured.min(RELAY_CAP_BYTES_PER_SECOND)
        } else {
            RELAY_PAYLOAD_BYTES_PER_SECOND
        }
    }

    /// "Over Bluetooth, about 6 min"; None on fast routes, where no estimate is worth showing.
    pub fn transfer_estimate(&self, bytes: u64, bytes_per_second: f64, route: RouteMethod) -> Option<String> {
        let prefix = self.text(estimate_key(route)?);
        let rate = self.estimate_bytes_per_second(bytes_per_second, route);
        if rate <= 0.0 {
            return Some(prefix); // no rate measured yet: say the route, promise no time
        }
        let duration = self.duration_label(bytes as f64 / rate);
        Some(self.text_with("estimate.with_time", &[("route", &prefix), ("duration", &duration)]))
    }

    /// "over Bluetooth, about 6 minutes".
    pub fn transfer_estimate_accessibility(
        &self,
        bytes: u64,
        bytes_per_second: f64,
        route: RouteMethod,
    ) -> Option<String> {
        let prefix = self.spoken_fragment(&self.text(estimate_key(route)?));
        let rate = self.estimate_bytes_per_second(bytes_per_second, route);
        if rate <= 0.0 {
            return Some(prefix);
        }
        let duration = self.duration_accessibility_label(bytes as f64 / rate);
        Some(self.text_with("estimate.with_time", &[("route", &prefix), ("duration", &duration)]))
    }

    /// Decimal units, as Finder shows them: one decimal below 100 ("2.4 MB", "18.6 MB"), none above ("120 MB").
    pub fn size_label(&self, bytes: u64) -> String {
        if bytes < 1000 {
            return self.text_count("size.bytes", bytes as i64, &[]);
        }
        let kilobytes = lround(bytes as f64 / 1000.0);
        if kilobytes < 1000 {
            return self.text_with("size.kb", &[("n", &kilobytes.to_string())]);
        }
        const UNITS: [&str; 3] = ["size.mb", "size.gb", "size.tb"];
        let mut value = bytes as f64 / 1e6;
        let mut unit = 0;
        while unit < 2 && lround(value) >= 1000 {
            value /= 1000.0;
            unit += 1;
        }
        let number = if value < 99.95 {
            let text = format!("{value:.1}");
            text.strip_suffix(".0").map(str::to_owned).unwrap_or(text)
        } else {
            lround(value).to_string()
        };
        self.text_with(UNITS[unit], &[("n", &number)])
    }
}

//! What each route carried for each transfer, sans-IO (PROTOCOL.md § Fast transfers, Progress by route): the helper
//! counts the file bytes of every PART and CHUNK a session sends or receives, by the transfer they belong to and the
//! session's route, and the views draw the transfer's bar split by those counts, its routes in use right now, a speed
//! that does not jitter and a time left that counts down instead of jumping. The Objective-C helper's
//! `SZFriendsRouteMeter` is the same, rule for rule.
//!
//! Cheap: one map entry per transfer moving, a few adds per frame, and the speed and time left worked out only when a
//! snapshot asks (at most a few times a second).

use std::collections::HashMap;

use szfriends_wire::RouteMethod;

/// A route carried the transfer "right now" when its last bytes are this recent (seconds). Bluetooth's 16 KiB parts
/// come several times a second, the relay's every fraction of a second, so a route in use never blinks out.
pub const ACTIVE_SECONDS: f64 = 1.5;
/// The speed's smoothing: an exponential average over about this many seconds, so the figure moves calmly.
pub const RATE_SECONDS: f64 = 3.0;
/// Samples closer together than this are folded into the next one.
const SAMPLE_SECONDS: f64 = 0.25;
/// No speed is claimed before the first bytes are this old.
const FIRST_RATE_SECONDS: f64 = 1.0;
/// The time left keeps counting down from its last value while a new estimate stays within this share of it (or 2 s).
const LEFT_TOLERANCE: f64 = 0.25;
/// A transfer nothing was counted for in this long is forgotten.
const FORGET_SECONDS: f64 = 120.0;

const ROUTES: [RouteMethod; 5] =
    [RouteMethod::Lan, RouteMethod::PeerToPeerWifi, RouteMethod::Internet, RouteMethod::Bluetooth, RouteMethod::Relay];

fn slot(route: RouteMethod) -> Option<usize> {
    ROUTES.iter().position(|r| *r == route)
}

#[derive(Clone, Debug, Default)]
struct Meter {
    bytes: [u64; 5],
    /// When each route's current run of bytes began, and when it last carried any.
    first: [f64; 5],
    last: [f64; 5],
    total: u64,
    began: f64,
    sample_at: f64,
    sample_total: u64,
    rate: f64,
    /// The time left last shown: when, and how many seconds it said then.
    left: Option<(f64, f64)>,
    touched: f64,
}

/// One transfer's counts as a snapshot shows them.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Reading {
    /// Bytes each route carried, in the routes' fixed order (same Wi-Fi, direct Wi-Fi, Internet, Bluetooth, relay);
    /// routes that carried nothing are left out.
    pub route_bytes: Vec<(RouteMethod, u64)>,
    /// The routes carrying it right now, in the same order.
    pub active: Vec<RouteMethod>,
    /// Smoothed; 0 until a second of bytes was counted.
    pub bytes_per_second: f64,
    /// Seconds left at that speed, counting down steadily; 0 when unknown.
    pub seconds_left: f64,
}

/// Every transfer the helper is moving, by transfer id (the hex of the frames' ID).
#[derive(Debug, Default)]
pub struct RouteMeter {
    transfers: HashMap<String, Meter>,
}

impl RouteMeter {
    pub fn new() -> Self {
        Self::default()
    }

    /// `bytes` of `transfer`'s file went or came on a session over `route`.
    pub fn carried(&mut self, transfer: &str, route: RouteMethod, bytes: u64, now: f64) {
        let Some(i) = slot(route) else { return };
        if bytes == 0 {
            return;
        }
        if !self.transfers.contains_key(transfer) {
            self.transfers.retain(|_, m| now - m.touched < FORGET_SECONDS);
            self.transfers.insert(transfer.to_owned(), Meter { began: now, sample_at: now, ..Meter::default() });
        }
        let m = self.transfers.get_mut(transfer).expect("inserted");
        if m.bytes[i] == 0 || now - m.last[i] > ACTIVE_SECONDS {
            m.first[i] = now;
        }
        m.bytes[i] += bytes;
        m.last[i] = now;
        m.total += bytes;
        m.touched = now;
    }

    /// The transfer is over (saved, cancelled, failed): its counts go.
    pub fn forget(&mut self, transfer: &str) {
        self.transfers.remove(transfer);
    }

    /// The counts of `transfer`, with `remaining` bytes still to go; None when nothing was counted for it.
    pub fn reading(&mut self, transfer: &str, remaining: u64, now: f64) -> Option<Reading> {
        let m = self.transfers.get_mut(transfer)?;
        let dt = now - m.sample_at;
        if dt >= SAMPLE_SECONDS && now - m.began >= FIRST_RATE_SECONDS {
            let instant = (m.total - m.sample_total) as f64 / dt;
            if m.rate > 0.0 {
                m.rate += (1.0 - (-dt / RATE_SECONDS).exp()) * (instant - m.rate);
            } else {
                m.rate = instant;
            }
            m.sample_at = now;
            m.sample_total = m.total;
        }
        let mut reading = Reading { bytes_per_second: m.rate, ..Reading::default() };
        for (i, route) in ROUTES.iter().enumerate() {
            if m.bytes[i] == 0 {
                continue;
            }
            reading.route_bytes.push((*route, m.bytes[i]));
            // In use: carried something lately, and no other route took over since (a route that began after this
            // one's last bytes replaced it, as the direct route replaces the relay: the icons switch at once).
            let recent = now - m.last[i] <= ACTIVE_SECONDS;
            let replaced = (0..ROUTES.len()).any(|j| j != i && m.bytes[j] > 0 && m.first[j] > m.last[i]);
            if recent && !replaced {
                reading.active.push(*route);
            }
        }
        if m.rate > 0.0 && remaining > 0 {
            let estimate = remaining as f64 / m.rate;
            let kept = m.left.map(|(at, said)| said - (now - at)).filter(|predicted| {
                *predicted > 0.0 && (estimate - predicted).abs() <= (predicted * LEFT_TOLERANCE).max(2.0)
            });
            if kept.is_none() {
                m.left = Some((now, estimate));
            }
            reading.seconds_left = kept.unwrap_or(estimate).max(1.0);
        } else {
            m.left = None;
        }
        Some(reading)
    }
}

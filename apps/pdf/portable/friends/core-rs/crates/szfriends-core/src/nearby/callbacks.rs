//! Presence windows, the tag matcher, and Add by ID callback tags (`SZFriendsPresence.m`, the callback days of
//! `SZFriendsNearbyService+RequestByID.m`; ADR 0004 § Presence tags and step 3, Review amendments, 2).
//!
//! Every device that hears REQUEST_BY_ID learns its callback secret, so how long its tags are on the air is how long
//! that device can follow the requester. The stored secret is a master that never leaves this computer: each day of
//! a request's life has its own secret keyed from it, which that day's broadcasts carry; a day's tags go on the air
//! only within six hours of the last broadcast that carried them, and every advertisement carries exactly four
//! callback slots, the real tags padded with random ones kept for the window.

use std::collections::HashMap;

use szfriends_crypto::presence::{self, SECRET_LEN, WINDOW_SECONDS};

use super::limits::CALLBACK_DAY_SECONDS;
use super::Tag;

pub const CALLBACK_TAGS_MAX: usize = 4;
pub const CALLBACK_REQUEST_LIFETIME_SECONDS: f64 = 7.0 * 86_400.0;
pub const CALLBACK_ADVERTISE_WINDOW_SECONDS: f64 = 6.0 * 3600.0;
pub const CALLBACK_SECRET_LIFETIME_SECONDS: f64 = 86_400.0;

/// `w = floor(unix seconds / 900)`.
pub fn window(now: f64) -> i64 {
    presence::window_index(now)
}

/// When the window holding `now` ends: the next tag goes on the air then.
pub fn window_end(now: f64) -> f64 {
    (window(now) + 1) as f64 * WINDOW_SECONDS as f64
}

/// A fresh random secret: ours at first use and on every remove or block, and each Add by ID request's master.
pub fn new_secret() -> [u8; SECRET_LEN] {
    let mut secret = [0u8; SECRET_LEN];
    szfriends_crypto::random_bytes(&mut secret);
    secret
}

/// Maps an advertised tag (presence or callback) to a conversation id (`SZFriendsMakeTagMatcher`): every tag the
/// secrets give for windows w-1, w and w+1. Conversations in sorted order, so in the astronomically unlikely event
/// of a collision the winner is the same every time.
#[derive(Clone, Debug, Default)]
pub struct TagMatcher {
    table: HashMap<Tag, String>,
}

impl TagMatcher {
    pub fn new<'a>(secrets: impl IntoIterator<Item = (&'a str, &'a [u8])>, now: f64) -> Self {
        let mut pairs: Vec<(&str, &[u8])> = secrets.into_iter().collect();
        szfriends_wire::order::sort_by(&mut pairs, |a, b| a.0.cmp(b.0));
        let mut table = HashMap::new();
        let w = window(now);
        for (conversation, secret) in pairs {
            if secret.len() != SECRET_LEN {
                continue;
            }
            for tag in presence::tags_to_match(secret, w) {
                table.entry(tag).or_insert_with(|| conversation.to_owned());
            }
        }
        Self { table }
    }

    pub fn conversation(&self, tag: &Tag) -> Option<&str> {
        self.table.get(tag).map(String::as_str)
    }
}

/// Whole days since an Add by ID request was made (0 on the first day).
pub fn callback_day(created_at: f64, now: f64) -> i64 {
    let age = now - created_at;
    if age > 0.0 {
        (age / CALLBACK_DAY_SECONDS).floor() as i64
    } else {
        0
    }
}

/// BLAKE2b-256 keyed with the master over `"SZFriends callback day v1" || u64be(day)`; `None` for a malformed
/// master (`SZFriendsCallbackSecretForDay`).
pub fn callback_secret_for_day(master: &[u8], day: i64) -> Option<[u8; 32]> {
    if !(16..=64).contains(&master.len()) {
        return None;
    }
    let day = day.max(0) as u64;
    Some(szfriends_crypto::blake2b::<32>(Some(master), &[b"SZFriends callback day v1", &day.to_be_bytes()]))
}

/// One pending Add by ID request as advertising sees it (`SZFriendsPendingCallback`).
#[derive(Clone, Debug, PartialEq)]
pub struct PendingCallback {
    /// That day's secret, never the master.
    pub secret: Vec<u8>,
    pub created_at: f64,
    pub expires_at: f64,
    pub secret_issued_at: f64,
    /// When REQUEST_BY_ID carrying this secret last went to a device; `None` advertises nothing.
    pub last_broadcast_at: Option<f64>,
}

impl PendingCallback {
    fn request_end(&self) -> f64 {
        self.expires_at.min(self.created_at + CALLBACK_REQUEST_LIFETIME_SECONDS)
    }

    fn advertise_end(&self) -> Option<f64> {
        if self.secret.len() != SECRET_LEN {
            return None;
        }
        let broadcast = self.last_broadcast_at?;
        Some(
            self.request_end()
                .min(broadcast + CALLBACK_ADVERTISE_WINDOW_SECONDS)
                .min(self.secret_issued_at + CALLBACK_SECRET_LIFETIME_SECONDS),
        )
    }

    /// Still pending, but its secret is a day old: draw the next day's and broadcast again.
    pub fn needs_fresh_secret(&self, now: f64) -> bool {
        now < self.request_end() && now >= self.secret_issued_at + CALLBACK_SECRET_LIFETIME_SECONDS
    }
}

/// The callback tags to advertise at `now`, one per live request, newest first, at most four.
pub fn tags_to_advertise(pending: &[PendingCallback], now: f64) -> Vec<Tag> {
    let mut live: Vec<&PendingCallback> =
        pending.iter().filter(|p| p.advertise_end().is_some_and(|end| now < end)).collect();
    szfriends_wire::order::sort_by(&mut live, |a, b| b.created_at.total_cmp(&a.created_at));
    let w = window(now);
    live.iter().take(CALLBACK_TAGS_MAX).map(|p| presence::tag(&p.secret, w)).collect()
}

/// The next moment after `now` when what to advertise changes other than at a window boundary.
pub fn next_change(pending: &[PendingCallback], now: f64) -> Option<f64> {
    let mut next: Option<f64> = None;
    for request in pending {
        let request_end = request.request_end();
        let secret_end = request.secret_issued_at + CALLBACK_SECRET_LIFETIME_SECONDS;
        let moments = [request.advertise_end(), (secret_end < request_end).then_some(secret_end), Some(request_end)];
        for moment in moments.into_iter().flatten().filter(|m| *m > now) {
            next = Some(next.map_or(moment, |n: f64| n.min(moment)));
        }
    }
    next
}

/// Exactly four callback slots for one advertisement (`SZFriendsCallbackSlots`): the real tags, and random padding
/// drawn once per window and kept while the advertisement is refreshed within it; a real tag keeps its slot.
#[derive(Clone, Debug, Default)]
pub struct CallbackSlots {
    rotation_key: Option<Vec<u8>>,
    slots: Vec<Tag>,
    real: [bool; CALLBACK_TAGS_MAX],
}

fn random_slot() -> Tag {
    let mut slot = [0u8; 8];
    szfriends_crypto::random_bytes(&mut slot);
    slot
}

impl CallbackSlots {
    /// `rotation_key` names the advertisement's window: the presence tag, or the window index without one.
    pub fn slots(&mut self, tags: &[Tag], rotation_key: &[u8]) -> Vec<Tag> {
        if self.rotation_key.as_deref() != Some(rotation_key) {
            self.rotation_key = Some(rotation_key.to_vec());
            self.slots = (0..CALLBACK_TAGS_MAX).map(|_| random_slot()).collect();
            self.real = [false; CALLBACK_TAGS_MAX];
        }
        let mut live: Vec<Tag> = Vec::new();
        for tag in tags {
            if live.len() < CALLBACK_TAGS_MAX && !live.contains(tag) {
                live.push(*tag);
            }
        }
        // A request that ended frees its slot for fresh padding: its holder must not keep matching us this window.
        for i in 0..CALLBACK_TAGS_MAX {
            if self.real[i] && !live.contains(&self.slots[i]) {
                self.slots[i] = random_slot();
                self.real[i] = false;
            }
        }
        for tag in live {
            if let Some(held) = self.slots.iter().position(|s| *s == tag) {
                if self.real[held] {
                    continue;
                }
            }
            if let Some(free) = (0..CALLBACK_TAGS_MAX).find(|i| !self.real[*i]) {
                self.slots[free] = tag;
                self.real[free] = true;
            }
        }
        self.slots.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(created: f64, broadcast: Option<f64>) -> PendingCallback {
        PendingCallback {
            secret: vec![7; 32],
            created_at: created,
            expires_at: created + CALLBACK_REQUEST_LIFETIME_SECONDS,
            secret_issued_at: created,
            last_broadcast_at: broadcast,
        }
    }

    #[test]
    fn windows() {
        assert_eq!(window(899.9), 0);
        assert_eq!(window(900.0), 1);
        assert_eq!(window(-0.5), -1);
        assert_eq!(window_end(1000.0), 1800.0);
    }

    #[test]
    fn matcher_accepts_three_windows_only() {
        let secret = [5u8; 32];
        let now = 1_000_000.0;
        let matcher = TagMatcher::new([("c1", &secret[..])], now);
        let w = window(now);
        for d in [-1, 0, 1] {
            assert_eq!(matcher.conversation(&presence::tag(&secret, w + d)), Some("c1"));
        }
        assert_eq!(matcher.conversation(&presence::tag(&secret, w + 2)), None);
        let short = TagMatcher::new([("c2", &[1u8; 16][..])], now);
        assert!(short.table.is_empty());
    }

    #[test]
    fn callback_days_and_secrets() {
        assert_eq!(callback_day(100.0, 50.0), 0);
        assert_eq!(callback_day(0.0, 86_399.0), 0);
        assert_eq!(callback_day(0.0, 86_400.0), 1);
        let master = [3u8; 32];
        let day0 = callback_secret_for_day(&master, 0).unwrap();
        assert_ne!(day0, callback_secret_for_day(&master, 1).unwrap());
        assert_eq!(callback_secret_for_day(&master, -4), Some(day0));
        assert!(callback_secret_for_day(&[1; 8], 0).is_none());
    }

    #[test]
    fn advertising_needs_a_broadcast_and_stops_after_six_hours() {
        let now = 10_000.0;
        assert!(tags_to_advertise(&[request(now, None)], now).is_empty());
        let fresh = request(now - 60.0, Some(now - 30.0));
        assert_eq!(tags_to_advertise(std::slice::from_ref(&fresh), now).len(), 1);
        assert!(tags_to_advertise(std::slice::from_ref(&fresh), now + CALLBACK_ADVERTISE_WINDOW_SECONDS).is_empty());
        assert_eq!(
            next_change(std::slice::from_ref(&fresh), now),
            Some(now - 30.0 + CALLBACK_ADVERTISE_WINDOW_SECONDS)
        );
        let five: Vec<_> = (0..5).map(|i| request(now - 100.0 + i as f64, Some(now))).collect();
        assert_eq!(tags_to_advertise(&five, now).len(), 4);
    }

    #[test]
    fn fresh_secret_after_a_day() {
        let r = request(0.0, Some(0.0));
        assert!(!r.needs_fresh_secret(86_399.0));
        assert!(r.needs_fresh_secret(86_400.0));
        assert!(!r.needs_fresh_secret(CALLBACK_REQUEST_LIFETIME_SECONDS));
    }

    #[test]
    fn slots_keep_their_places_and_pad() {
        let mut slots = CallbackSlots::default();
        let first = slots.slots(&[[1; 8]], b"w1");
        assert_eq!(first.len(), 4);
        assert_eq!(first.iter().filter(|s| **s == [1; 8]).count(), 1);
        let place = first.iter().position(|s| *s == [1; 8]).unwrap();
        let second = slots.slots(&[[2; 8], [1; 8]], b"w1");
        assert_eq!(second[place], [1; 8], "a real tag keeps its slot");
        let padding: Vec<_> = first.iter().enumerate().filter(|(i, _)| *i != place).map(|(_, s)| *s).collect();
        assert!(padding.iter().filter(|p| second.contains(p)).count() >= 2, "padding stays within a window");
        let third = slots.slots(&[[2; 8]], b"w1");
        assert!(!third.contains(&[1; 8]), "an ended request's slot is padded afresh");
        let next = slots.slots(&[[2; 8]], b"w2");
        assert!(next.contains(&[2; 8]));
        assert!(!next.iter().any(|s| *s != [2; 8] && third.contains(s)), "a new window draws new padding");
    }
}

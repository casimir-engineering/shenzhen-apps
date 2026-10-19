//! ID attestations (HOST-PROTOCOL.md § ID attestations; `SZFriendsHostAttestation.m`, `attestation.js`): the host's
//! signature over a Friends ID, the person's root key and a UTC day, handed out with every reservation. A holder shows
//! it beside its certificate when it answers an Add by ID, so the requester knows the holder of that ID answered and
//! not just anyone who heard the broadcast. The shared vectors (`server/friends/test/vectors/host-list-v1.json`,
//! "attestations") hold this, the host and the helper to the same bytes and verdicts.

use serde_json::{json, Value};
use szfriends_identity::identity::verify;

use super::codec::{length_prefixed, Field};
use super::list::HostList;
use crate::b64;

pub const DOMAIN: &str = "SZFriends id attestation v1";
/// Good for this many days after the day it was signed (and one day early, for clock skew).
pub const MAX_AGE_DAYS: i64 = 30;
/// Far more than one needs (about 250 bytes): a bound so a peer cannot hand the parser megabytes.
pub const MAX_BYTES: usize = 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Attestation {
    pub host_id: String,
    pub friends_id: String,
    pub identity_key: [u8; 32],
    pub day: String,
    pub signature: [u8; 64],
}

/// `checkAttestation`'s verdicts, the first reason in this order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    Valid,
    Malformed,
    UnknownHost,
    BadSignature,
    WrongHolder,
    Expired,
}

fn host_id_shape(text: &str) -> bool {
    let bytes = text.as_bytes();
    (1..=32).contains(&bytes.len())
        && bytes[0] != b'-'
        && bytes.iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
}

fn friends_id_shape(text: &str) -> bool {
    let words: Vec<&str> = text.split('-').collect();
    (2..=3).contains(&words.len())
        && words.iter().all(|w| (3..=8).contains(&w.len()) && w.bytes().all(|c| c.is_ascii_lowercase()))
}

/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's `days_from_civil`).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = year - i64::from(month <= 2);
    let era = (if year >= 0 { year } else { year - 399 }) / 400;
    let year_of_era = year - era * 400;
    let day_of_year = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

/// The day number of "YYYY-MM-DD" when it is a real calendar day (2026-02-30 is not 2 March).
pub fn day_number(text: &str) -> Option<i64> {
    let b = text.as_bytes();
    let digits = |r: std::ops::Range<usize>| b[r].iter().all(u8::is_ascii_digit);
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' || !digits(0..4) || !digits(5..7) || !digits(8..10) {
        return None;
    }
    let (year, month, day): (i64, i64, i64) =
        (text[0..4].parse().ok()?, text[5..7].parse().ok()?, text[8..].parse().ok()?);
    let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    const LENGTHS: [i64; 12] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if !(1..=12).contains(&month) {
        return None;
    }
    let length = LENGTHS[(month - 1) as usize] + i64::from(month == 2 && leap);
    (1..=length).contains(&day).then(|| days_from_civil(year, month, day))
}

/// What the host signs after the domain.
pub fn signed_message(host_id: &str, friends_id: &str, identity_key: &[u8; 32], day: &str) -> Vec<u8> {
    length_prefixed(&[Field::Text(host_id), Field::Text(friends_id), Field::Bytes(identity_key), Field::Text(day)])
}

impl Attestation {
    /// The wire form, or `None` when any field is missing or malformed.
    pub fn from_value(value: &Value) -> Option<Self> {
        let host_id = value.get("host_id")?.as_str().filter(|t| host_id_shape(t))?;
        let friends_id = value.get("friends_id")?.as_str().filter(|t| friends_id_shape(t))?;
        let day = value.get("day")?.as_str().filter(|t| day_number(t).is_some())?;
        Some(Self {
            host_id: host_id.to_owned(),
            friends_id: friends_id.to_owned(),
            identity_key: b64::decode_array::<32>(value.get("identity_key"))?,
            day: day.to_owned(),
            signature: b64::decode_array::<64>(value.get("sig"))?,
        })
    }

    /// As a holder shows it nearby and keeps it: JSON, at most `MAX_BYTES`.
    pub fn from_bytes(bytes: &[u8]) -> Option<Self> {
        if bytes.is_empty() || bytes.len() > MAX_BYTES {
            return None;
        }
        Self::from_value(&serde_json::from_slice(bytes).ok()?)
    }

    /// The JSON a holder shows (keys sorted, as the helper writes it).
    pub fn encoded(&self) -> Vec<u8> {
        json!({
            "day": self.day,
            "friends_id": self.friends_id,
            "host_id": self.host_id,
            "identity_key": b64::encode_url(&self.identity_key),
            "sig": b64::encode_url(&self.signature),
        })
        .to_string()
        .into_bytes()
    }

    /// Whether a rendezvous host of `list` signed it for `friends_id` and `identity_key`, dated within the window
    /// around `now` (seconds since 1970, UTC).
    pub fn check(&self, list: &HostList, friends_id: &str, identity_key: &[u8; 32], now: f64) -> Verdict {
        let Some(day) = day_number(&self.day) else { return Verdict::Malformed };
        let Some(host) = list.entries.iter().find(|e| e.id == self.host_id && e.rendezvous) else {
            return Verdict::UnknownHost;
        };
        let message = signed_message(&self.host_id, &self.friends_id, &self.identity_key, &self.day);
        if !verify(&self.signature, &message, DOMAIN, &host.public_key) {
            return Verdict::BadSignature;
        }
        if self.friends_id != friends_id || &self.identity_key != identity_key {
            return Verdict::WrongHolder;
        }
        let today = (now / 86_400.0).floor() as i64;
        if day > today + 1 || day < today - MAX_AGE_DAYS {
            return Verdict::Expired;
        }
        Verdict::Valid
    }
}

/// The verdict on a value as it arrived (a reservation's `attestation`, or a peer's field).
pub fn check_value(value: Option<&Value>, list: &HostList, friends_id: &str, key: &[u8; 32], now: f64) -> Verdict {
    match value.and_then(Attestation::from_value) {
        Some(attestation) => attestation.check(list, friends_id, key, now),
        None => Verdict::Malformed,
    }
}

/// What an Add by ID answer's attestation says about it (`SZFriendsJudgeAnswerAttestation`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Answer {
    /// None shown, or one that does not check out: an answer like any other.
    Unattested,
    /// The holder of the ID asked for answered.
    Attested(Attestation),
    /// Another key's attestation: never an honest mistake, since a holder only ever shows its own.
    Refused,
}

/// Judges `presented` on an answer from `key` to an Add by ID for `requested`.
pub fn judge_answer(presented: Option<&[u8]>, list: &HostList, requested: &str, key: &[u8; 32], now: f64) -> Answer {
    let Some(parsed) = presented.filter(|p| !p.is_empty()).and_then(Attestation::from_bytes) else {
        return Answer::Unattested;
    };
    if &parsed.identity_key != key {
        return Answer::Refused;
    }
    match parsed.check(list, requested, key, now) {
        Verdict::Valid => Answer::Attested(parsed),
        _ => Answer::Unattested,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn days_are_real_calendar_days() {
        assert_eq!(day_number("1970-01-01"), Some(0));
        assert_eq!(day_number("2026-10-13"), Some(20_739));
        assert_eq!(day_number("2024-02-29"), Some(19_782));
        for bad in ["2026-02-29", "2026-02-30", "2026-13-01", "2026-00-10", "2026-1-01", "2026/10/13", "2026-10-1x"] {
            assert_eq!(day_number(bad), None, "{bad}");
        }
    }

    #[test]
    fn shapes() {
        assert!(friends_id_shape("maple-river") && friends_id_shape("abc-defghijk-lmn"));
        assert!(!friends_id_shape("maple") && !friends_id_shape("ma-river") && !friends_id_shape("a-b-c-d"));
        assert!(host_id_shape("main-hk") && !host_id_shape("-hk") && !host_id_shape("Main"));
    }
}

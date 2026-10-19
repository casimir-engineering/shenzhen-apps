//! Bluetooth's fixed values and the presence characteristic (`SZFriendsBluetoothPresence.m`, ADR 0004 § Decision):
//! what every Friends device advertises and serves, so a phone, a Linux laptop and a Mac read each other.
//!
//! The presence characteristic's value, version 1:
//!
//! | bytes | field |
//! |---|---|
//! | 0 | version, 1 |
//! | 1 | flags; bit 0: a presence tag follows |
//! | 2..10 | presence tag (zero without one) |
//! | 10..12 | hidden channel PSM, u16 big-endian (0 until published) |
//! | 12..14 | public channel PSM (0 when not visible) |
//! | 14 | callback tag count n, at most 4 |
//! | 15.. | n × 8-byte callback tags |
//!
//! Longer values are accepted, so version 1 can grow fields at the end. The hidden characteristic fills everything
//! but the public PSM; the public characteristic, read while the public UUID is advertised, fills only the public
//! PSM. A reader takes each field only from the characteristic that owns it.

use super::callbacks::CALLBACK_TAGS_MAX;
use super::Tag;

/// The hidden Friends service, always advertised.
pub const SERVICE_UUID: &str = "22FB96F7-C35A-45B5-9673-1CAC64EC8E75";
/// Added to the advertisement during the person's 5 minutes.
pub const PUBLIC_UUID: &str = "C8B26601-A773-4E6D-BC10-BA6F596D92C1";
/// Read: the hidden entry's value.
pub const PRESENCE_CHARACTERISTIC_UUID: &str = "9F2BC83C-9A97-49C4-9F30-19D368A135BA";
/// Read while the public UUID is advertised: only the public PSM.
pub const PUBLIC_CHARACTERISTIC_UUID: &str = "E66577A2-9C37-4D7B-876E-03127666B7DA";

/// Scanning restarts this often: a scan that filters duplicates reports each device once.
pub const SCAN_REFRESH_SECONDS: f64 = 30.0;
/// A presence read stands for re-sightings within its window for this long.
pub const PRESENCE_CACHE_LIFE_SECONDS: f64 = 300.0;
/// Each read is a short connection; this many at once.
pub const MAX_CONCURRENT_READS: usize = 2;
/// A channel replaced at a new window stays published, unadvertised, this long for people already opening it.
pub const CHANNEL_OVERLAP_SECONDS: f64 = 30.0;

const VERSION: u8 = 1;
const FIXED_LENGTH: usize = 15;
const TAG_LEN: usize = 8;

/// One presence characteristic's value.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Presence {
    pub tag: Option<Tag>,
    pub callback_tags: Vec<Tag>,
    pub hidden_psm: u16,
    pub public_psm: u16,
}

impl Presence {
    /// At most four callback tags are kept, as the helper keeps them.
    pub fn new(tag: Option<Tag>, callback_tags: &[Tag], hidden_psm: u16, public_psm: u16) -> Self {
        let callback_tags = callback_tags.iter().take(CALLBACK_TAGS_MAX).copied().collect();
        Self { tag, callback_tags, hidden_psm, public_psm }
    }

    /// The public characteristic's value: only the public PSM.
    pub fn public(public_psm: u16) -> Self {
        Self { public_psm, ..Self::default() }
    }

    pub fn value(&self) -> Vec<u8> {
        let mut value = vec![0u8; FIXED_LENGTH];
        value[0] = VERSION;
        if let Some(tag) = &self.tag {
            value[1] = 1;
            value[2..2 + TAG_LEN].copy_from_slice(tag);
        }
        value[10..12].copy_from_slice(&self.hidden_psm.to_be_bytes());
        value[12..14].copy_from_slice(&self.public_psm.to_be_bytes());
        value[14] = self.callback_tags.len() as u8;
        for tag in &self.callback_tags {
            value.extend_from_slice(tag);
        }
        value
    }

    /// `None` for anything malformed or another version.
    pub fn from_value(value: &[u8]) -> Option<Self> {
        if value.len() < FIXED_LENGTH || value[0] != VERSION {
            return None;
        }
        let count = usize::from(value[14]);
        if count > CALLBACK_TAGS_MAX || value.len() < FIXED_LENGTH + count * TAG_LEN {
            return None;
        }
        let tag_at = |at: usize| -> Tag { value[at..at + TAG_LEN].try_into().expect("8 bytes") };
        Some(Self {
            tag: (value[1] & 1 != 0).then(|| tag_at(2)),
            callback_tags: (0..count).map(|i| tag_at(FIXED_LENGTH + i * TAG_LEN)).collect(),
            hidden_psm: u16::from_be_bytes([value[10], value[11]]),
            public_psm: u16::from_be_bytes([value[12], value[13]]),
        })
    }
}

/// Whether a cached read still stands for a re-sighting: within its window (tags rotate), within its life (callback
/// tags change), and only while the advertisement's public flag agrees with it (visibility started or stopped).
pub fn read_is_fresh(read_at: f64, read_public: bool, now: f64, public: bool) -> bool {
    use super::callbacks::window;
    window(read_at) == window(now) && now - read_at < PRESENCE_CACHE_LIFE_SECONDS && read_public == public
}

const ENDPOINT_PREFIX: &str = "bluetooth:";
const PUBLIC_SUFFIX: &str = "/public";

/// A sighted device's endpoint: a dialing handle made of the radio's identifier for it, never identity.
pub fn endpoint(peripheral: &str, public: bool) -> String {
    format!("{ENDPOINT_PREFIX}{peripheral}{}", if public { PUBLIC_SUFFIX } else { "" })
}

/// The peripheral and entry an endpoint names.
pub fn parse_endpoint(endpoint: &str) -> Option<(&str, bool)> {
    let rest = endpoint.strip_prefix(ENDPOINT_PREFIX)?;
    match rest.strip_suffix(PUBLIC_SUFFIX) {
        Some(peripheral) => Some((peripheral, true)),
        None => Some((rest, false)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn values_round_trip_and_grow_at_the_end() {
        let presence = Presence::new(Some([1; 8]), &[[2; 8], [3; 8], [4; 8], [5; 8], [6; 8]], 0x1234, 0);
        assert_eq!(presence.callback_tags.len(), 4);
        let mut value = presence.value();
        assert_eq!(value.len(), 15 + 32);
        assert_eq!(&value[..2], &[1, 1]);
        assert_eq!(&value[10..15], &[0x12, 0x34, 0, 0, 4]);
        assert_eq!(Presence::from_value(&value), Some(presence.clone()));
        value.extend_from_slice(&[9, 9, 9]);
        assert_eq!(Presence::from_value(&value), Some(presence));
        let public = Presence::public(0x0081).value();
        assert_eq!(public, [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x81, 0]);
    }

    #[test]
    fn malformed_values_are_refused() {
        assert_eq!(Presence::from_value(&[1; 14]), None);
        let mut value = Presence::new(None, &[[2; 8]], 1, 0).value();
        value[0] = 2;
        assert_eq!(Presence::from_value(&value), None);
        value[0] = 1;
        value[14] = 2;
        assert_eq!(Presence::from_value(&value), None, "claims more tags than it holds");
        value[14] = 5;
        value.extend_from_slice(&[0; 32]);
        assert_eq!(Presence::from_value(&value), None, "more than four");
    }

    #[test]
    fn endpoints_name_a_peripheral_and_an_entry() {
        assert_eq!(endpoint("AB-12", false), "bluetooth:AB-12");
        assert_eq!(parse_endpoint("bluetooth:AB-12/public"), Some(("AB-12", true)));
        assert_eq!(parse_endpoint("bluetooth:AB-12"), Some(("AB-12", false)));
        assert_eq!(parse_endpoint("n:abc"), None);
    }

    #[test]
    fn reads_go_stale_with_the_window_the_clock_and_the_public_flag() {
        let at = 1_800_000_000.0;
        assert!(read_is_fresh(at, false, at + 10.0, false));
        assert!(!read_is_fresh(at, false, at + 10.0, true));
        assert!(!read_is_fresh(at, false, at + 900.0, false));
        let start = 900.0 * 2_000_000.0;
        assert!(!read_is_fresh(start, false, start + 300.0, false));
    }
}

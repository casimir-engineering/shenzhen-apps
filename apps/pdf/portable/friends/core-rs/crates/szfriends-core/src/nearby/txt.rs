//! What a DNS-SD entry carries (`SZFriendsNetworkTXT.m`): the TXT fields, the random instance names, and the key an
//! address counts under for admission. The fields are ASCII text, so every DNS-SD API (Network.framework, Windows'
//! DnsService, mdns-sd, Android's NsdManager) carries them unchanged.
//!
//! - hidden entry: `v=1`, `t=<16 hex>` (the presence tag), `c=<16 hex>×4` (exactly four callback slots, padding
//!   included, ADR 0004 Review amendments, 2);
//! - public entry (the person's 5 minutes): `v=1`, `p=1`, nothing else.

use std::net::IpAddr;

use super::Tag;

/// The fields of one entry, in the order they are advertised.
pub fn fields(tag: Option<&Tag>, callback_slots: &[Tag], public_entry: bool) -> Vec<(String, String)> {
    let mut fields = vec![("v".to_owned(), "1".to_owned())];
    if public_entry {
        fields.push(("p".to_owned(), "1".to_owned()));
        return fields;
    }
    if let Some(tag) = tag {
        fields.push(("t".to_owned(), hex::encode(tag)));
    }
    let callbacks: String = callback_slots.iter().take(super::callbacks::CALLBACK_TAGS_MAX).map(hex::encode).collect();
    if !callbacks.is_empty() {
        fields.push(("c".to_owned(), callbacks));
    }
    fields
}

/// What an entry's TXT says, or `None` for anything but version 1 (a later format is ignored, never misread).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Parsed {
    pub tag: Option<Tag>,
    pub callback_tags: Vec<Tag>,
    pub public: bool,
}

/// Reads the fields as an adapter got them (`key`, `value` bytes).
pub fn parse<'a>(fields: impl IntoIterator<Item = (&'a str, &'a [u8])>) -> Option<Parsed> {
    let mut version = None;
    let (mut public, mut presence, mut callbacks) = (false, None, None);
    for (key, value) in fields {
        let text = std::str::from_utf8(value).ok();
        match key {
            "v" => version = text,
            "p" => public = text == Some("1"),
            "t" => presence = text,
            "c" => callbacks = text,
            _ => {}
        }
    }
    if version != Some("1") {
        return None;
    }
    if public {
        // A public entry carries no tag; anything else in it is ignored.
        return Some(Parsed { public: true, ..Parsed::default() });
    }
    let tag = presence.and_then(|text| hex::decode(text).ok()).and_then(|bytes| bytes.try_into().ok());
    let mut callback_tags = Vec::new();
    let callbacks = callbacks.unwrap_or_default();
    if callbacks.len() % 16 == 0 {
        for chunk in callbacks.as_bytes().chunks(16).take(super::callbacks::CALLBACK_TAGS_MAX) {
            match std::str::from_utf8(chunk).ok().and_then(|h| hex::decode(h).ok()) {
                Some(bytes) => callback_tags.push(bytes.try_into().expect("16 hex digits are 8 bytes")),
                None => {
                    callback_tags.clear();
                    break;
                }
            }
        }
    }
    Some(Parsed { tag, callback_tags, public: false })
}

/// A random instance name, 16 hex digits, never the computer's name.
pub fn random_instance_name() -> String {
    let mut bytes = [0u8; 8];
    szfriends_crypto::random_bytes(&mut bytes);
    hex::encode(bytes)
}

/// Where a connection comes from, as the per-address admission limits count it (`SZFriendsAdmissionKeyForAddress`):
/// an IPv4 address, or an IPv6 /64 (with its interface when link-local), so one host with many addresses counts once.
/// An IPv4-mapped address counts as the IPv4 address it is.
pub fn admission_key(address: IpAddr, scope_id: u32) -> String {
    let v6 = match address {
        IpAddr::V4(v4) => return format!("4:{v4}"),
        IpAddr::V6(v6) => v6,
    };
    if let Some(v4) = v6.to_ipv4_mapped() {
        return format!("4:{v4}");
    }
    let mut bytes = v6.octets();
    let mut scope = String::new();
    if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 {
        // The kernel may carry the interface in bytes 2 and 3 of a link-local address rather than in the scope id.
        let embedded = u32::from(bytes[2]) << 8 | u32::from(bytes[3]);
        bytes[2] = 0;
        bytes[3] = 0;
        scope = format!("%{}", if scope_id != 0 { scope_id } else { embedded });
    }
    format!(
        "6:{:02x}{:02x}:{:02x}{:02x}:{:02x}{:02x}:{:02x}{:02x}/64{scope}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7]
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn as_pairs(fields: &[(String, String)]) -> Vec<(&str, &[u8])> {
        fields.iter().map(|(k, v)| (k.as_str(), v.as_bytes())).collect()
    }

    #[test]
    fn hidden_entry_round_trips() {
        let tag = [1, 2, 3, 4, 5, 6, 7, 8];
        let slots = [[9; 8], [10; 8], [11; 8], [12; 8], [13; 8]];
        let written = fields(Some(&tag), &slots, false);
        assert_eq!(written[1], ("t".into(), "0102030405060708".into()));
        assert_eq!(written[2].1.len(), 64, "four slots at most");
        let parsed = parse(as_pairs(&written)).unwrap();
        assert_eq!(parsed.tag, Some(tag));
        assert_eq!(parsed.callback_tags, slots[..4].to_vec());
        assert!(!parsed.public);
    }

    #[test]
    fn public_entry_carries_nothing_else() {
        let written = fields(Some(&[1; 8]), &[[2; 8]], true);
        assert_eq!(written, vec![("v".into(), "1".into()), ("p".into(), "1".into())]);
        let parsed = parse([("v", &b"1"[..]), ("p", b"1"), ("t", b"0102030405060708")]).unwrap();
        assert_eq!(parsed, Parsed { public: true, ..Parsed::default() });
    }

    #[test]
    fn other_versions_and_bad_hex_are_ignored() {
        assert!(parse([("v", &b"2"[..]), ("t", b"0102030405060708")]).is_none());
        assert!(parse([("t", &b"0102030405060708"[..])]).is_none());
        let parsed = parse([("v", &b"1"[..]), ("t", b"01020304"), ("c", b"zz02030405060708")]).unwrap();
        assert_eq!(parsed, Parsed::default());
        let odd = parse([("v", &b"1"[..]), ("c", b"0102030405060708aa")]).unwrap();
        assert!(odd.callback_tags.is_empty());
    }

    #[test]
    fn admission_keys_count_hosts() {
        assert_eq!(admission_key("192.168.1.9".parse().unwrap(), 0), "4:192.168.1.9");
        assert_eq!(admission_key("::ffff:10.0.0.2".parse().unwrap(), 0), "4:10.0.0.2");
        let a = admission_key("2001:db8:1:2:aaaa::1".parse().unwrap(), 0);
        let b = admission_key("2001:db8:1:2:bbbb::7".parse().unwrap(), 0);
        assert_eq!(a, "6:2001:0db8:0001:0002/64");
        assert_eq!(a, b, "one /64 is one host");
        assert_eq!(admission_key("fe80::1".parse().unwrap(), 4), "6:fe80:0000:0000:0000/64%4");
        assert_eq!(admission_key("fe80:0:0:0:1::1".parse().unwrap(), 0), "6:fe80:0000:0000:0000/64%0");
    }

    #[test]
    fn instance_names_are_random_hex() {
        let (a, b) = (random_instance_name(), random_instance_name());
        assert_eq!(a.len(), 16);
        assert!(a.bytes().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(a, b);
    }
}

//! The signed host list (ADR 0005 § Signed host list; `SZFriendsHostList.m`): verified against pinned keys, then
//! parsed from exactly the bytes that were signed, by the rules of `server/friends/src/hostlist.js`.

use serde_json::Value;
use szfriends_identity::identity::verify;

use crate::b64;

const DOMAIN: &str = "SZFriends host list v1\n";
const MAX_SIGNATURES: usize = 4;
const MAX_HOSTS: usize = 32;
const MAX_URLS: usize = 8;
const MAX_URL_LENGTH: usize = 512;
pub const MAX_BYTES: usize = 64 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostEntry {
    pub id: String,
    pub rendezvous: bool,
    pub relay: bool,
    pub urls: Vec<String>,
    pub turn_uris: Vec<String>,
    pub region: String,
    pub priority: i64,
    pub public_key: [u8; 32],
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostList {
    pub version: i64,
    pub new_id_words: i64,
    /// By priority, then id.
    pub entries: Vec<HostEntry>,
    pub signed: Vec<u8>,
    pub payload: Vec<u8>,
}

fn valid_id(text: &str) -> bool {
    (1..=32).contains(&text.len())
        && text.bytes().enumerate().all(|(i, c)| c.is_ascii_lowercase() || c.is_ascii_digit() || (c == b'-' && i > 0))
}

fn integer(value: Option<&Value>, min: i64, max: i64) -> Option<i64> {
    value?.as_i64().filter(|v| (min..=max).contains(v))
}

/// wss://, or ws:// only to 127.0.0.1, [::1] or localhost; no user, password or fragment.
pub fn url_allowed(url: &str) -> bool {
    let Some((scheme, rest)) = url.split_once("://") else { return false };
    let authority = rest.split(['/', '?']).next().unwrap_or("");
    if authority.is_empty() || authority.contains('@') || url.contains('#') {
        return false;
    }
    let host = if let Some(inner) = authority.strip_prefix('[') {
        inner.split(']').next().unwrap_or("")
    } else {
        authority.split(':').next().unwrap_or("")
    };
    match scheme.to_ascii_lowercase().as_str() {
        "wss" => !host.is_empty(),
        "ws" => matches!(host.to_ascii_lowercase().as_str(), "127.0.0.1" | "::1" | "localhost"),
        _ => false,
    }
}

fn time_shape(text: &str) -> bool {
    let bytes = text.as_bytes();
    let digits = |range: std::ops::Range<usize>| bytes.get(range).is_some_and(|b| b.iter().all(u8::is_ascii_digit));
    let base = text.len() >= 20
        && digits(0..4)
        && bytes[4] == b'-'
        && digits(5..7)
        && bytes[7] == b'-'
        && digits(8..10)
        && bytes[10] == b'T'
        && digits(11..13)
        && bytes[13] == b':'
        && digits(14..16)
        && bytes[16] == b':'
        && digits(17..19);
    if !base || !text.ends_with('Z') {
        return false;
    }
    let middle = &text[19..text.len() - 1];
    middle.is_empty()
        || (middle.starts_with('.')
            && (2..=4).contains(&middle.len())
            && middle[1..].bytes().all(|c| c.is_ascii_digit()))
}

fn entry(value: &Value) -> Option<HostEntry> {
    let object = value.as_object()?;
    let id = object.get("id")?.as_str().filter(|id| valid_id(id))?;
    let (rendezvous, relay) = match object.get("role")?.as_str()? {
        "rendezvous" => (true, false),
        "relay" => (false, true),
        "both" => (true, true),
        _ => return None,
    };
    let urls = object.get("urls")?.as_array().filter(|u| (1..=MAX_URLS).contains(&u.len()))?;
    let urls: Vec<String> = urls
        .iter()
        .map(|u| u.as_str().filter(|u| u.len() <= MAX_URL_LENGTH && url_allowed(u)).map(str::to_owned))
        .collect::<Option<_>>()?;
    let empty = Vec::new();
    let turn = match object.get("turn_uris") {
        Some(value) => value.as_array().filter(|t| t.len() <= MAX_URLS)?,
        None => &empty,
    };
    let turn_uris: Vec<String> = turn
        .iter()
        .map(|t| t.as_str().filter(|t| t.len() <= MAX_URL_LENGTH).map(str::to_owned))
        .collect::<Option<_>>()?;
    let region = object.get("region")?.as_str().filter(|r| (1..=64).contains(&r.chars().count()))?;
    let priority = integer(object.get("priority"), 1, 1000)?;
    let public_key = b64::decode_array::<32>(object.get("public_key"))?;
    Some(HostEntry {
        id: id.to_owned(),
        rendezvous,
        relay,
        urls,
        turn_uris,
        region: region.to_owned(),
        priority,
        public_key,
    })
}

impl HostList {
    /// The envelope verified with one of `pinned`, then its payload parsed. `None` for anything else.
    pub fn from_signed(data: &[u8], pinned: &[[u8; 32]]) -> Option<Self> {
        if data.is_empty() || data.len() > MAX_BYTES {
            return None;
        }
        let envelope: Value = serde_json::from_slice(data).ok()?;
        let payload = b64::decode_value(envelope.get("payload"), 0).filter(|p| !p.is_empty())?;
        let sigs = envelope.get("sigs")?.as_array().filter(|s| (1..=MAX_SIGNATURES).contains(&s.len()))?;
        let signed = [DOMAIN.as_bytes(), &payload].concat();
        let mut verified = false;
        for sig in sigs {
            let signature = b64::decode_value(sig.get("sig"), 64)?;
            // The domain carries its own newline; verify() takes the domain and the payload separately.
            verified |= pinned.iter().any(|key| verify(&signature, &payload, DOMAIN, key));
        }
        if !verified || signed.is_empty() {
            return None;
        }
        let object: Value = serde_json::from_slice(&payload).ok()?;
        let version = integer(object.get("version"), 1, 9_007_199_254_740_991)?;
        object.get("issued_at")?.as_str().filter(|t| time_shape(t))?;
        let new_id_words = integer(object.get("new_id_words"), 2, 3)?;
        let hosts = object.get("hosts")?.as_array().filter(|h| (1..=MAX_HOSTS).contains(&h.len()))?;
        let mut entries: Vec<HostEntry> = hosts.iter().map(entry).collect::<Option<_>>()?;
        let mut ids: Vec<&str> = entries.iter().map(|e| e.id.as_str()).collect();
        ids.sort_unstable();
        ids.dedup();
        if ids.len() != entries.len() {
            return None;
        }
        entries.sort_by(|a, b| a.priority.cmp(&b.priority).then_with(|| a.id.cmp(&b.id)));
        let rendezvous: Vec<&HostEntry> = entries.iter().filter(|e| e.rendezvous).collect();
        if rendezvous.is_empty() || (rendezvous.len() > 1 && rendezvous[0].priority == rendezvous[1].priority) {
            return None;
        }
        Some(Self { version, new_id_words, entries, signed: data.to_vec(), payload })
    }

    /// Whether every URL, STUN and TURN URI names loopback: what a test home's list must be.
    /// The web origin download links name (`SZFriendsLinkOriginForList`): the payload's `links`, an `https` origin
    /// with no path, else the first rendezvous host's own (`wss` as `https`, `ws` as `http`).
    pub fn link_origin(&self) -> Option<String> {
        let payload: Value = serde_json::from_slice(&self.payload).ok()?;
        if let Some(named) = payload.get("links") {
            let named = named.as_str()?;
            let rest = named.strip_prefix("https://")?;
            let plain = !rest.is_empty() && !rest.contains(['/', '?', '#', '@', ' ']);
            return plain.then(|| named.to_owned());
        }
        let entry = self.entries.iter().find(|e| e.rendezvous)?;
        let url = entry.urls.first()?;
        let (scheme, rest) = match url.split_once("://")? {
            ("wss", rest) => ("https", rest),
            ("ws", rest) => ("http", rest),
            _ => return None,
        };
        let authority = rest.split(['/', '?', '#']).next().filter(|a| !a.is_empty() && !a.contains('@'))?;
        Some(format!("{scheme}://{authority}"))
    }

    pub fn is_loopback_only(&self) -> bool {
        let loopback = |host: &str| matches!(host.to_ascii_lowercase().as_str(), "127.0.0.1" | "::1" | "localhost");
        self.entries.iter().all(|entry| {
            entry.urls.iter().all(|url| {
                let rest = url.split_once("://").map_or("", |(_, r)| r);
                let authority = rest.split(['/', '?']).next().unwrap_or("");
                let host = match authority.strip_prefix('[') {
                    Some(inner) => inner.split(']').next().unwrap_or(""),
                    None => authority.split(':').next().unwrap_or(""),
                };
                loopback(host)
            }) && entry.turn_uris.iter().all(|uri| ice_uri_host(uri).is_some_and(loopback))
        })
    }

    /// The entry of a host by id.
    pub fn entry(&self, id: &str) -> Option<&HostEntry> {
        self.entries.iter().find(|e| e.id == id)
    }
}

/// "stun:127.0.0.1:3478", "turn:[::1]:3478?transport=udp" -> "127.0.0.1", "::1".
pub fn ice_uri_host(uri: &str) -> Option<&str> {
    let (scheme, rest) = uri.split_once(':')?;
    if !["stun", "turn", "turns"].contains(&scheme.to_ascii_lowercase().as_str()) {
        return None;
    }
    let rest = rest.split('?').next().unwrap_or("");
    if let Some(inner) = rest.strip_prefix('[') {
        return inner.split(']').next();
    }
    let parts: Vec<&str> = rest.split(':').collect();
    (parts.len() <= 2).then_some(parts[0])
}

/// The pinned-keys file: `{"keys": [{"public_key": ..., "test": false}]}`. Whether any is a test key comes with them
/// (only an explicit false counts as production).
pub fn pinned_keys(data: &[u8]) -> Option<(Vec<[u8; 32]>, bool)> {
    let object: Value = serde_json::from_slice(data).ok()?;
    let keys = object.get("keys")?.as_array().filter(|k| !k.is_empty())?;
    let mut out = Vec::new();
    let mut any_test = false;
    for key in keys {
        out.push(b64::decode_array::<32>(key.get("public_key"))?);
        any_test |= key.get("test") != Some(&Value::Bool(false));
    }
    Some((out, any_test))
}

/// The list and keys the helper bundles: copies of `service/host/resources/`, which a test keeps identical.
pub fn bundled() -> (&'static [u8], &'static [u8]) {
    (include_bytes!("../../resources/bootstrap-hosts.json"), include_bytes!("../../resources/pinned-keys.json"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_bundled_list_verifies_with_the_bundled_keys() {
        let (list, keys) = bundled();
        let (keys, test) = pinned_keys(keys).unwrap();
        assert!(!test);
        let list = HostList::from_signed(list, &keys).unwrap();
        assert_eq!(list.entries[0].id, "main-hk");
        assert!(!list.is_loopback_only());
        assert_eq!(list.link_origin().as_deref(), Some("https://friends.meerkat.orgabots.com"), "the main host's own");
        assert!(HostList::from_signed(super::bundled().0, &[[7; 32]]).is_none());
        // The copies are the helper's own files, byte for byte, where the source tree has them.
        let helper = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../service/host/resources");
        for (name, ours) in [("bootstrap-hosts.json", bundled().0), ("pinned-keys.json", bundled().1)] {
            if let Ok(theirs) = std::fs::read(helper.join(name)) {
                assert_eq!(theirs, ours, "{name} differs from the helper's");
            }
        }
    }

    #[test]
    fn urls() {
        assert!(url_allowed("wss://friends.example/v1"));
        assert!(url_allowed("ws://127.0.0.1:9/v1"));
        assert!(!url_allowed("ws://friends.example/v1"));
        assert!(!url_allowed("wss://user@friends.example/v1"));
        assert_eq!(ice_uri_host("turn:[::1]:3478?transport=udp"), Some("::1"));
    }
}

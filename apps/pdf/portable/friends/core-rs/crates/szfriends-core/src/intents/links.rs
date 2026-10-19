//! Link intents (`SZFriendsIntentRouter+Links.m`) and the payload an app passes on (`SZFriendsLinkPayload.m`,
//! PROTOCOL.md § Links): "f." and a friend link's bytes, or "d." and a download link's, in strict base64url.

use serde_json::Value;

use super::content::{files, integer};
use super::{required, string, Intent, IntentError, Result};

/// The longest payload string an app passes on.
pub const LINK_PAYLOAD_MAX: usize = 512;
const LINK_NAME_MAX: usize = 160;
const VERSION: u8 = 1;

/// A link an app received, parsed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LinkPayload {
    /// A friend link: whose it is, the invite token their computer accepts, their ID and the name they gave.
    Friend { identity_key: [u8; 32], invite_token: [u8; 16], friends_id: String, name: String },
    /// A download link: which link, and the secret that opens it.
    Download { link_id: [u8; 16], secret: [u8; 32] },
}

/// Strict base64url (RFC 4648 § 5): no padding, the URL alphabet only, unused trailing bits zero.
pub fn base64url_decode(text: &str) -> Option<Vec<u8>> {
    if text.len() % 4 == 1 {
        return None;
    }
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let (mut buffer, mut bits) = (0u32, 0);
    for c in text.bytes() {
        let value = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'-' => 62,
            b'_' => 63,
            _ => return None,
        };
        buffer = (buffer << 6) | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
        }
    }
    // Canonical: the bits left over must be zero, so one string names one byte sequence.
    if bits > 0 && buffer & ((1 << bits) - 1) != 0 {
        return None;
    }
    Some(out)
}

/// Unpadded base64url (RFC 4648 § 5).
pub fn base64url_encode(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let value = chunk.iter().enumerate().fold(0u32, |v, (i, b)| v | u32::from(*b) << (16 - 8 * i));
        for i in 0..=chunk.len() {
            out.push(char::from(ALPHABET[((value >> (18 - 6 * i)) & 63) as usize]));
        }
    }
    out
}

/// A friend link's app payload ("f." and the base64url of its bytes) for this identity, invite and ID; a name that
/// does not fit the link is left out rather than cut, so the page names the Friends ID instead. None for an ID of the
/// wrong shape.
pub fn friend_link_payload(
    identity_key: &[u8; 32],
    invite_token: &[u8; 16],
    friends_id: &str,
    name: &str,
) -> Option<String> {
    let name = if name.len() <= LINK_NAME_MAX && !name.chars().any(crate::presentation::text::is_control_or_format) {
        name
    } else {
        ""
    };
    if !id_shape_valid(friends_id.as_bytes()) {
        return None;
    }
    let mut bytes = vec![VERSION];
    bytes.extend_from_slice(identity_key);
    bytes.extend_from_slice(invite_token);
    bytes.push(friends_id.len() as u8);
    bytes.extend_from_slice(friends_id.as_bytes());
    bytes.push(name.len() as u8);
    bytes.extend_from_slice(name.as_bytes());
    Some(format!("f.{}", base64url_encode(&bytes)))
}

/// Lowercase ASCII words joined by single hyphens: what a Friends ID looks like.
fn id_shape_valid(bytes: &[u8]) -> bool {
    (3..=64).contains(&bytes.len())
        && bytes[0] != b'-'
        && bytes[bytes.len() - 1] != b'-'
        && bytes.iter().enumerate().all(|(i, b)| b.is_ascii_lowercase() || (*b == b'-' && bytes[i - 1] != b'-'))
}

fn friend(data: &[u8]) -> Option<LinkPayload> {
    let mut at = 1 + 32 + 16;
    if data.len() < at + 1 || data[0] != VERSION {
        return None;
    }
    let id_length = usize::from(data[at]);
    at += 1;
    if data.len() < at + id_length + 1 {
        return None;
    }
    let id = &data[at..at + id_length];
    at += id_length;
    let name_length = usize::from(data[at]);
    at += 1;
    if data.len() != at + name_length || !id_shape_valid(id) {
        return None;
    }
    let name = std::str::from_utf8(&data[at..]).ok()?;
    let control = name.chars().any(crate::presentation::text::is_control_or_format);
    if name.len() > LINK_NAME_MAX || control {
        return None;
    }
    Some(LinkPayload::Friend {
        identity_key: data[1..33].try_into().ok()?,
        invite_token: data[33..49].try_into().ok()?,
        friends_id: String::from_utf8(id.to_vec()).ok()?,
        name: name.to_owned(),
    })
}

/// A friend or a download payload as an app received it; None for anything else, including a payload longer than
/// [`LINK_PAYLOAD_MAX`], base64url that is not canonical, a version other than 1, or bytes left over.
pub fn parse_link_payload(text: &str) -> Option<LinkPayload> {
    if text.len() < 3 || text.encode_utf16().count() > LINK_PAYLOAD_MAX || text.as_bytes()[1] != b'.' {
        return None;
    }
    let data = base64url_decode(&text[2..])?;
    match text.as_bytes()[0] {
        b'f' => friend(&data),
        b'd' if data.len() == 1 + 16 + 32 && data[0] == VERSION => {
            Some(LinkPayload::Download { link_id: data[1..17].try_into().ok()?, secret: data[17..49].try_into().ok()? })
        }
        _ => None,
    }
}

/// open_link, add_from_link, receive_link, make_download_link and revoke_link.
pub(super) fn parse_link_intent(kind: &str, frame: &Value) -> Result<Intent> {
    if kind == "make_download_link" {
        let file = frame.get("file").filter(|f| f.is_object());
        // A null display name is no name here, unlike in a send's files.
        let name_ok = file.and_then(|f| f.get("display_name")).is_none_or(|n| n.is_null() || n.is_string());
        let mut parsed = file.and_then(|f| files(Some(&Value::Array(vec![without_null_name(f)])), "file", 1).ok());
        if !name_ok {
            parsed = None;
        }
        let file = parsed.and_then(|mut f| f.pop()).ok_or_else(|| IntentError::field("invalid_field", "file"))?;
        let days = frame.get("expires_days").and_then(integer).filter(|d| [1, 7, 30].contains(d));
        let days = days.ok_or_else(|| IntentError::field("invalid_field", "expires_days"))?;
        return Ok(Intent::MakeDownloadLink { file, expires_days: days as u32 });
    }
    if kind == "revoke_link" {
        let id = string(frame, "link_id").and_then(base64url_decode).and_then(|b| <[u8; 16]>::try_from(b).ok());
        return Ok(Intent::RevokeLink { link_id: id.ok_or_else(|| IntentError::field("invalid_field", "link_id"))? });
    }
    let payload = required(frame, "payload", LINK_PAYLOAD_MAX)?;
    let link = parse_link_payload(&payload);
    let link = match (kind, link) {
        ("open_link", Some(link)) => return Ok(Intent::OpenLink { payload, link }),
        ("add_from_link", Some(link @ LinkPayload::Friend { .. })) => link,
        ("receive_link", Some(link @ LinkPayload::Download { .. })) => {
            return Ok(Intent::ReceiveLink { payload, link });
        }
        _ => return Err(IntentError::field("invalid_field", "payload")),
    };
    Ok(Intent::AddFromLink { payload, link })
}

fn without_null_name(file: &Value) -> Value {
    let mut file = file.clone();
    if let Some(map) = file.as_object_mut() {
        if map.get("display_name").is_some_and(Value::is_null) {
            map.remove("display_name");
        }
    }
    file
}

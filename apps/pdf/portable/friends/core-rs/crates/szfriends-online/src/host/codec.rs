//! The host protocol's signed messages (`SZFriendsHostCodec.m`, `SZFriendsHostReply.m`): length-prefixed fields (each a
//! 4-byte big-endian length and its bytes), the check-in, the host's reply signature, and a rendezvous record's.

use serde_json::Value;
use sha2::{Digest, Sha256};
use szfriends_identity::identity::verify;

use crate::b64;

pub const CHECKIN_DOMAIN: &str = "SZFriends checkin v1";
pub const REPLY_DOMAIN: &str = "SZFriends host reply v1";
pub const RECORD_DOMAIN: &str = "SZFriends rendezvous record v1";
/// The protocol this client speaks, and the first that knows devices (it signs the root key and the chain's hash).
pub const PROTOCOL: i64 = 3;
pub const DEVICES_PROTOCOL: i64 = 3;

/// A field as signed: a string's UTF-8, or bytes.
#[derive(Clone, Copy, Debug)]
pub enum Field<'a> {
    Text(&'a str),
    Bytes(&'a [u8]),
}

pub fn length_prefixed(fields: &[Field<'_>]) -> Vec<u8> {
    let mut out = Vec::new();
    for field in fields {
        let bytes = match field {
            Field::Text(text) => text.as_bytes(),
            Field::Bytes(bytes) => bytes,
        };
        out.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
        out.extend_from_slice(bytes);
    }
    out
}

/// The host's protocol as its challenge says it: 3 or more is 3; none (a host from before protocol 3) is 2.
pub fn protocol_for_challenge(challenge: &Value) -> i64 {
    match challenge.get("protocol").and_then(Value::as_i64) {
        Some(p) if p >= DEVICES_PROTOCOL => PROTOCOL,
        _ => 2,
    }
}

/// What a check-in's signature covers (HOST-PROTOCOL.md § Signatures).
#[allow(clippy::too_many_arguments)]
pub fn checkin_message(
    host_id: &str,
    challenge: &[u8],
    identity_key: &[u8; 32],
    friends_id: &str,
    reserved: bool,
    app_version: &str,
    protocol: i64,
    list_version: i64,
    root_key: Option<&[u8; 32]>,
    chain: Option<&[u8]>,
) -> Vec<u8> {
    let (protocol_text, list_text) = (protocol.to_string(), list_version.to_string());
    let mut fields = vec![
        Field::Text(host_id),
        Field::Bytes(challenge),
        Field::Bytes(identity_key),
        Field::Text(friends_id),
        Field::Text(if reserved { "1" } else { "0" }),
        Field::Text(app_version),
        Field::Text(&protocol_text),
        Field::Text(&list_text),
    ];
    let digest: Option<[u8; 32]> = chain.map(|c| Sha256::digest(c).into());
    if protocol >= DEVICES_PROTOCOL {
        fields.push(Field::Bytes(root_key.map_or(&[][..], |k| &k[..])));
        fields.push(Field::Bytes(digest.as_ref().map_or(&[][..], |d| &d[..])));
    }
    length_prefixed(&fields)
}

fn reply_string(value: Option<&Value>) -> &str {
    value.and_then(Value::as_str).unwrap_or("")
}

fn reply_flag(value: Option<&Value>) -> &'static str {
    if value == Some(&Value::Bool(true)) {
        "1"
    } else {
        "0"
    }
}

/// The body a `welcome` signs, for the ID the check-in asked for.
pub fn welcome_body(requested: &str, message: &Value) -> Vec<String> {
    let payload = message.get("host_list").and_then(|l| l.get("payload")).and_then(Value::as_str).unwrap_or("");
    vec![
        "welcome".into(),
        requested.into(),
        reply_string(message.get("reservation")).into(),
        reply_string(message.get("friends_id")).into(),
        reply_flag(message.get("update_required")).into(),
        payload.into(),
    ]
}

pub fn reserve_result_body(requested: &str, message: &Value) -> Vec<String> {
    vec![
        "reserve_result".into(),
        requested.into(),
        reply_string(message.get("reservation")).into(),
        reply_string(message.get("friends_id")).into(),
    ]
}

/// Whether `host_sig` is the host key's signature over this connection's challenge and the reply's body.
pub fn reply_verifies(message: &Value, body: &[String], challenge: &[u8], host_key: &[u8; 32]) -> bool {
    let Some(signature) = b64::decode_value(message.get("host_sig"), 64) else { return false };
    if challenge.len() != 32 {
        return false;
    }
    let fields: Vec<Field<'_>> = body.iter().map(|f| Field::Text(f)).collect();
    let digest: [u8; 32] = Sha256::digest(length_prefixed(&fields)).into();
    let signed = length_prefixed(&[Field::Bytes(challenge), Field::Bytes(&digest)]);
    verify(&signature, &signed, REPLY_DOMAIN, host_key)
}

/// What a rendezvous record's signature covers after its domain.
pub fn record_message(host_id: &str, rdv_key: &[u8; 32], seq: u64, expires: i64, sealed: &[u8]) -> Vec<u8> {
    let digest: [u8; 32] = Sha256::digest(sealed).into();
    let (seq, expires) = (seq.to_string(), expires.to_string());
    length_prefixed(&[
        Field::Text(host_id),
        Field::Bytes(rdv_key),
        Field::Text(&seq),
        Field::Text(&expires),
        Field::Bytes(&digest),
    ])
}

/// One message to the host: the fields, its type and `v: 1`.
pub fn encode(kind: &str, mut fields: serde_json::Map<String, Value>) -> String {
    fields.insert("type".into(), Value::String(kind.into()));
    fields.insert("v".into(), Value::from(1));
    Value::Object(fields).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn length_prefixed_fields() {
        let bytes = length_prefixed(&[Field::Text("ab"), Field::Bytes(&[1])]);
        assert_eq!(bytes, [0, 0, 0, 2, b'a', b'b', 0, 0, 0, 1, 1]);
        let three = checkin_message("h", &[0; 32], &[1; 32], "a-b", false, "1", 3, 2, Some(&[1; 32]), None);
        let two = checkin_message("h", &[0; 32], &[1; 32], "a-b", false, "1", 2, 2, Some(&[1; 32]), None);
        assert_eq!(three.len(), two.len() + 4 + 32 + 4);
    }
}

//! PROTOCOL.md § Handshake and § Replies and errors: reading a client's `hello`, and the frames whose shape never
//! changes (`welcome`, `reply`, `goodbye`). Mirrors `SZFriendsIPCServer.m` and `SZFriendsClientContext.m`; the
//! fixtures in `fixtures/frames` are what these produce.

use std::collections::BTreeSet;

use serde_json::{json, Map, Value};

use crate::framing::FRAME_MAX;
use crate::lifecycle::ProtocolVersion;

/// Strings an app supplies end up inside snapshot text, so they are bounded (`SZFRIENDS_MAX_HELLO_STRING`).
pub const HELLO_STRING_MAX: usize = 128;
/// At most this many capabilities.
pub const CAPABILITIES_MAX: usize = 64;
/// At most this many open formats (`SZFRIENDS_MAX_OPEN_FORMATS`).
pub const OPEN_FORMATS_MAX: usize = 512;

/// The helper inside the asking app (`hello.embedded_helper`), which drives handover.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EmbeddedHelper {
    pub version: String,
    pub build_number: u64,
    pub protocol: ProtocolVersion,
}

/// What a `hello` says about versions, read before negotiation so a newer app can always ask an older helper to
/// step aside, even when the two share no major.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HelloVersions {
    pub protocol: ProtocolVersion,
    pub min_major: i64,
    pub embedded_helper: Option<EmbeddedHelper>,
}

/// Who the helper is writing for, from a `hello` that negotiated.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClientInfo {
    pub app_id: String,
    pub app_name: String,
    pub app_version: String,
    pub toolkit: String,
    pub reveal_in: String,
    pub locale: String,
    pub capabilities: BTreeSet<String>,
    /// Lowercased.
    pub open_formats: BTreeSet<String>,
    pub negotiated: ProtocolVersion,
    /// `client.url_scheme`: where a notification's click opens this app (`<scheme>://friends/...`); `None` when
    /// absent or not a URL scheme.
    pub url_scheme: Option<String>,
}

/// A URL scheme as RFC 3986 spells one, lowercased, at most 32 characters.
fn url_scheme(value: Option<&Value>) -> Option<String> {
    let scheme = value?.as_str()?.to_ascii_lowercase();
    let mut chars = scheme.chars();
    let first = chars.next()?;
    let valid = first.is_ascii_lowercase()
        && scheme.len() <= 32
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '+' | '-' | '.'));
    valid.then_some(scheme)
}

/// A JSON integer, as `NSJSONSerialization` reads one: not a boolean, not a fraction.
fn integer(value: Option<&Value>) -> Option<i64> {
    value?.as_i64()
}

fn version(value: Option<&Value>, with_min_major: bool) -> Option<(ProtocolVersion, i64)> {
    let object = value?.as_object()?;
    let parsed = ProtocolVersion { major: integer(object.get("major"))?, minor: integer(object.get("minor"))? };
    let min = if with_min_major { integer(object.get("min_major"))? } else { parsed.major };
    Some((parsed, min))
}

/// The versions in a `hello`. `Err(field)` names the field an `invalid_field` reply carries.
pub fn hello_versions(hello: &Value) -> Result<HelloVersions, &'static str> {
    let (protocol, min_major) = version(hello.get("protocol"), true).ok_or("protocol")?;
    let embedded_helper = match hello.get("embedded_helper") {
        None | Some(Value::Null) => None,
        Some(embedded) => {
            let build = embedded.get("build_number").and_then(Value::as_u64);
            let name = embedded.get("version").and_then(Value::as_str);
            let protocol = version(embedded.get("protocol"), false);
            match (build, name, protocol) {
                (Some(build_number), Some(name), Some((protocol, _))) => {
                    Some(EmbeddedHelper { version: name.to_owned(), build_number, protocol })
                }
                _ => return Err("embedded_helper"),
            }
        }
    };
    Ok(HelloVersions { protocol, min_major, embedded_helper })
}

fn hello_string(object: &Map<String, Value>, key: &str, required: bool) -> Option<String> {
    match object.get(key) {
        None | Some(Value::Null) => (!required).then(String::new),
        Some(Value::String(text)) => {
            let fits = text.encode_utf16().count() <= HELLO_STRING_MAX && !(required && text.is_empty());
            fits.then(|| text.clone())
        }
        Some(_) => None,
    }
}

fn hello_set(value: Option<&Value>, max: usize, lowercase: bool) -> Option<BTreeSet<String>> {
    let items = value?.as_array()?;
    if items.len() > max {
        return None;
    }
    items
        .iter()
        .map(|item| {
            let text = item.as_str().filter(|t| !t.is_empty() && t.encode_utf16().count() <= HELLO_STRING_MAX)?;
            Some(if lowercase { text.to_lowercase() } else { text.to_owned() })
        })
        .collect()
}

/// The client's context. Any toolkit name is accepted, so a later host never fails `hello` on an older helper; a
/// missing locale means English.
pub fn client_info(hello: &Value, negotiated: ProtocolVersion) -> Result<ClientInfo, String> {
    let client = hello.get("client").and_then(Value::as_object).ok_or_else(|| "client".to_owned())?;
    let mut values = Vec::new();
    for key in ["app_id", "app_name", "app_version", "toolkit", "reveal_in"] {
        values.push(hello_string(client, key, true).ok_or_else(|| format!("client.{key}"))?);
    }
    let hello_object = hello.as_object().ok_or_else(|| "client".to_owned())?;
    let locale = hello_string(hello_object, "locale", false).ok_or_else(|| "locale".to_owned())?;
    let capabilities =
        hello_set(hello.get("capabilities"), CAPABILITIES_MAX, false).ok_or_else(|| "capabilities".to_owned())?;
    let open_formats =
        hello_set(hello.get("open_formats"), OPEN_FORMATS_MAX, true).ok_or_else(|| "open_formats".to_owned())?;
    let [app_id, app_name, app_version, toolkit, reveal_in] = <[String; 5]>::try_from(values).expect("five keys");
    Ok(ClientInfo {
        app_id,
        app_name,
        app_version,
        toolkit,
        reveal_in,
        locale: if locale.is_empty() { "en".to_owned() } else { locale },
        capabilities,
        open_formats,
        negotiated,
        url_scheme: url_scheme(client.get("url_scheme")),
    })
}

/// Codes a client may retry unchanged (PROTOCOL.md § Replies and errors).
pub fn code_is_retryable(code: &str) -> bool {
    matches!(
        code,
        "rate_limited" | "disk_full" | "link_offline" | "link_failed" | "internal" | "not_ready" | "connection_lost"
    )
}

/// An `error` object: `message` is display-ready text for the person, or `None` when the view has nothing useful
/// to say.
pub fn error_object(code: &str, message: Option<&str>, details: Value) -> Value {
    let details = if details.is_null() { json!({}) } else { details };
    json!({"code": code, "message": message, "retryable": code_is_retryable(code), "details": details})
}

pub fn error_reply(re: &str, code: &str, message: Option<&str>, details: Value) -> Value {
    json!({"type": "reply", "re": re, "ok": false, "error": error_object(code, message, details)})
}

pub fn ok_reply(re: &str, result: Value) -> Value {
    let result = if result.is_null() { json!({}) } else { result };
    json!({"type": "reply", "re": re, "ok": true, "result": result})
}

/// The helper a `goodbye` with reason `handover` names.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Successor {
    pub version: String,
    pub build_number: u64,
}

/// Why the helper closes a connection on purpose.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GoodbyeReason {
    Handover,
    Shutdown,
    ProtocolError,
    Reset,
    TooManyClients,
}

impl GoodbyeReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Handover => "handover",
            Self::Shutdown => "shutdown",
            Self::ProtocolError => "protocol_error",
            Self::Reset => "reset",
            Self::TooManyClients => "too_many_clients",
        }
    }
}

pub fn goodbye(reason: GoodbyeReason, successor: Option<&Successor>, error: Option<Value>) -> Value {
    let successor = successor.map(|s| json!({"version": s.version, "build_number": s.build_number}));
    json!({"type": "goodbye", "reason": reason.as_str(), "message": null, "successor": successor, "error": error})
}

/// A `goodbye` for a protocol error (`bad_frame`, `frame_too_large`, `hello_required`, `protocol_unsupported`).
pub fn protocol_error_goodbye(code: &str, details: Value) -> Value {
    goodbye(GoodbyeReason::ProtocolError, None, Some(error_object(code, None, details)))
}

/// What the running helper says about itself in `welcome.helper`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HelperFacts {
    pub version: String,
    pub build_number: u64,
    pub protocol: ProtocolVersion,
    pub pid: u32,
}

/// The limits a `welcome` announces when the presentation names none (PROTOCOL.md § Limits).
pub fn default_limits() -> Value {
    json!({"max_frame_bytes": FRAME_MAX, "max_message_bytes": 32768, "max_files_per_send": 100,
           "max_subscriptions": 32})
}

/// A `welcome`: `extras` (capabilities, limits, strings) come from the presentation; the frozen fields are the
/// server's to fill, whatever `extras` holds.
pub fn welcome(re: &str, negotiated: ProtocolVersion, helper: &HelperFacts, handover: bool, extras: Value) -> Value {
    let mut frame = match extras {
        Value::Object(map) => map,
        _ => Map::new(),
    };
    frame.entry("capabilities").or_insert_with(|| json!([]));
    frame.entry("strings").or_insert_with(|| json!({}));
    frame.entry("limits").or_insert_with(default_limits);
    frame.insert("type".into(), json!("welcome"));
    frame.insert("re".into(), json!(re));
    frame.insert("protocol".into(), json!({"major": negotiated.major, "minor": negotiated.minor}));
    frame.insert(
        "helper".into(),
        json!({"version": helper.version, "build_number": helper.build_number,
               "protocol": {"major": helper.protocol.major, "minor": helper.protocol.minor}, "pid": helper.pid}),
    );
    frame.insert("handover".into(), json!(if handover { "scheduled" } else { "none" }));
    Value::Object(frame)
}

/// The `protocol_unsupported` pair: the reply to the `hello`, then the goodbye.
pub fn protocol_unsupported(re: &str, helper_major: i64, helper_min_major: i64, handover: bool) -> [Value; 2] {
    let details = json!({"helper_major": helper_major, "helper_min_major": helper_min_major,
                         "handover": if handover { "scheduled" } else { "none" }});
    [
        error_reply(re, "protocol_unsupported", None, details.clone()),
        protocol_error_goodbye("protocol_unsupported", details),
    ]
}

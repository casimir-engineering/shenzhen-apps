//! What the page may ask of Friends, checked before anything reaches the service: the rules of Shenzhen 3D's
//! Electron bridge (`electron/friends/validate.cjs`), so both shells refuse the same things.
//!
//! The page is the app's own, but it renders other people's names, messages and file names, so the bridge treats
//! what it sends as untrusted: only the intents the panel uses, only the fields each one takes, with the types
//! PROTOCOL.md § Schemas gives them, opaque ids in their documented alphabet, and file paths that are absolute and
//! plain. The service then applies its own rules (sizes, existence, folders, friendship) and answers with
//! display-ready errors; the bridge never duplicates those, it only keeps malformed input from going out.

use std::path::{Component, Path};

use serde_json::{Map, Value};

const MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;
const MAX_PATH_BYTES: usize = 1024;
const MAX_TEXT_BYTES: usize = 32768;
/// The views the panel subscribes to. message_status is for host surfaces outside Friends.
/// `received` lists the files received here, for the app's own recent files.
const VIEWS: &[&str] = &["badge", "list", "nearby", "details", "profile", "settings", "join", "received"];

/// The field that failed, as PROTOCOL.md's `invalid_field` names it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FieldError(pub String);

type Checked = Result<(), FieldError>;

fn fail(field: impl Into<String>) -> Checked {
    Err(FieldError(field.into()))
}

fn opaque_id(value: &Value) -> bool {
    value.as_str().is_some_and(szfriends_contract::ids::opaque_id_is_valid)
}

fn opaque(fields: &Map<String, Value>, key: &str, optional: bool) -> Checked {
    match fields.get(key) {
        None | Some(Value::Null) if optional => Ok(()),
        Some(value) if opaque_id(value) => Ok(()),
        _ => fail(key),
    }
}

fn text(fields: &Map<String, Value>, key: &str, max: usize) -> Checked {
    match fields.get(key).and_then(Value::as_str) {
        Some(value) if value.len() <= max && !value.contains('\0') => Ok(()),
        _ => fail(key),
    }
}

/// An absolute path without `.` or `..`, doubled or trailing separators: what a native picker or drop gives. Every
/// path the page names passes here before anything reads it (classify, show_file, open_file, intents, drops).
pub fn plain_path(value: &str) -> bool {
    if value.is_empty() || value.contains('\0') || value.len() > MAX_PATH_BYTES || !Path::new(value).is_absolute() {
        return false;
    }
    let separator = std::path::MAIN_SEPARATOR;
    let mut rest = value;
    if cfg!(windows) {
        // A drive letter, then the root; never a verbatim or device path, never forward slashes, and never a network
        // share: only reading a share's path would make Windows sign in to that server as the person (an NTLM
        // exchange a page could aim at a server of its choosing). A share mapped to a drive letter works.
        use std::path::Prefix;
        let Some(Component::Prefix(prefix)) = Path::new(value).components().next() else { return false };
        if value.contains('/') || !matches!(prefix.kind(), Prefix::Disk(_)) {
            return false;
        }
        rest = &value[prefix.as_os_str().len()..];
    }
    let Some(rest) = rest.strip_prefix(separator) else { return false };
    !rest.is_empty() && rest.split(separator).all(|segment| !matches!(segment, "" | "." | ".."))
}

/// A MediaStore item's content URI (`content://media/…/<number>`), where Android 10 keeps a received file that no
/// path reads; only the share sheet takes one, and only one a snapshot offered.
pub fn media_store_uri(value: &str) -> bool {
    let Some(rest) = value.strip_prefix("content://media/") else { return false };
    value.len() <= MAX_PATH_BYTES
        && !rest.is_empty()
        && rest.split('/').all(|segment| {
            !segment.is_empty() && segment.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'))
        })
        && !rest.split('/').any(|segment| segment == "." || segment == "..")
}

fn path_field(value: &Value, field: &str) -> Checked {
    match value.as_str() {
        Some(path) if plain_path(path) => Ok(()),
        _ => fail(field),
    }
}

/// PROTOCOL.md's file object. The Tauri apps send plain files only: their bytes at that moment are what the person
/// meant, so a revision is never attached.
fn file_object(value: &Value, field: &str) -> Checked {
    let Some(object) = value.as_object() else { return fail(field) };
    if let Some(key) = object.keys().find(|k| !["path", "display_name", "revision"].contains(&k.as_str())) {
        return fail(format!("{field}.{key}"));
    }
    path_field(&object.get("path").cloned().unwrap_or(Value::Null), &format!("{field}.path"))?;
    if let Some(name) = object.get("display_name") {
        match name.as_str() {
            Some(name) if !name.is_empty() && name.len() <= 1024 => {}
            _ => return fail(format!("{field}.display_name")),
        }
    }
    match object.get("revision") {
        None | Some(Value::Null) => Ok(()),
        _ => fail(format!("{field}.revision")),
    }
}

fn file_list(fields: &Map<String, Value>, key: &str, max: usize) -> Checked {
    let Some(list) = fields.get(key).and_then(Value::as_array).filter(|l| (1..=max).contains(&l.len())) else {
        return fail(key);
    };
    list.iter().enumerate().try_for_each(|(index, file)| file_object(file, &format!("{key}[{index}]")))
}

fn client_token(fields: &Map<String, Value>) -> Checked {
    match fields.get("client_token").and_then(Value::as_str) {
        Some(token) if (16..=64).contains(&token.len()) && token.bytes().all(|b| (0x21..=0x7e).contains(&b)) => Ok(()),
        _ => fail("client_token"),
    }
}

fn integer_in(value: Option<&Value>, low: i64, high: i64) -> bool {
    value.and_then(Value::as_i64).is_some_and(|n| (low..=high).contains(&n))
}

fn subscribe(fields: &Map<String, Value>) -> Checked {
    let view = fields.get("view").and_then(Value::as_str).unwrap_or_default();
    if !VIEWS.contains(&view) {
        return fail("view");
    }
    match fields.get("params") {
        None | Some(Value::Null) if view == "details" => fail("params"),
        None | Some(Value::Null) => Ok(()),
        Some(Value::Object(params)) if view == "details" => {
            if params.len() != 1 || !params.contains_key("conversation_id") {
                return fail("params");
            }
            opaque(params, "conversation_id", false)
        }
        Some(Value::Object(params)) if params.is_empty() => Ok(()),
        _ => fail("params"),
    }
}

fn send_message(fields: &Map<String, Value>) -> Checked {
    text(fields, "text", MAX_TEXT_BYTES * 4)?;
    client_token(fields)?;
    if fields.contains_key("attachments") {
        file_list(fields, "attachments", 20)?;
    }
    if let Some(mentions) = fields.get("mentions") {
        let Some(list) = mentions.as_array().filter(|l| l.len() <= 20) else { return fail("mentions") };
        for (index, mention) in list.iter().enumerate() {
            let keys_ok = mention.as_object().is_some_and(|m| m.len() == 1 && m.contains_key("conversation_id"));
            if !keys_ok || !opaque_id(&mention["conversation_id"]) {
                return fail(format!("mentions[{index}]"));
            }
        }
    }
    Ok(())
}

fn picture(fields: &Map<String, Value>) -> Checked {
    let Some(picture) = fields.get("picture").and_then(Value::as_object) else { return fail("picture") };
    if picture.get("kind").and_then(Value::as_str) == Some("animal") {
        if picture.keys().any(|k| !["kind", "set", "index"].contains(&k.as_str())) {
            return fail("picture");
        }
        if !integer_in(picture.get("set"), 0, 1000) {
            return fail("picture.set");
        }
        if !integer_in(picture.get("index"), 0, 10000) {
            return fail("picture.index");
        }
        return Ok(());
    }
    if picture.get("kind").and_then(Value::as_str) != Some("image") {
        return fail("picture.kind");
    }
    if picture.keys().any(|k| !["kind", "data_base64", "path", "crop"].contains(&k.as_str())) {
        return fail("picture");
    }
    let (data, path) = (picture.get("data_base64"), picture.get("path"));
    if data.is_some() == path.is_some() {
        return fail("picture");
    }
    if let Some(data) = data {
        let base64 = |s: &str| {
            let body = s.trim_end_matches('=');
            s.len() - body.len() <= 2 && body.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/')
        };
        if !data.as_str().is_some_and(|s| s.len() <= 7 * 1024 * 1024 && base64(s)) {
            return fail("picture.data_base64");
        }
    }
    if let Some(path) = path {
        path_field(path, "picture.path")?;
    }
    match picture.get("crop") {
        None | Some(Value::Null) => Ok(()),
        Some(Value::Object(crop)) => {
            let mut keys: Vec<&str> = crop.keys().map(String::as_str).collect();
            keys.sort_unstable();
            if keys != ["side", "x", "y"] {
                return fail("picture.crop");
            }
            for key in ["x", "y", "side"] {
                if !integer_in(crop.get(key), 0, 1 << 20) {
                    return fail(format!("picture.crop.{key}"));
                }
            }
            Ok(())
        }
        Some(_) => fail("picture.crop"),
    }
}

fn search_messages(fields: &Map<String, Value>) -> Checked {
    text(fields, "query", 800)?;
    opaque(fields, "conversation_id", true)?;
    match fields.get("limit") {
        None => Ok(()),
        limit if integer_in(limit, 1, 50) => Ok(()),
        _ => fail("limit"),
    }
}

/// Each intent's allowed keys, the keys that are opaque ids, and the rest of its checks. Intents not listed never
/// leave the bridge: hello and disable belong to the bridge itself, and the assistant intents to hosts with an AI
/// chat.
struct Rule {
    keys: &'static [&'static str],
    ids: &'static [&'static str],
    check: fn(&Map<String, Value>) -> Checked,
}

fn none(_: &Map<String, Value>) -> Checked {
    Ok(())
}

macro_rules! rule {
    ($keys:expr) => {
        Rule { keys: $keys, ids: &[], check: none }
    };
    ($keys:expr, ids) => {
        Rule { keys: $keys, ids: $keys, check: none }
    };
    ($keys:expr, $ids:expr, $check:expr) => {
        Rule { keys: $keys, ids: $ids, check: $check }
    };
}

fn rule(kind: &str) -> Option<Rule> {
    let conversation: &'static [&'static str] = &["conversation_id"];
    Some(match kind {
        "ping" | "activate" | "reset_friend_link" | "cancel_join" | "start_visibility" | "stop_visibility" => {
            rule!(&[])
        }
        "subscribe" => rule!(&["view", "params"], &[], subscribe),
        "unsubscribe" | "load_earlier" => rule!(&["subscription"], ids),
        "set_filter" => rule!(&["subscription", "query"], &["subscription"], |f| text(f, "query", 800)),
        "open_conversation" => {
            rule!(&["conversation_id", "message_id"], conversation, |f| opaque(f, "message_id", true))
        }
        "send_message" => {
            rule!(&["conversation_id", "text", "client_token", "attachments", "mentions"], conversation, send_message)
        }
        "send_files" => rule!(&["conversation_id", "files", "client_token"], conversation, |f| {
            file_list(f, "files", 100)?;
            client_token(f)
        }),
        "cancel_transfer" | "accept_offer" | "decline_offer" | "fetch_from_device" => rule!(&["transfer_id"], ids),
        "retry_item" => rule!(&["item_id"], ids),
        "cancel_message" => rule!(&["message_id"], ids),
        "accept_request" | "decline_request" | "cancel_request" | "block" | "unblock" | "remove_friend"
        | "mark_verified" | "accept_key_change" => rule!(conversation, ids),
        "send_request" => rule!(&["nearby_id"], ids),
        "add_by_id" | "join_profile" => rule!(&["friends_id"], &[], |f| text(f, "friends_id", 800)),
        "add_from_mention" => rule!(&["friends_id", "identity_key", "name"], &[], |f| {
            text(f, "friends_id", 800)?;
            text(f, "identity_key", 128)?;
            text(f, "name", 1024)
        }),
        "open_link" | "add_from_link" | "receive_link" => rule!(&["payload"], &[], |f| text(f, "payload", 512)),
        "make_download_link" => rule!(&["file", "expires_days"], &[], |f| {
            file_object(f.get("file").unwrap_or(&Value::Null), "file")?;
            match f.get("expires_days").and_then(Value::as_u64) {
                Some(1 | 7 | 30) => Ok(()),
                _ => fail("expires_days"),
            }
        }),
        "revoke_link" => rule!(&["link_id"], ids),
        "enter_join_code" => rule!(&["code"], &[], |f| text(f, "code", 64)),
        "approve_join" | "deny_join" => rule!(&["join_id"], ids),
        "revoke_device" => rule!(&["device_id"], ids),
        "rename_device" | "set_name" => rule!(&["name"], &[], |f| text(f, "name", 1024)),
        "set_picture" => rule!(&["picture"], &[], picture),
        "set_auto_accept" => rule!(&["conversation_id", "enabled"], conversation, |f| match f.get("enabled") {
            Some(Value::Bool(_)) => Ok(()),
            _ => fail("enabled"),
        }),
        "dismiss_banner" => rule!(&["kind"], &[], |f| match f.get("kind").and_then(Value::as_str) {
            Some("id_changed") => Ok(()),
            _ => fail("kind"),
        }),
        "search_messages" => rule!(&["query", "conversation_id", "limit"], &[], search_messages),
        "delete_history" => rule!(conversation, &[], |f| opaque(f, "conversation_id", true)),
        "set_received_folder" => rule!(&["path"], &[], |f| path_field(f.get("path").unwrap_or(&Value::Null), "path")),
        "reset_friends" => rule!(&["confirm"], &[], |f| match f.get("confirm").and_then(Value::as_str) {
            Some("reset") => Ok(()),
            _ => fail("confirm"),
        }),
        _ => return None,
    })
}

/// Every intent a page may send.
#[cfg(test)]
pub const INTENT_TYPES: &[&str] = &[
    "ping",
    "activate",
    "subscribe",
    "unsubscribe",
    "set_filter",
    "open_conversation",
    "load_earlier",
    "send_message",
    "send_files",
    "cancel_transfer",
    "accept_offer",
    "decline_offer",
    "retry_item",
    "cancel_message",
    "accept_request",
    "decline_request",
    "cancel_request",
    "send_request",
    "add_by_id",
    "add_from_mention",
    "open_link",
    "add_from_link",
    "receive_link",
    "make_download_link",
    "reset_friend_link",
    "revoke_link",
    "join_profile",
    "enter_join_code",
    "cancel_join",
    "approve_join",
    "deny_join",
    "revoke_device",
    "rename_device",
    "fetch_from_device",
    "block",
    "unblock",
    "remove_friend",
    "mark_verified",
    "accept_key_change",
    "set_name",
    "set_picture",
    "set_auto_accept",
    "set_received_folder",
    "dismiss_banner",
    "start_visibility",
    "stop_visibility",
    "search_messages",
    "delete_history",
    "reset_friends",
];

/// The intent's fields, checked, ready to send; or the field that failed.
pub fn validate_intent(kind: &Value, fields: &Value) -> Result<Map<String, Value>, FieldError> {
    let Some(rule) = kind.as_str().and_then(rule) else { return Err(FieldError("type".into())) };
    let fields = match fields {
        Value::Null => Map::new(),
        Value::Object(map) => map.clone(),
        _ => return Err(FieldError("fields".into())),
    };
    if let Some(key) = fields.keys().find(|k| !rule.keys.contains(&k.as_str())) {
        return Err(FieldError(key.clone()));
    }
    for key in rule.ids {
        opaque(&fields, key, false)?;
    }
    (rule.check)(&fields)?;
    let bytes = serde_json::to_vec(&fields).map(|b| b.len()).unwrap_or(usize::MAX);
    if bytes > MAX_FRAME_BYTES - 4096 {
        return Err(FieldError("fields".into()));
    }
    Ok(fields)
}

#[cfg(test)]
#[path = "tests/validate.rs"]
mod tests;

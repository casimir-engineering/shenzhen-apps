//! Intents about subscriptions, reading and sending (`SZFriendsIntentRouter.m` § Connection and subscription intents,
//! `SZFriendsIntentRouter+Content.m`): their fields, in the helper's order.

use serde_json::{json, Value};

use super::compose::text_with_mentions;
use super::{
    person, required, string, FileRef, Intent, IntentError, IntentState, Result, Revision, View, ATTACHMENTS_MAX,
    FILES_PER_SEND_MAX, MESSAGE_BYTES_MAX, MESSAGE_STATUS_MAX, QUERY_MAX, SEARCH_LIMIT_DEFAULT, SEARCH_LIMIT_MAX,
};
use crate::store::Relation;

/// The person's own computers' conversation.
const YOU: &str = "you";

fn view_named(name: &str) -> Option<View> {
    Some(match name {
        "badge" => View::Badge,
        "list" => View::List,
        "nearby" => View::Nearby,
        "details" => View::Details,
        "profile" => View::Profile,
        "settings" => View::Settings,
        "message_status" => View::MessageStatus,
        "join" => View::Join,
        "received" => View::Received,
        _ => return None,
    })
}

/// A JSON integer as the helper reads one: a number with no fraction, below 2^53.
pub(crate) fn integer(value: &Value) -> Option<i64> {
    let number = value.as_f64().filter(|_| value.is_number())?;
    (number == number.floor() && number.abs() < 9_007_199_254_740_992.0).then_some(number as i64)
}

/// One of this connection's subscriptions, and its view: not_found otherwise.
fn subscription(frame: &Value, state: &dyn IntentState) -> Result<(String, String)> {
    let id = required(frame, "subscription", 64)?;
    let view = state.subscription_view(&id).ok_or_else(|| IntentError::field("not_found", "subscription"))?;
    Ok((id, view))
}

fn subscribe(frame: &Value, state: &dyn IntentState) -> Result<Intent> {
    let view = string(frame, "view").and_then(view_named).ok_or_else(|| IntentError::field("invalid_field", "view"))?;
    let params = frame.get("params").unwrap_or(&Value::Null);
    if !params.is_null() && !params.is_object() {
        return Err(IntentError::field("invalid_field", "params"));
    }
    let mut conversation_id = None;
    if view == View::Details {
        let id = string(params, "conversation_id").filter(|id| !id.is_empty());
        let id = id.ok_or_else(|| IntentError::field("invalid_field", "params.conversation_id"))?;
        if state.relation(id).is_none() {
            return Err(IntentError::field("not_found", "params.conversation_id"));
        }
        conversation_id = Some(id.to_owned());
    }
    let mut message_ids = None;
    if view == View::MessageStatus {
        // Which of them are this person's outgoing messages is the snapshot's business, so subscribing again after a
        // reconnect never fails over an id whose history was deleted since.
        let ids = params
            .get("message_ids")
            .and_then(Value::as_array)
            .filter(|ids| (1..=MESSAGE_STATUS_MAX).contains(&ids.len()));
        let ids: Option<Vec<String>> = ids.and_then(|ids| {
            ids.iter()
                .map(|id| id.as_str().filter(|id| !id.is_empty() && id.encode_utf16().count() <= 64).map(str::to_owned))
                .collect()
        });
        message_ids = Some(ids.ok_or_else(|| IntentError::field("invalid_field", "params.message_ids"))?);
    }
    Ok(Intent::Subscribe { view, conversation_id, message_ids })
}

fn search(frame: &Value, state: &dyn IntentState) -> Result<Intent> {
    let query = string(frame, "query").filter(|q| q.encode_utf16().count() <= QUERY_MAX);
    let query = query.ok_or_else(|| IntentError::field("invalid_field", "query"))?.to_owned();
    let conversation_id = match frame.get("conversation_id") {
        None | Some(Value::Null) => None,
        Some(_) => Some(person(frame, state)?.0),
    };
    let limit = match frame.get("limit") {
        None => SEARCH_LIMIT_DEFAULT,
        Some(value) => {
            let limit = integer(value).ok_or_else(|| IntentError::field("invalid_field", "limit"))?;
            limit.clamp(1, SEARCH_LIMIT_MAX as i64) as usize
        }
    };
    Ok(Intent::SearchMessages { query, conversation_id, limit })
}

/// subscribe, unsubscribe, set_filter, open_conversation, load_earlier, search_messages, delete_history and
/// reset_friends.
pub(super) fn parse_reading(kind: &str, frame: &Value, state: &dyn IntentState) -> Result<Intent> {
    Ok(match kind {
        "subscribe" => subscribe(frame, state)?,
        "unsubscribe" => Intent::Unsubscribe { subscription: subscription(frame, state)?.0 },
        "set_filter" => {
            let (subscription, view) = subscription(frame, state)?;
            let query = string(frame, "query").filter(|q| q.encode_utf16().count() <= QUERY_MAX);
            let query = query.ok_or_else(|| IntentError::field("invalid_field", "query"))?.to_owned();
            if view != "list" && view != "nearby" {
                return Err(IntentError::field("not_allowed", "subscription"));
            }
            Intent::SetFilter { subscription, query }
        }
        "load_earlier" => {
            let (subscription, view) = subscription(frame, state)?;
            if view != "conversation" {
                return Err(IntentError::field("not_allowed", "subscription"));
            }
            Intent::LoadEarlier { subscription }
        }
        "open_conversation" => {
            let (conversation_id, _) = person(frame, state)?;
            let message_id = match frame.get("message_id") {
                None | Some(Value::Null) => None,
                Some(Value::String(id)) if !id.is_empty() => Some(id.clone()),
                Some(_) => return Err(IntentError::field("invalid_field", "message_id")),
            };
            Intent::OpenConversation { conversation_id, message_id }
        }
        "search_messages" => search(frame, state)?,
        "delete_history" => {
            let conversation_id = match frame.get("conversation_id") {
                None | Some(Value::Null) => None,
                Some(_) => Some(person(frame, state)?.0),
            };
            Intent::DeleteHistory { conversation_id }
        }
        _ => {
            if string(frame, "confirm") != Some("reset") {
                return Err(IntentError::field("invalid_field", "confirm"));
            }
            Intent::ResetFriends
        }
    })
}

/// A revision object, or None for an absent or null one; Err for anything malformed.
pub(crate) fn revision(value: Option<&Value>) -> std::result::Result<Option<Revision>, ()> {
    let object = match value {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::Object(object)) => object,
        Some(_) => return Err(()),
    };
    let text = |key: &str| object.get(key).and_then(Value::as_str).map(str::to_owned);
    let (Some(source), Some(document_id), Some(revision_id)) =
        (text("source"), text("document_id"), text("revision_id"))
    else {
        return Err(());
    };
    let size = object.get("size").and_then(integer).filter(|s| *s >= 0).ok_or(())? as u64;
    let sha256 = match object.get("sha256") {
        Some(Value::String(hex)) => {
            // Exactly 64 hex digits: no prefix, separators or whitespace.
            if hex.len() != 64 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
                return Err(());
            }
            let mut digest = [0u8; 32];
            for (i, byte) in digest.iter_mut().enumerate() {
                *byte = u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).map_err(|_| ())?;
            }
            Some(digest)
        }
        None | Some(Value::Null) => None,
        Some(_) => return Err(()),
    };
    Ok(Some(Revision { source, document_id, revision_id, label: text("label"), sha256, size }))
}

/// An absolute path as the helper reads one (it starts with `/`), and on Windows also a drive or share path
/// (`C:\…`, `\\server\share\…`).
fn is_absolute(path: &str) -> bool {
    path.starts_with('/') || (cfg!(windows) && std::path::Path::new(path).is_absolute())
}

/// The file objects of `files` (an array) for `field`: at most `max`, each with an absolute path, a display name that
/// is a string when present, and a well-formed revision. One bad file sends none.
pub fn files(value: Option<&Value>, field: &str, max: usize) -> Result<Vec<FileRef>> {
    let items = value.and_then(Value::as_array).ok_or_else(|| IntentError::field("invalid_field", field))?;
    if items.len() > max {
        let mut error = IntentError::new("too_many_files");
        error.details.insert("max".into(), json!(max));
        return Err(error);
    }
    items
        .iter()
        .enumerate()
        .map(|(i, file)| {
            let path = file.get("path").and_then(Value::as_str).filter(|p| is_absolute(p));
            let name = file.get("display_name");
            let name_ok = name.is_none_or(Value::is_string);
            match (path, name_ok, revision(file.get("revision"))) {
                (Some(path), true, Ok(revision)) => Ok(FileRef {
                    path: path.to_owned(),
                    display_name: name.and_then(Value::as_str).map(str::to_owned),
                    revision,
                }),
                _ => Err(IntentError::field("invalid_field", format!("{field}[{i}]"))),
            }
        })
        .collect()
}

/// The person a send goes to, and whether it may: friends only.
fn recipient(frame: &Value, state: &dyn IntentState) -> Result<String> {
    let (id, relation) = person(frame, state)?;
    match relation {
        Relation::Friend => Ok(id),
        Relation::Blocked => Err(IntentError::new("blocked")),
        _ => Err(IntentError::new("not_friends")),
    }
}

/// `via_assistant`: false when absent; only a client whose app has an assistant may say its assistant wrote something.
fn via_assistant(frame: &Value, state: &dyn IntentState) -> Result<bool> {
    match frame.get("via_assistant") {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(flag)) => {
            let capabilities = state.client_capabilities();
            if *flag && !capabilities.contains("assistant.chats") && !capabilities.contains("assistant.drafts") {
                return Err(IntentError::field("not_allowed", "via_assistant"));
            }
            Ok(*flag)
        }
        Some(_) => Err(IntentError::field("invalid_field", "via_assistant")),
    }
}

/// The client token makes Send safe to retry after a reconnect: 16 to 64 characters.
fn client_token(frame: &Value) -> Result<String> {
    let token = string(frame, "client_token").filter(|t| (16..=64).contains(&t.encode_utf16().count()));
    Ok(token.ok_or_else(|| IntentError::field("invalid_field", "client_token"))?.to_owned())
}

/// send_message and send_files. A send whose client token already sent something ([`IntentState::sent_before`]) is
/// [`Intent::Resend`] once the fields before the token check out, as the helper answers it with what it sent then;
/// the mentions and the files are checked only for a new send. You (the person's own computers) keeps its own tokens.
pub(super) fn parse_sending(kind: &str, frame: &Value, state: &dyn IntentState) -> Result<Intent> {
    let conversation_id = recipient(frame, state)?;
    let via_assistant = via_assistant(frame, state)?;
    let resend = |client_token: &str| {
        (conversation_id != YOU && state.sent_before(client_token))
            .then(|| Intent::Resend { client_token: client_token.to_owned(), message: kind == "send_message" })
    };
    if kind == "send_files" {
        let client_token = client_token(frame)?;
        if frame.get("files").and_then(Value::as_array).is_none_or(|f| f.is_empty()) {
            return Err(IntentError::field("invalid_field", "files"));
        }
        if let Some(resend) = resend(&client_token) {
            return Ok(resend);
        }
        let files = files(frame.get("files"), "files", FILES_PER_SEND_MAX)?;
        return Ok(Intent::SendFiles { conversation_id, files, client_token, via_assistant });
    }
    let attachments = frame.get("attachments").filter(|a| !a.is_null());
    let has_attachments = attachments.and_then(Value::as_array).is_some_and(|a| !a.is_empty());
    let text = string(frame, "text").filter(|t| t.len() <= MESSAGE_BYTES_MAX && (!t.is_empty() || has_attachments));
    let text = text.ok_or_else(|| IntentError::field("invalid_field", "text"))?;
    let client_token = client_token(frame)?;
    if let Some(resend) = resend(&client_token) {
        return Ok(resend);
    }
    // The friends its @ chips name, written in as mentions.
    let text = text_with_mentions(text, frame.get("mentions"), state)?;
    let attachments = match attachments {
        Some(value) => files(Some(value), "attachments", ATTACHMENTS_MAX)?,
        None => Vec::new(),
    };
    Ok(Intent::SendMessage { conversation_id, text, client_token, attachments, via_assistant })
}

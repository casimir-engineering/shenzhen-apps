//! send_message's mentions (`SZFriendsIntentRouter+Mentions.m`, PROTOCOL.md § Mentions). Views never write IDs or
//! keys: they send the friends a message names by conversation id, with U+FFFC where each chip sits, and the helper
//! writes each mention from its own data, so a mention always carries the key this computer knows for that friend.

use serde_json::Value;

use super::{IntentError, IntentState, Result, MESSAGE_BYTES_MAX};
use crate::presentation::mentions::{
    mention_link, mention_name, mentions_neutralized, MENTIONS_MAX, MENTION_PLACEHOLDER,
};
use crate::store::Relation;

/// The mention of the friend `entry` names: invalid_field for a malformed entry, not_found for nobody, not_allowed for
/// anyone who is not a friend with a Friends ID and a key.
fn mention_for(entry: &Value, field: &str, state: &dyn IntentState) -> Result<String> {
    let id = entry.get("conversation_id").and_then(Value::as_str);
    let id = id.filter(|id| !id.is_empty() && id.encode_utf16().count() <= 64);
    let id = id.ok_or_else(|| IntentError::field("invalid_field", field))?;
    let relation = state.relation(id).ok_or_else(|| IntentError::field("not_found", field))?;
    let link = match (relation, state.mention_target(id)) {
        (Relation::Friend, Some((name, friends_id, key))) if !friends_id.is_empty() => {
            mention_link(&mention_name(name.as_deref(), Some(&friends_id)), &friends_id, &key)
        }
        _ => None,
    };
    link.ok_or_else(|| IntentError::field("not_allowed", field))
}

/// send_message's text as it is sent: every Friends link the person typed made plain text, then each U+FFFC replaced
/// by the mention of the friend `mentions` names in its place. Errors when `mentions` does not fit the text, names
/// someone who cannot be mentioned, or makes the text too long.
pub fn text_with_mentions(text: &str, mentions: Option<&Value>, state: &dyn IntentState) -> Result<String> {
    // Nothing the person typed is a mention, however it looks: only what `mentions` names becomes one.
    let typed = mentions_neutralized(text);
    let mentions = match mentions {
        None | Some(Value::Null) => return Ok(typed),
        Some(value) => value,
    };
    let pieces: Vec<&str> = typed.split(MENTION_PLACEHOLDER).collect();
    let entries = mentions.as_array().filter(|m| m.len() <= MENTIONS_MAX && pieces.len() == m.len() + 1);
    let entries = entries.ok_or_else(|| IntentError::field("invalid_field", "mentions"))?;
    let mut written = pieces[0].to_owned();
    for (i, entry) in entries.iter().enumerate() {
        written.push_str(&mention_for(entry, &format!("mentions[{i}]"), state)?);
        written.push_str(pieces[i + 1]);
    }
    if written.len() > MESSAGE_BYTES_MAX {
        return Err(IntentError::field("invalid_field", "text"));
    }
    Ok(written)
}

//! Intents about people and the person's own profile (`SZFriendsIntentRouter+People.m`, `+Profile.m`,
//! `+Mentions.m`, `+Join.m`, `+Devices.m`): Add by ID and from a mention, the name, the picture, automatic
//! acceptance, the ID notice, a join code and this computer's name.

use serde_json::Value;

use super::{person, required, string, Intent, IntentError, IntentState, Result, Wording, NAME_MAX};
use crate::presentation::mentions::{key_from_string, mention_link, mention_name};
use crate::presentation::text::{clusters, trim};

/// Characters a name may not contain: C0 and C1 controls, line and paragraph separators, and the bidirectional
/// overrides and isolates, which can make a name display as something else. Format characters such as the zero-width
/// joiner stay allowed, since emoji sequences need them.
fn forbidden_in_name(c: char) -> bool {
    matches!(u32::from(c), 0x00..=0x1F | 0x7F..=0x9F | 0x2028..=0x2029 | 0x202A..=0x202E | 0x2066..=0x2069)
}

/// set_name's name: None clears it; name_invalid for one that is only spaces, longer than 40 characters as people
/// count them, or holding a forbidden character.
pub fn checked_name(name: &str) -> Result<Option<String>> {
    let trimmed = trim(name);
    if !name.is_empty() && trimmed.is_empty() {
        return Err(IntentError::field("name_invalid", "name"));
    }
    if !trimmed.is_empty() && (clusters(trimmed).len() > NAME_MAX || trimmed.chars().any(forbidden_in_name)) {
        return Err(IntentError::field("name_invalid", "name"));
    }
    Ok((!trimmed.is_empty()).then(|| trimmed.to_owned()))
}

fn normalized_id(typed: &str, state: &dyn IntentState) -> Result<String> {
    state
        .word_list()
        .and_then(|list| list.normalized_id(typed))
        .ok_or_else(|| IntentError::field("id_invalid", "friends_id"))
}

fn add_from_mention(frame: &Value, state: &dyn IntentState) -> Result<Intent> {
    let typed_id = required(frame, "friends_id", 100)?;
    let key_text = required(frame, "identity_key", 64)?;
    let typed_name = required(frame, "name", 512)?;
    let friends_id = normalized_id(&typed_id, state)?;
    let name = mention_name(Some(&typed_name), None);
    let Some(key) = key_from_string(&key_text) else {
        return Err(IntentError::field("invalid_field", "identity_key"));
    };
    if mention_link(&name, &friends_id, &key).is_none() {
        return Err(IntentError::field("invalid_field", "name"));
    }
    Ok(Intent::AddFromMention { friends_id, identity_key: key, name })
}

/// Everything else the helper takes.
pub(super) fn parse_profile(kind: &str, frame: &Value, state: &dyn IntentState) -> Result<Intent> {
    Ok(match kind {
        "add_by_id" => {
            let typed = required(frame, "friends_id", 100)?;
            Intent::AddById { friends_id: normalized_id(&typed, state)? }
        }
        "add_from_mention" => add_from_mention(frame, state)?,
        "set_name" => {
            let name = string(frame, "name").ok_or_else(|| IntentError::field("invalid_field", "name"))?;
            Intent::SetName { name: checked_name(name)? }
        }
        "set_picture" => Intent::SetPicture { picture: frame.get("picture").cloned().unwrap_or(Value::Null) },
        "set_auto_accept" => {
            let (conversation_id, _) = person(frame, state)?;
            let enabled = frame.get("enabled").and_then(Value::as_bool);
            let enabled = enabled.ok_or_else(|| IntentError::field("invalid_field", "enabled"))?;
            Intent::SetAutoAccept { conversation_id, enabled }
        }
        "dismiss_banner" => {
            if string(frame, "kind") != Some("id_changed") {
                return Err(IntentError::field("invalid_field", "kind"));
            }
            Intent::DismissBanner
        }
        "enter_join_code" => {
            let code = string(frame, "code").filter(|c| c.encode_utf16().count() <= 32);
            let code = code.ok_or_else(|| IntentError::field("invalid_field", "code").worded(Wording::Join))?;
            Intent::EnterJoinCode { code: code.to_owned() }
        }
        "rename_device" => {
            let name = string(frame, "name");
            let name =
                name.ok_or_else(|| IntentError::field("name_invalid", "name").worded(Wording::Devices("empty")))?;
            Intent::RenameDevice { name: name.to_owned() }
        }
        _ => return Err(IntentError::new("unknown_intent")),
    })
}

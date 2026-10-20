//! The intents of PROTOCOL.md § Intents (`service/helper/SZFriendsIntentRouter*.m`): which intents a helper takes and
//! when ([`admit`]), each intent's fields read and checked as the helper checks them, in the helper's order
//! ([`parse`]), and the replies, with the catalog's words for the person who asked ([`reply`]).
//!
//! Parsing reaches into the helper's state only through [`IntentState`]: whether a conversation exists and how the
//! person stands, a subscription's view, the word list, and who a mention may name. What an intent then does (the
//! store, the outbox, sessions) is the dispatcher's, which also answers the state errors that come after the fields
//! (`stale`, `not_friends` for a relation, `not_found` for a transfer or an item).

mod compose;
mod content;
mod gate;
mod links;
mod profile;
mod reply;

use std::collections::BTreeSet;

use serde_json::{json, Map, Value};

use crate::store::Relation;
use szfriends_identity::friends_id::WordList;

pub use compose::text_with_mentions;
pub use gate::{admit, Admission, KNOWN_INTENTS};
pub use links::{base64url_encode, friend_link_payload, parse_link_payload, LinkPayload};
pub use reply::{error_frame, error_message, ok_frame, retryable};

/// PROTOCOL.md § Limits.
pub const MESSAGE_BYTES_MAX: usize = 32_768;
pub const FILES_PER_SEND_MAX: usize = 100;
pub const ATTACHMENTS_MAX: usize = 20;
pub const QUERY_MAX: usize = 200;
pub const SEARCH_LIMIT_DEFAULT: usize = 20;
pub const SEARCH_LIMIT_MAX: usize = 50;
pub const NAME_MAX: usize = 40;
pub const MESSAGE_STATUS_MAX: usize = 16;

/// A subscribable view.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum View {
    Badge,
    List,
    Nearby,
    Details,
    Profile,
    Settings,
    MessageStatus,
    Join,
    /// The files received here (helper capability `received.folder`).
    Received,
}

/// A file object (`type.file`): a path, the name it is shown under, and the revision it must still be.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileRef {
    pub path: String,
    pub display_name: Option<String>,
    pub revision: Option<Revision>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Revision {
    pub source: String,
    pub document_id: String,
    pub revision_id: String,
    pub label: Option<String>,
    pub sha256: Option<[u8; 32]>,
    pub size: u64,
}

/// One intent, its fields checked.
#[derive(Clone, Debug, PartialEq)]
pub enum Intent {
    Ping,
    Activate,
    Disable,
    Subscribe {
        view: View,
        conversation_id: Option<String>,
        message_ids: Option<Vec<String>>,
    },
    Unsubscribe {
        subscription: String,
    },
    SetFilter {
        subscription: String,
        query: String,
    },
    OpenConversation {
        conversation_id: String,
        message_id: Option<String>,
    },
    LoadEarlier {
        subscription: String,
    },
    /// `text` as it is sent: whatever the person typed made plain text, and each U+FFFC the mention `mentions` names.
    SendMessage {
        conversation_id: String,
        text: String,
        client_token: String,
        attachments: Vec<FileRef>,
        via_assistant: bool,
    },
    SendFiles {
        conversation_id: String,
        files: Vec<FileRef>,
        client_token: String,
        via_assistant: bool,
    },
    /// A send_message (`message`) or send_files whose client token already sent something: the reply is what that
    /// send returned, and nothing is sent twice.
    Resend {
        client_token: String,
        message: bool,
    },
    CancelTransfer {
        transfer_id: String,
    },
    AcceptOffer {
        transfer_id: String,
    },
    DeclineOffer {
        transfer_id: String,
    },
    RetryItem {
        item_id: String,
    },
    CancelMessage {
        message_id: String,
    },
    AcceptRequest {
        conversation_id: String,
    },
    DeclineRequest {
        conversation_id: String,
    },
    CancelRequest {
        conversation_id: String,
    },
    SendRequest {
        nearby_id: String,
    },
    /// The ID normalised by the word list.
    AddById {
        friends_id: String,
    },
    AddFromMention {
        friends_id: String,
        identity_key: [u8; 32],
        name: String,
    },
    OpenLink {
        payload: String,
        link: LinkPayload,
    },
    AddFromLink {
        payload: String,
        link: LinkPayload,
    },
    ReceiveLink {
        payload: String,
        link: LinkPayload,
    },
    MakeDownloadLink {
        file: FileRef,
        expires_days: u32,
    },
    ResetFriendLink,
    RevokeLink {
        link_id: [u8; 16],
    },
    /// The ID normalised by the word list.
    JoinProfile {
        friends_id: String,
    },
    EnterJoinCode {
        code: String,
    },
    CancelJoin,
    ApproveJoin {
        join_id: String,
    },
    DenyJoin {
        join_id: String,
    },
    RevokeDevice {
        device_id: String,
    },
    RenameDevice {
        name: String,
    },
    FetchFromDevice {
        transfer_id: String,
    },
    Block {
        conversation_id: String,
    },
    Unblock {
        conversation_id: String,
    },
    /// Takes the person off the list, ending the friendship or request first; `delete_history` also deletes the chat.
    RemoveFriend {
        conversation_id: String,
        delete_history: bool,
    },
    MarkVerified {
        conversation_id: String,
    },
    AcceptKeyChange {
        conversation_id: String,
    },
    /// None clears the name: friends then see the Friends ID.
    SetName {
        name: Option<String>,
    },
    /// The picture object as sent; the avatars area parses, limits and decodes it.
    SetPicture {
        picture: Value,
    },
    SetAutoAccept {
        conversation_id: String,
        enabled: bool,
    },
    /// The folder received files are saved to on this computer, as given (the store checks it).
    SetReceivedFolder {
        path: String,
    },
    DismissBanner,
    StartVisibility,
    StopVisibility,
    SearchMessages {
        query: String,
        conversation_id: Option<String>,
        limit: usize,
    },
    DeleteHistory {
        conversation_id: Option<String>,
    },
    ResetFriends,
}

/// How an error's message is worded for the person.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Wording {
    /// The catalog's words for the code and details ([`crate::presentation::Strings::error_message`]).
    General,
    /// The join intents' own words.
    Join,
    /// The devices intents' own words, for this reason ("device", "empty", "invalid", "fetch", "again",
    /// "device_removed").
    Devices(&'static str),
    /// Named as the mention or card named the person.
    Named(String),
    /// Worded for the folder the person picked in Settings (set_received_folder), not for a file being sent.
    ReceivedFolder,
}

/// A refused intent: the code and wire details, and how its message is worded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IntentError {
    pub code: &'static str,
    pub details: Map<String, Value>,
    pub wording: Wording,
}

impl IntentError {
    pub fn new(code: &'static str) -> Self {
        Self { code, details: Map::new(), wording: Wording::General }
    }

    /// `code` with `details.field`.
    pub fn field(code: &'static str, field: impl Into<String>) -> Self {
        let mut error = Self::new(code);
        error.details.insert("field".into(), json!(field.into()));
        error
    }

    pub fn worded(mut self, wording: Wording) -> Self {
        self.wording = wording;
        self
    }
}

/// What parsing asks of the helper's state.
pub trait IntentState {
    /// How the person a conversation id names stands, or None when there is nobody with it.
    fn relation(&self, conversation_id: &str) -> Option<Relation>;
    /// The name, Friends ID and identity key a mention of this conversation's person carries; None for anyone who
    /// cannot be mentioned (no ID or key).
    fn mention_target(&self, conversation_id: &str) -> Option<(Option<String>, String, [u8; 32])>;
    /// The view of one of this connection's subscriptions.
    fn subscription_view(&self, subscription: &str) -> Option<String>;
    /// The Friends ID word list; None reads every ID as invalid.
    fn word_list(&self) -> Option<&WordList>;
    /// The capabilities this client declared in its hello.
    fn client_capabilities(&self) -> &BTreeSet<String>;
    /// Whether a send with this client token already went out (PROTOCOL.md § Intents, idempotency).
    fn sent_before(&self, client_token: &str) -> bool {
        let _ = client_token;
        false
    }
}

pub(crate) type Result<T> = std::result::Result<T, IntentError>;

pub(crate) fn string<'a>(intent: &'a Value, key: &str) -> Option<&'a str> {
    intent.get(key).and_then(Value::as_str)
}

/// A required string: present, a string, not empty and at most `max` UTF-16 units; invalid_field otherwise.
pub(crate) fn required(intent: &Value, key: &str, max: usize) -> Result<String> {
    match string(intent, key) {
        Some(value) if !value.is_empty() && value.encode_utf16().count() <= max => Ok(value.to_owned()),
        _ => Err(IntentError::field("invalid_field", key)),
    }
}

/// The person `conversation_id` names: invalid_field, or not_found when nobody has it.
pub(crate) fn person(intent: &Value, state: &dyn IntentState) -> Result<(String, Relation)> {
    let id = required(intent, "conversation_id", 64)?;
    match state.relation(&id) {
        Some(relation) => Ok((id, relation)),
        None => Err(IntentError::field("not_found", "conversation_id")),
    }
}

/// remove_friend: `delete_history`, when present and not null, must be a bool; then anyone but You.
fn remove_friend(frame: &Value, state: &dyn IntentState) -> Result<Intent> {
    let delete_history = match frame.get("delete_history") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(value)) => *value,
        Some(_) => return Err(IntentError::field("invalid_field", "delete_history")),
    };
    let (conversation_id, _) = person(frame, state)?;
    if conversation_id == crate::store::sync_log::YOU {
        return Err(IntentError::new("not_allowed"));
    }
    Ok(Intent::RemoveFriend { conversation_id, delete_history })
}

/// An intent's fields read and checked in the helper's order. `frame` is the whole client frame; its `type` must be
/// an intent this helper takes ([`admit`] first).
pub fn parse(frame: &Value, state: &dyn IntentState) -> Result<Intent> {
    let kind = string(frame, "type").unwrap_or("");
    let conversation = |make: fn(String) -> Intent| person(frame, state).map(|(id, _)| make(id));
    Ok(match kind {
        "ping" => Intent::Ping,
        "activate" => Intent::Activate,
        "disable" => Intent::Disable,
        "accept_request" => conversation(|id| Intent::AcceptRequest { conversation_id: id })?,
        "decline_request" => conversation(|id| Intent::DeclineRequest { conversation_id: id })?,
        "cancel_request" => conversation(|id| Intent::CancelRequest { conversation_id: id })?,
        "block" => conversation(|id| Intent::Block { conversation_id: id })?,
        "unblock" => conversation(|id| Intent::Unblock { conversation_id: id })?,
        "remove_friend" => remove_friend(frame, state)?,
        "mark_verified" => conversation(|id| Intent::MarkVerified { conversation_id: id })?,
        "accept_key_change" => conversation(|id| Intent::AcceptKeyChange { conversation_id: id })?,
        "cancel_transfer" => Intent::CancelTransfer { transfer_id: required(frame, "transfer_id", 64)? },
        "accept_offer" => Intent::AcceptOffer { transfer_id: required(frame, "transfer_id", 64)? },
        "decline_offer" => Intent::DeclineOffer { transfer_id: required(frame, "transfer_id", 64)? },
        "retry_item" => Intent::RetryItem { item_id: required(frame, "item_id", 64)? },
        "cancel_message" => Intent::CancelMessage { message_id: required(frame, "message_id", 64)? },
        "send_request" => Intent::SendRequest { nearby_id: required(frame, "nearby_id", 64)? },
        "approve_join" => Intent::ApproveJoin { join_id: required(frame, "join_id", 64)? },
        "deny_join" => Intent::DenyJoin { join_id: required(frame, "join_id", 64)? },
        "revoke_device" => Intent::RevokeDevice { device_id: required(frame, "device_id", 64)? },
        "fetch_from_device" => Intent::FetchFromDevice { transfer_id: required(frame, "transfer_id", 64)? },
        "join_profile" => {
            // The ID typed, read as the word list reads it (U+2011, spaces and case as people type them).
            let typed = required(frame, "friends_id", 100)?;
            let id = state.word_list().and_then(|list| list.normalized_id(&typed));
            let id = id.ok_or_else(|| IntentError::field("id_invalid", "friends_id").worded(Wording::Join))?;
            Intent::JoinProfile { friends_id: id }
        }
        "cancel_join" => Intent::CancelJoin,
        "reset_friend_link" => Intent::ResetFriendLink,
        "start_visibility" => Intent::StartVisibility,
        "stop_visibility" => Intent::StopVisibility,
        "subscribe" | "unsubscribe" | "set_filter" | "open_conversation" | "load_earlier" | "search_messages"
        | "delete_history" | "reset_friends" => content::parse_reading(kind, frame, state)?,
        "send_message" | "send_files" => content::parse_sending(kind, frame, state)?,
        "open_link" | "add_from_link" | "receive_link" | "make_download_link" | "revoke_link" => {
            links::parse_link_intent(kind, frame)?
        }
        _ => profile::parse_profile(kind, frame, state)?,
    })
}

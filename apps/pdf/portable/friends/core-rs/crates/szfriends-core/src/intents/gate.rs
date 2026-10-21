//! Which intents a helper takes, and when (`connection:handleIntent:reply:` in `SZFriendsIntentRouter.m`): an intent
//! outside protocol 1.0, or in a family whose helper capability is absent, is `unknown_intent`; without a store or an
//! identity only reads and the way out work; a computer another one removed reads and sends nothing.

use super::{IntentError, Wording};

/// Every intent of protocol 1.0 this helper implements. The assistant_* family needs `assistant.scopes`, which no
/// helper announces yet, so those are unknown_intent.
pub const KNOWN_INTENTS: [&str; 55] = [
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
    "accept_request",
    "decline_request",
    "cancel_request",
    "send_request",
    "add_by_id",
    "block",
    "unblock",
    "remove_friend",
    "mark_verified",
    "accept_key_change",
    "set_name",
    "set_picture",
    "set_auto_accept",
    "dismiss_banner",
    "start_visibility",
    "stop_visibility",
    "search_messages",
    "delete_history",
    "reset_friends",
    "disable",
    "cancel_message",
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
    "fetch_from_friend",
    "set_received_folder",
    "set_focus",
    "set_notifications",
    "allow_notifications",
    "test_notification_response",
];

/// System notifications: only while the helper announces `notifications`; the test response only in a test home.
const NOTIFICATIONS_INTENTS: [&str; 4] =
    ["set_focus", "set_notifications", "allow_notifications", "test_notification_response"];

/// One profile on several computers: only while the helper announces `devices`.
const DEVICES_INTENTS: [&str; 8] = [
    "revoke_device",
    "rename_device",
    "fetch_from_device",
    "join_profile",
    "enter_join_code",
    "cancel_join",
    "approve_join",
    "deny_join",
];

/// Friend links and download links: only while the helper announces `links` (PROTOCOL.md § Links).
const LINKS_INTENTS: [&str; 6] =
    ["open_link", "add_from_link", "receive_link", "make_download_link", "reset_friend_link", "revoke_link"];

/// What a removed computer still does: read, search, Start Over, leave.
const ON_REMOVED_COMPUTER: [&str; 12] = [
    "ping",
    "activate",
    "subscribe",
    "unsubscribe",
    "set_filter",
    "open_conversation",
    "load_earlier",
    "search_messages",
    "reset_friends",
    "disable",
    "dismiss_banner",
    "set_focus",
];

/// What works while the identity key cannot be read: reads, the reset that fixes it, leaving, and where received
/// files go (this computer's own setting).
const WITHOUT_IDENTITY: [&str; 12] = [
    "ping",
    "activate",
    "subscribe",
    "unsubscribe",
    "set_filter",
    "open_conversation",
    "load_earlier",
    "search_messages",
    "delete_history",
    "reset_friends",
    "disable",
    "set_received_folder",
];

/// What works without a store: nothing that reads or writes Friends data.
const WITHOUT_STORE: [&str; 6] = ["ping", "activate", "subscribe", "unsubscribe", "set_filter", "disable"];

/// The helper's state as the gates see it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Admission {
    /// The store opened.
    pub has_store: bool,
    /// The store needs a newer helper (another app updated it): a state, not a bug.
    pub store_needs_update: bool,
    /// The identity key could be read.
    pub has_identity: bool,
    /// The helper announces `devices`.
    pub devices: bool,
    /// The helper announces `links`.
    pub links: bool,
    /// Another of the person's computers removed this one.
    pub removed_computer: bool,
    /// The helper announces `received.folder`.
    pub received_folder: bool,
    /// The helper announces `files.again`.
    pub files_again: bool,
    /// The helper announces `notifications`.
    pub notifications: bool,
    /// The helper runs in a test home (`SZFRIENDS_STATE_DIR`): `test_notification_response` is taken.
    pub test_home: bool,
}

/// Whether the helper takes an intent of this `type` now; the error to reply with otherwise.
pub fn admit(kind: &str, state: Admission) -> Result<(), IntentError> {
    if !KNOWN_INTENTS.contains(&kind) {
        return Err(IntentError::new("unknown_intent"));
    }
    if !state.has_store && !WITHOUT_STORE.contains(&kind) {
        return Err(IntentError::new(if state.store_needs_update { "not_allowed" } else { "internal" }));
    }
    if !state.has_identity && !WITHOUT_IDENTITY.contains(&kind) {
        return Err(IntentError::new("identity_unavailable"));
    }
    if (DEVICES_INTENTS.contains(&kind) && !state.devices)
        || (LINKS_INTENTS.contains(&kind) && !state.links)
        || (kind == "set_received_folder" && !state.received_folder)
        || (kind == "fetch_from_friend" && !state.files_again)
        || (NOTIFICATIONS_INTENTS.contains(&kind) && !state.notifications)
        || (kind == "test_notification_response" && !state.test_home)
    {
        return Err(IntentError::new("unknown_intent"));
    }
    if state.removed_computer && !ON_REMOVED_COMPUTER.contains(&kind) {
        return Err(IntentError::new("not_allowed").worded(Wording::Devices("device_removed")));
    }
    Ok(())
}

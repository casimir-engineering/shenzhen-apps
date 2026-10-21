//! What the builder is told (`SZFriendsPresentation.h` § Facts, `SZFriendsFacts.m`): plain values with defaults
//! that describe "nothing happened yet", so the helper fills only what it knows. The helper fills them from the store,
//! discovery and sessions; the builder reads no store, radio, socket or clock.

use std::collections::{BTreeMap, BTreeSet};

pub use crate::store::{OutboxState, Relation, TransferState};

use super::avatar::Picture;
use super::time::TimeZone;

/// The parts of a client's hello that change wording: each connection gets snapshots written for its own app.
#[derive(Clone, Debug)]
pub struct Audience {
    /// "ShenzhenPDF": "...the next time ShenzhenPDF reaches...".
    pub app_name: String,
    /// "Finder": "Show in Finder".
    pub reveal_in: String,
    /// M1 ships English only; reserved for translations.
    pub locale: String,
    /// The client's capabilities: "assistant.drafts" adds "/ Ask the assistant", "mentions" shows mentions...
    pub capabilities: BTreeSet<String>,
    /// Received files in these formats offer Open.
    pub open_formats: BTreeSet<String>,
    pub time_zone: TimeZone,
    /// What the helper announces in this client's welcome: "online" lets the words say Online and Connecting.
    pub helper_capabilities: BTreeSet<String>,
}

impl Default for Audience {
    fn default() -> Self {
        // Neutral words until a hello names the app: a sentence with "this app" is still true.
        Self {
            app_name: "this app".into(),
            reveal_in: "Finder".into(),
            locale: "en".into(),
            capabilities: BTreeSet::new(),
            open_formats: BTreeSet::new(),
            time_zone: TimeZone::default(),
            helper_capabilities: BTreeSet::new(),
        }
    }
}

impl Audience {
    pub fn has(&self, capability: &str) -> bool {
        self.capabilities.contains(capability)
    }

    pub fn helper_has(&self, capability: &str) -> bool {
        self.helper_capabilities.contains(capability)
    }
}

/// `SZFriendsRouteKind`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum RouteKind {
    /// Nothing to show (a request by ID that never connected): no route icon.
    None,
    /// A nearby session is up.
    Local,
    /// An Internet session is up.
    Online,
    /// A friend with no working route.
    #[default]
    Offline,
}

/// `SZFriendsRouteMethod`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum RouteMethod {
    #[default]
    None,
    Lan,
    PeerToPeerWifi,
    Bluetooth,
    Internet,
    Relay,
}

/// `SZFriendsAdapterState`: one discovery method's state.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum AdapterState {
    #[default]
    NotAsked,
    Starting,
    Working,
    Denied,
    RadioOff,
    Unavailable,
}

/// Where online attempts toward a friend stand, shown only to an audience whose helper announces "online".
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum OnlineReach {
    #[default]
    Unknown,
    Connecting,
    Unreachable,
}

/// `SZFriendsIDState`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum IdState {
    #[default]
    Unreserved,
    Reserved,
    Changed,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum IdentityState {
    #[default]
    Ready,
    /// The list shows the identity_unavailable banner and the profile's id.state is "unavailable".
    Unavailable,
}

/// Why the list shows the `update_required` banner, if it does.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum UpdateNeed {
    #[default]
    None,
    /// The Friends host says online Friends needs a newer app; Nearby still works.
    Online,
    /// Another app on this computer updated the Friends data past what this helper reads.
    Store,
}

/// Event kinds the helper records in history; only the presentation turns them into words.
pub mod event {
    pub const NOW_FRIENDS: &str = "now_friends";
    pub const VERIFIED: &str = "verified";
    pub const KEY_CHANGED: &str = "key_changed";
    pub const KEY_ACCEPTED: &str = "key_accepted";
    pub const BLOCKED: &str = "blocked";
    pub const UNBLOCKED: &str = "unblocked";
    pub const REMOVED: &str = "removed";
    /// Argument "file", the file's name.
    pub const RECEIVED_LINK_FILE: &str = "received_through_link";
    pub const ADDED_THROUGH_OUR_LINK: &str = "added_through_your_link";
    pub const ADDED_THROUGH_THEIR_LINK: &str = "added_through_their_link";
}

/// The store's failure keys a Failed item carries (`SZFriendsOutbox.h`, `SZFriendsTransfers.h`).
pub mod failure {
    pub const NOT_DELIVERED_30_DAYS: &str = "not_delivered_30_days";
    pub const REFUSED: &str = "refused";
    pub const SOURCE_MISSING: &str = "source_missing";
    pub const DIGEST_MISMATCH: &str = "digest_mismatch";
}

/// One person and their conversation (`SZFriendsPersonFacts`).
#[derive(Clone, Debug)]
pub struct PersonFacts {
    pub conversation_id: String,
    /// None: the Friends ID is the title.
    pub name: Option<String>,
    pub friends_id: Option<String>,
    /// Mentions find people by it, never by name or ID.
    pub identity_key: Option<[u8; 32]>,
    pub picture: Picture,
    pub relation: Relation,
    pub route_kind: RouteKind,
    pub route_method: RouteMethod,
    pub online_reach: OnlineReach,
    pub verified: bool,
    pub verified_at: Option<f64>,
    /// The Friends host attested that `friends_id` is reserved for this identity key.
    pub friends_id_confirmed: bool,
    pub auto_accept: bool,
    pub key_change_pending: bool,
    pub unread_count: i64,
    /// Incoming offers waiting for this person's answer.
    pub offers_waiting: i64,
    pub last_interaction_at: f64,
    /// The item the row's subtitle describes.
    pub last_preview_item_id: Option<String>,
    pub request_at: Option<f64>,
    pub request_found_nearby: bool,
    /// An answer to our own Add by ID the host could not confirm: the ID we asked for.
    pub unconfirmed_answer_id: Option<String>,
    /// Six ASCII digits as the session derived them; grouped for display.
    pub comparison_code: Option<String>,
    pub received_file_count: i64,
    pub received_reveal_path: Option<String>,
    /// In the list only because they sent a file through a download link, and not a friend (relation Removed).
    pub link_contact: bool,
    /// Taken off the list (`left_list_at`): the list skips them; their conversation and details still open.
    pub left_list: bool,
    /// The discovery methods that see this person nearby now (lan, p2p_wifi, bluetooth); empty when none do.
    pub found_methods: Vec<RouteMethod>,
}

impl Default for PersonFacts {
    fn default() -> Self {
        Self {
            conversation_id: String::new(),
            name: None,
            friends_id: None,
            identity_key: None,
            picture: Picture::Placeholder,
            relation: Relation::Friend,
            route_kind: RouteKind::Offline,
            route_method: RouteMethod::None,
            online_reach: OnlineReach::Unknown,
            verified: false,
            verified_at: None,
            friends_id_confirmed: false,
            auto_accept: false,
            key_change_pending: false,
            unread_count: 0,
            offers_waiting: 0,
            last_interaction_at: 0.0,
            last_preview_item_id: None,
            request_at: None,
            request_found_nearby: false,
            unconfirmed_answer_id: None,
            comparison_code: None,
            received_file_count: 0,
            received_reveal_path: None,
            link_contact: false,
            left_list: false,
            found_methods: Vec::new(),
        }
    }
}

impl PersonFacts {
    /// What the store holds of a person; the rest (routes, pictures, verification...) is the caller's to add.
    pub fn from_store(person: &crate::store::Person) -> Self {
        Self {
            conversation_id: person.conversation_id.clone(),
            name: person.name.clone(),
            friends_id: person.friends_id.clone(),
            identity_key: person.identity_key,
            relation: person.relation,
            auto_accept: person.auto_accept,
            comparison_code: person.comparison_code.clone(),
            last_interaction_at: person.last_interaction_at,
            unread_count: person.unread_count,
            left_list: person.left_list_at.is_some(),
            ..Self::default()
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ItemKind {
    #[default]
    Message,
    Transfer,
    Event,
}

/// Get again on a file a friend sent (PROTOCOL.md § Getting a file again; `SZFriendsAgainState`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum AgainState {
    #[default]
    None,
    /// Get again pressed: waiting for the friend, or copying.
    Asked,
    /// The friend's computer answered that it no longer has the file.
    Gone,
}

/// One history item (`SZFriendsItemFacts`).
#[derive(Clone, Debug, Default)]
pub struct ItemFacts {
    pub item_id: String,
    /// Set where an item is shown away from its conversation (message_status).
    pub conversation_id: Option<String>,
    pub kind: ItemKind,
    pub outgoing: bool,
    pub sent_at: f64,
    pub text: Option<String>,
    pub via_assistant: bool,
    /// An outgoing message's delivery record; None gives it no status at all.
    pub outbox_state: Option<OutboxState>,
    /// Withdrawn before it left (cancel_message).
    pub cancelled: bool,
    /// Written to a session at least once: waiting again, it may already be there, so no Cancel.
    pub outbox_written: bool,
    /// Why a Failed item failed, as the store keys it ([`failure`]).
    pub failure_reason: Option<String>,
    pub transfer_id: Option<String>,
    pub file_name: Option<String>,
    pub file_extension: Option<String>,
    pub file_size: u64,
    pub bytes_done: u64,
    pub transfer_state: Option<TransferState>,
    pub accepted_automatically: bool,
    pub asked_because_disk_low: bool,
    pub transfer_route: RouteMethod,
    /// Measured on the current route; 0 when unknown.
    pub bytes_per_second: f64,
    /// A received file, once published.
    pub local_path: Option<String>,
    /// The folder a received file was saved in, for its "Saved to {folder}"; `None` (older files, or kept in the
    /// store's own folder) keeps "Received".
    pub saved_in: Option<crate::store::SavedPlace>,
    /// A file received or copied here (or by another computer of the profile) whose bytes this computer no longer
    /// has: the person moved or deleted it. `local_path` is None then. Where it can come from is the devices facts'
    /// `files` (another computer) or the `again` facts below (the friend who sent it).
    pub file_missing: bool,
    /// Get again on a friend's file (fetch_from_friend): asked and waiting or copying, or answered that they no longer
    /// have it; whether a session with that friend is live, so it copies now; and how much arrived.
    pub again: AgainState,
    pub again_connected: bool,
    pub again_fraction: f64,
    pub file_type_identifier: Option<String>,
    pub thumbnail_path: Option<String>,
    pub thumbnail_width: u32,
    pub thumbnail_height: u32,
    pub thumbnail_from_sender: bool,
    pub event_kind: Option<String>,
    pub event_arguments: BTreeMap<String, String>,
}

impl ItemFacts {
    /// The transfer's state, Queued when unset (the helper's integer default).
    pub fn state(&self) -> TransferState {
        self.transfer_state.unwrap_or(TransferState::Queued)
    }

    /// What the store holds of a history item.
    pub fn from_store(item: &crate::store::Item) -> Self {
        let kind = match item.kind {
            crate::store::ItemKind::Message => ItemKind::Message,
            crate::store::ItemKind::Transfer => ItemKind::Transfer,
            crate::store::ItemKind::Event => ItemKind::Event,
        };
        Self {
            item_id: item.item_id.clone(),
            conversation_id: Some(item.conversation_id.clone()),
            kind,
            outgoing: item.direction == crate::store::Direction::Outgoing,
            sent_at: item.sent_at,
            text: item.text.clone(),
            via_assistant: item.via_assistant,
            transfer_id: item.transfer_id.clone(),
            ..Self::default()
        }
    }
}

/// Someone Nearby shows (`SZFriendsNearbyPersonFacts`).
#[derive(Clone, Debug)]
pub struct NearbyPersonFacts {
    /// Ephemeral handle for a public entry (send_request takes it); None for a friend seen by presence tag.
    pub nearby_id: Option<String>,
    pub conversation_id: Option<String>,
    pub name: Option<String>,
    pub friends_id: Option<String>,
    pub picture: Picture,
    pub relation: Relation,
    pub is_stranger: bool,
    pub route_method: RouteMethod,
    /// The discovery methods that see this person now (lan, p2p_wifi, bluetooth).
    pub found_methods: Vec<RouteMethod>,
}

impl Default for NearbyPersonFacts {
    fn default() -> Self {
        Self {
            nearby_id: None,
            conversation_id: None,
            name: None,
            friends_id: None,
            picture: Picture::Placeholder,
            relation: Relation::Friend,
            is_stranger: false,
            route_method: RouteMethod::None,
            found_methods: Vec::new(),
        }
    }
}

/// How long after a method starts working an empty Nearby keeps saying it is looking.
pub const NEARBY_SEARCHING_SECONDS: f64 = 8.0;

#[derive(Clone, Debug, Default)]
pub struct NearbyFacts {
    /// None when not visible.
    pub visibility_deadline: Option<f64>,
    pub network_state: AdapterState,
    pub bluetooth_state: AdapterState,
    /// At least one method is working and looking.
    pub searching: bool,
    /// When the first method started working since Nearby last started; None while none works.
    pub working_since: Option<f64>,
    pub people: Vec<NearbyPersonFacts>,
    /// This computer accepts no connections nearby (a Windows firewall without a rule for it): it reaches friends
    /// itself, and nobody nearby can see it.
    pub inbound_blocked: bool,
    /// This computer has no Bluetooth route at all (Windows): Nearby says nothing of Bluetooth.
    pub bluetooth_absent: bool,
    /// A phone: access is changed in its Settings app, not a computer's System Settings.
    pub phone: bool,
}

/// One download link as "Your links" shows it.
#[derive(Clone, Debug, Default)]
pub struct DownloadLinkFacts {
    /// base64url of the 16-byte id, as revoke_link takes it.
    pub link_id: String,
    pub file_name: String,
    pub downloads: u64,
    pub expires_at: f64,
}

#[derive(Clone, Debug, Default)]
pub struct LinksFacts {
    /// None while no link can be made (no Friends host).
    pub friend_url: Option<String>,
    /// Live ones, newest first.
    pub downloads: Vec<DownloadLinkFacts>,
    /// What expiry words count from.
    pub now: f64,
}

/// This person's own profile (`SZFriendsProfileFacts`).
#[derive(Clone, Debug, Default)]
pub struct ProfileFacts {
    pub name: Option<String>,
    pub friends_id: String,
    pub friends_id_state: IdState,
    /// This service never checks in with a Friends server (a phone's embedded core without online), so an
    /// unreserved ID stays so and no note promises that it gets confirmed.
    pub nearby_only: bool,
    /// The ID before a collision rename, until the person dismisses the notice.
    pub previous_friends_id: Option<String>,
    pub picture: Picture,
    pub identity_public_key: Option<[u8; 32]>,
    pub identity_state: IdentityState,
    pub update_need: UpdateNeed,
    /// The folder received files go to.
    pub received: ReceivedFolderFacts,
    /// "Your links", for an audience whose helper announces "links"; None shows none.
    pub links: Option<LinksFacts>,
    /// This device's notifications, from a helper that announces "notifications"; None shows no block or card.
    pub notifications: Option<super::notifications::NotificationFacts>,
}

/// The folder received files go to (`settings`' `received`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ReceivedFolderFacts {
    /// The folder; `None` where there is none to show (a phone).
    pub path: Option<String>,
    /// The name of the folder the person chose; `None`: the default Downloads.
    pub chosen_name: Option<String>,
    /// A phone's place, which Friends does not change.
    pub phone: Option<crate::store::PhoneFolder>,
    /// Where the last file went when this folder could not take it.
    pub fallback: Option<crate::store::ReceivedFallback>,
}

/// One local search hit with what the result row needs (`SZFriendsSearchHitFacts`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SearchHitFacts {
    pub conversation_id: String,
    pub item_id: String,
    pub sent_at: f64,
    pub outgoing: bool,
    /// The message text or file name.
    pub text: String,
    /// UTF-16 ranges (start, length) into `text`.
    pub match_ranges: Vec<(usize, usize)>,
}

//! The facts the presentation is built from, read from the store and the live sessions (`SZFriendsHelperFacts.m`):
//! people with their routes and waiting offers, a conversation's history with each item's delivery or transfer
//! state, and this person's own profile.

use std::collections::HashMap;

use rusqlite::{params, OptionalExtension};
use szfriends_core::presentation::{
    IdState, ItemFacts, ItemKind, OutboxState, PersonFacts, ProfileFacts, RouteKind, RouteMethod, TransferState,
};
use szfriends_core::store::{sync_files, Relation};
use szfriends_core::sync::holds_transfer;
use szfriends_identity::friends_id::{system_uniform, word_count_for_new_id, WordList};

use super::State;

/// How many history items a conversation shows before Show earlier messages.
pub const PAGE: usize = 50;

impl State {
    /// Everyone in the list, most recent first, with what only the service knows.
    pub fn people_facts(&self) -> Vec<PersonFacts> {
        let people = self.store.people_by_latest_interaction().unwrap_or_default();
        let link_contacts = self.store.link_contact_conversations();
        // Details' Show in Finder opens the folder received files go to now.
        let folder = self.store.received_folder().map(|p| p.to_string_lossy().into_owned());
        people
            .iter()
            .map(|person| {
                let mut facts = self.person_facts(person);
                facts.link_contact = link_contacts.contains(&person.conversation_id);
                facts.received_reveal_path = folder.clone();
                facts
            })
            .collect()
    }

    /// "Your links", while this helper announces `links` and the Friends host's pages have an origin.
    #[cfg(feature = "online")]
    pub fn links_facts(
        &mut self,
        profile: &ProfileFacts,
        now: f64,
    ) -> Option<szfriends_core::presentation::LinksFacts> {
        if !self.capabilities.iter().any(|c| c == "links") {
            return None;
        }
        let origin = self.online.as_ref().and_then(|o| o.link_origin())?;
        let name = profile.name.clone().unwrap_or_default();
        let friend_url = self.friend_link_url(&origin, &profile.friends_id, &name);
        let mut records = self.store.download_links();
        records.retain(|link| link.expires_at > now);
        szfriends_core::wire::order::sort_by(&mut records, |a, b| b.created_at.total_cmp(&a.created_at));
        let downloads = records
            .iter()
            .map(|link| szfriends_core::presentation::DownloadLinkFacts {
                link_id: szfriends_online::b64::encode_url(&link.link_id),
                file_name: link.file_name.clone(),
                downloads: link.downloads,
                expires_at: link.expires_at,
            })
            .collect();
        Some(szfriends_core::presentation::LinksFacts { friend_url, downloads, now })
    }

    pub fn person_facts(&self, person: &szfriends_core::store::Person) -> PersonFacts {
        let mut facts = PersonFacts::from_store(person);
        let conn = self.store.connection();
        if let Some(route) = self.live_route(&person.conversation_id) {
            facts.route_kind = RouteKind::Local;
            facts.route_method = Self::view_route(route);
        } else if matches!(person.relation, Relation::OutgoingRequest | Relation::IncomingRequest)
            && person.identity_key.is_none()
        {
            facts.route_kind = RouteKind::None; // a request by ID that never connected: no route icon
        }
        facts.request_at = person.request_at;
        facts.request_found_nearby = person.request_found_nearby;
        facts.unconfirmed_answer_id = person.unconfirmed_answer_id.clone();
        facts.friends_id_confirmed = person.friends_id_confirmed;
        facts.key_change_pending = person.key_change_pending;
        if person.relation == Relation::Friend {
            facts.found_methods = self.found_methods_of(&person.conversation_id);
        }
        facts.offers_waiting = conn
            .query_row(
                "SELECT count(*) FROM transfers WHERE conversation_id = ?1 AND outgoing = 0 AND state = ?2",
                params![person.conversation_id, TransferState::WaitingForYou as i64],
                |r| r.get(0),
            )
            .unwrap_or(0);
        facts.last_preview_item_id = conn
            .query_row(
                "SELECT item_id FROM messages WHERE conversation_id = ?1 ORDER BY sent_at DESC, seq DESC LIMIT 1",
                [&person.conversation_id],
                |r| r.get(0),
            )
            .optional()
            .ok()
            .flatten();
        (facts.last_message_item_id, facts.last_message_files) = self.last_message(&person.conversation_id);
        let verified: Option<(i64, Option<f64>)> = conn
            .query_row(
                "SELECT verified, verified_at FROM friends WHERE conversation_id = ?1",
                [&person.conversation_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .ok()
            .flatten();
        if let Some((verified, at)) = verified {
            facts.verified = verified != 0;
            facts.verified_at = at;
        }
        facts.received_file_count = conn
            .query_row(
                "SELECT count(*) FROM transfers WHERE conversation_id = ?1 AND outgoing = 0 \
                 AND received_path IS NOT NULL",
                [&person.conversation_id],
                |r| r.get(0),
            )
            .unwrap_or(0);
        facts
    }

    /// One history item with its delivery or transfer state.
    fn item_facts(&self, row: ItemRow) -> ItemFacts {
        let conn = self.store.connection();
        let kind = match row.kind {
            1 => ItemKind::Transfer,
            2 => ItemKind::Event,
            _ => ItemKind::Message,
        };
        let mut item = ItemFacts {
            item_id: row.item_id.clone(),
            conversation_id: Some(row.conversation_id.clone()),
            kind,
            outgoing: row.direction == 1,
            sent_at: row.sent_at,
            text: row.body.clone(),
            via_assistant: row.via_assistant,
            transfer_id: row.transfer_id.clone(),
            event_kind: row.event_kind.clone(),
            ..ItemFacts::default()
        };
        if let Some(arguments) = row.event_args.as_deref().and_then(|a| serde_json::from_str(a).ok()) {
            item.event_arguments = arguments;
        }
        if kind == ItemKind::Message && item.outgoing {
            let entry: Option<(i64, i64, Option<String>)> = conn
                .query_row(
                    "SELECT state, attempts, failure_reason FROM outbox WHERE conversation_id = ?1 AND item_id = ?2",
                    params![row.conversation_id, row.item_id],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )
                .optional()
                .ok()
                .flatten();
            // A message the outbox no longer holds was delivered before it was cleared.
            let (state, attempts, failure) = entry.unwrap_or((OutboxState::Delivered as i64, 1, None));
            item.outbox_state = OutboxState::from_i64(state);
            item.outbox_written = attempts > 0;
            item.failure_reason = failure;
        }
        if let Some(transfer) = item.transfer_id.as_deref().and_then(|id| self.store.transfer(id).ok().flatten()) {
            item.file_name = Some(transfer.file_name.clone());
            item.file_extension =
                std::path::Path::new(&transfer.file_name).extension().and_then(|e| e.to_str()).map(str::to_lowercase);
            item.file_size = transfer.size;
            // By blocks (ADR 0018), what checked so far, in any order; otherwise the durable prefix.
            item.bytes_done = self.store.block_progress(&transfer.transfer_id).unwrap_or(transfer.verified_bytes);
            item.finishing = !transfer.outgoing && self.shows_finishing(&transfer.transfer_id);
            item.boost = self.boost_facts(&transfer.transfer_id);
            item.transfer_state = Some(transfer.state);
            item.failure_reason = transfer.failure_reason.clone();
            item.local_path = transfer.received_path.as_ref().map(|p| p.to_string_lossy().into_owned());
            if !item.outgoing {
                item.saved_in = transfer.received_path.as_deref().and_then(|p| self.store.saved_place(p));
            }
            item.transfer_route =
                self.live_route(&transfer.conversation_id).map_or(RouteMethod::None, Self::view_route);
            let automatic: i64 = conn
                .query_row(
                    "SELECT accepted_automatically FROM transfers WHERE transfer_id = ?1",
                    [&transfer.transfer_id],
                    |r| r.get(0),
                )
                .unwrap_or(0);
            item.accepted_automatically = automatic != 0;
            // Moved or deleted: a file received or copied here whose bytes are gone from where they were saved.
            let synced = sync_files::transfer(conn, &transfer.transfer_id).ok().flatten();
            let kept = transfer.received_path.is_some() && (item.outgoing || transfer.state == TransferState::Received);
            if kept && synced.is_some_and(|t| !holds_transfer(&self.store, &t)) {
                item.file_missing = true;
                item.local_path = None;
                item.saved_in = None;
                self.devices.missing_seen.set(true);
            }
        } else if let Some(file) = item.transfer_id.as_deref().and_then(|id| sync_files::sync_file(conn, id).ok()?) {
            // A file another computer of ours received: its record is here at once, its bytes when copied.
            item.file_extension =
                std::path::Path::new(&file.file_name).extension().and_then(|e| e.to_str()).map(str::to_lowercase);
            item.file_name = Some(file.file_name.clone());
            item.file_size = file.size;
            item.transfer_state = TransferState::from_i64(file.state);
            // Received there, and no other computer of ours holds it anymore.
            item.file_missing =
                !file.outgoing && file.state == 6 && !file.holders.iter().any(|h| self.is_own_device(h));
        }
        if let Some(transfer_id) = item.transfer_id.clone().filter(|_| !item.outgoing) {
            self.again_facts(&mut item, &transfer_id, &row.conversation_id);
        }
        item
    }

    /// The newest `limit` items of a conversation, oldest first, and whether earlier ones exist.
    pub fn conversation_items(&self, conversation_id: &str, limit: usize) -> (Vec<ItemFacts>, bool) {
        let rows = item_rows(&self.store, "WHERE conversation_id = ?1", conversation_id, limit + 1);
        let has_earlier = rows.len() > limit;
        let mut items: Vec<ItemFacts> = rows.into_iter().take(limit).map(|row| self.item_facts(row)).collect();
        items.reverse();
        (items, has_earlier)
    }

    /// The items the list's rows describe: each person's newest item, and their newest message or file.
    pub fn preview_items(&self, people: &[PersonFacts]) -> HashMap<String, ItemFacts> {
        let mut items = HashMap::new();
        for person in people {
            for id in [&person.last_preview_item_id, &person.last_message_item_id].into_iter().flatten() {
                if items.contains_key(id) {
                    continue;
                }
                if let Some(row) = item_row(&self.store, &person.conversation_id, id) {
                    items.insert(id.clone(), self.item_facts(row));
                }
            }
        }
        items
    }

    /// The newest message or file of a conversation (a file received through a link counts; other events do not),
    /// and how many files went with it: the same kind from the same side, each within a minute of the next.
    fn last_message(&self, conversation_id: &str) -> (Option<String>, i64) {
        let clause = format!(
            "WHERE conversation_id = ?1 AND (kind != 2 OR event_kind = '{}')",
            szfriends_core::presentation::event::RECEIVED_LINK_FILE
        );
        let rows = item_rows(&self.store, &clause, conversation_id, 50);
        let Some(newest) = rows.first() else { return (None, 0) };
        let mut files = 0;
        if newest.kind != 0 {
            let mut later = newest.sent_at;
            for row in rows.iter().take_while(|r| r.kind == newest.kind && r.direction == newest.direction) {
                if later - row.sent_at > 60.0 {
                    break;
                }
                later = row.sent_at;
                files += 1;
            }
        }
        (Some(newest.item_id.clone()), files)
    }

    /// This person's own profile; a first start draws a Friends ID (unreserved until a Friends host confirms it).
    pub fn profile_facts(&mut self) -> ProfileFacts {
        let conn = self.store.connection();
        let row: Option<(Option<String>, Option<String>, i64)> = conn
            .query_row("SELECT name, friends_id, friends_id_state FROM profile WHERE id = 1", [], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .optional()
            .ok()
            .flatten();
        let (name, friends_id, id_state) = row.unwrap_or((None, None, 0));
        let friends_id = match friends_id {
            Some(id) => id,
            None => self.draw_friends_id(),
        };
        ProfileFacts {
            name,
            friends_id,
            friends_id_state: match id_state {
                1 => IdState::Reserved,
                2 => IdState::Changed,
                _ => IdState::Unreserved,
            },
            nearby_only: cfg!(not(feature = "online")),
            identity_public_key: Some(self.identity.public_key()),
            received: self.received_folder_facts(),
            notifications: Some(self.notification_facts()),
            ..ProfileFacts::default()
        }
    }

    /// The folder received files go to, for Settings.
    pub fn received_folder_facts(&self) -> szfriends_core::presentation::ReceivedFolderFacts {
        let chosen = self.store.chosen_received_folder();
        szfriends_core::presentation::ReceivedFolderFacts {
            path: self.store.received_folder().map(|p| p.to_string_lossy().into_owned()),
            chosen_name: chosen.and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned())),
            phone: self.store.received_defaults().phone,
            fallback: self.store.received_fallback(),
        }
    }

    fn draw_friends_id(&mut self) -> String {
        let id = WordList::bundled()
            .map(|list| list.random_id(word_count_for_new_id(2, 0), system_uniform))
            .unwrap_or_default();
        let _ = self.store.connection().execute(
            "INSERT INTO profile (id, friends_id) VALUES (1, ?1) ON CONFLICT(id) DO UPDATE SET friends_id = ?1 \
             WHERE friends_id IS NULL",
            [&id],
        );
        id
    }

    pub fn set_own_name(&mut self, name: &str) -> bool {
        self.store
            .connection()
            .execute("INSERT INTO profile (id, name) VALUES (1, ?1) ON CONFLICT(id) DO UPDATE SET name = ?1", [name])
            .is_ok()
    }
}

pub struct ItemRow {
    pub item_id: String,
    pub conversation_id: String,
    pub kind: i64,
    pub direction: i64,
    pub body: Option<String>,
    pub transfer_id: Option<String>,
    pub sent_at: f64,
    pub via_assistant: bool,
    pub event_kind: Option<String>,
    pub event_args: Option<String>,
}

const ITEM_COLUMNS: &str =
    "item_id, conversation_id, kind, direction, body, transfer_id, sent_at, via_assistant, event_kind, event_args";

fn item_from_row(r: &rusqlite::Row) -> rusqlite::Result<ItemRow> {
    Ok(ItemRow {
        item_id: r.get(0)?,
        conversation_id: r.get(1)?,
        kind: r.get(2)?,
        direction: r.get(3)?,
        body: r.get(4)?,
        transfer_id: r.get(5)?,
        sent_at: r.get(6)?,
        via_assistant: r.get::<_, Option<i64>>(7)?.unwrap_or(0) != 0,
        event_kind: r.get(8)?,
        event_args: r.get(9)?,
    })
}

/// Newest first.
fn item_rows(store: &szfriends_core::store::Store, clause: &str, conversation_id: &str, limit: usize) -> Vec<ItemRow> {
    let sql = format!("SELECT {ITEM_COLUMNS} FROM messages {clause} ORDER BY sent_at DESC, seq DESC LIMIT ?2");
    let Ok(mut statement) = store.connection().prepare(&sql) else { return Vec::new() };
    let rows = statement.query_map(params![conversation_id, limit as i64], item_from_row);
    rows.map(|rows| rows.filter_map(Result::ok).collect()).unwrap_or_default()
}

pub fn item_row(store: &szfriends_core::store::Store, conversation_id: &str, item_id: &str) -> Option<ItemRow> {
    let sql = format!("SELECT {ITEM_COLUMNS} FROM messages WHERE conversation_id = ?1 AND item_id = ?2");
    store.connection().query_row(&sql, params![conversation_id, item_id], item_from_row).optional().ok().flatten()
}

//! System notifications in the service (ADR 0017, PROTOCOL.md § Notifications): what notifies is decided once, when
//! an item is first committed to this device's store, and a [`Notifier`] posts it (toasts, freedesktop, a phone's
//! native code, or the test home's sink).
//!
//! Every pass after an input reads what the store gained since the last one: friends' messages and file offers
//! (`messages.seq` past the last row seen), files accepted automatically once they arrive, requests and acceptances
//! (people's relations against the last ones seen) and computers asking to join. Nothing in the store when the
//! service started is ever seen. The never-rules apply at that moment: the You conversation, outgoing items, blocked
//! people, a conversation a focused window shows, items that came by sync already read or older than ten minutes or
//! from before this device joined, and anything while Notifications is off or the system refuses. Messages in one
//! conversation within one second make one notification for the newest; files offered together make one.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;

use rusqlite::OptionalExtension;
use serde_json::{json, Value};
use szfriends_core::presentation::{
    Audience, MentionDirectory, NotificationFacts, PeopleNotice, PersonFacts, SnapshotBuilder,
};
use szfriends_core::store::sync_log::YOU;
use szfriends_core::store::{unix_now, Relation, Store, TransferState};

use super::views::ViewKind;
use super::State;
use crate::notify::prefs::{Prefs, Target};
use crate::notify::{Notifier, Open, Permission, Reply, Request, Response};

/// Messages committed within this many seconds in one conversation post once, for the newest.
pub const BURST_SECONDS: f64 = 1.0;
/// A friend's item that came by sync from another of the person's devices notifies only while this fresh.
pub const SYNC_FRESH_SECONDS: f64 = 600.0;
/// Requests kept for clicks and replies.
const POSTED_KEPT: usize = 256;
/// The thread computers asking to join share.
const JOIN_THREAD: &str = "join";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum BurstKind {
    Messages,
    Offers,
    Received,
}

#[derive(Debug)]
struct Entry {
    /// The item's id (messages) or the transfer's (files).
    id: String,
    /// The message's text or the file's name.
    text: String,
    sent_at: f64,
}

#[derive(Debug)]
struct Burst {
    conversation: String,
    kind: BurstKind,
    first_at: f64,
    entries: Vec<Entry>,
}

/// What the service keeps for notifications between inputs.
pub struct NotifyArea {
    pub notifier: Option<Arc<dyn Notifier>>,
    pub prefs: Prefs,
    pub target: Target,
    /// A test home: the sink posts, and `test_notification_response` is taken.
    pub test_home: bool,
    /// The conversation each connection's focused window shows.
    focus: HashMap<u64, String>,
    last_seq: i64,
    relations: HashMap<String, Relation>,
    join_ids: HashSet<String>,
    /// Files accepted automatically, notified once they arrive: transfer id to (conversation, sent at).
    awaiting: HashMap<String, (String, f64)>,
    bursts: Vec<Burst>,
    posted: VecDeque<Request>,
    /// Threads with delivered notifications, and whether their conversation was seen unread since.
    delivered: HashMap<String, bool>,
    requests: u64,
}

impl std::fmt::Debug for NotifyArea {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NotifyArea").field("prefs", &self.prefs).field("target", &self.target).finish()
    }
}

impl NotifyArea {
    /// Everything already in the store counts as seen.
    pub fn new(store: &Store, test_home: bool, notifier: Option<Arc<dyn Notifier>>) -> Self {
        let conn = store.connection();
        let last_seq = conn.query_row("SELECT coalesce(max(seq), 0) FROM messages", [], |r| r.get(0)).unwrap_or(0);
        Self {
            notifier,
            prefs: Prefs::load(store.state_dir()),
            target: Target::load(store.state_dir()),
            test_home,
            focus: HashMap::new(),
            last_seq,
            relations: relations(store),
            join_ids: HashSet::new(),
            awaiting: HashMap::new(),
            bursts: Vec::new(),
            posted: VecDeque::new(),
            delivered: HashMap::new(),
            requests: 0,
        }
    }

    pub fn permission(&self) -> Permission {
        self.notifier.as_ref().map_or(Permission::NotNeeded, |n| n.permission())
    }

    /// Whether anything may be posted now: a notifier, Notifications on, and the system allowing it.
    fn may_post(&self) -> bool {
        self.notifier.is_some() && self.prefs.enabled && self.permission().allows_posting()
    }

    pub fn disconnected(&mut self, connection: u64) {
        self.focus.remove(&connection);
    }

    fn post(&mut self, request: Request) {
        let Some(notifier) = &self.notifier else { return };
        notifier.post(&request);
        self.delivered.insert(request.thread.clone(), false);
        self.posted.push_back(request);
        while self.posted.len() > POSTED_KEPT {
            self.posted.pop_front();
        }
    }

    fn withdraw(&mut self, thread: &str) {
        if self.delivered.remove(thread).is_some() {
            if let Some(notifier) = &self.notifier {
                notifier.withdraw(thread);
            }
        }
    }

    fn find(&self, key: &str) -> Option<Request> {
        self.posted.iter().rev().find(|r| r.key == key).cloned()
    }
}

fn relations(store: &Store) -> HashMap<String, Relation> {
    store
        .people_by_latest_interaction()
        .unwrap_or_default()
        .into_iter()
        .map(|p| (p.conversation_id, p.relation))
        .collect()
}

/// One new row of `messages`, as the pass reads it.
struct NewItem {
    conversation: String,
    item_id: String,
    kind: i64,
    incoming: bool,
    body: Option<String>,
    event_kind: Option<String>,
    sent_at: f64,
    received_at: f64,
    by_sync: bool,
    transfer: Option<Transfer>,
}

struct Transfer {
    id: String,
    state: i64,
    automatic: bool,
    name: String,
}

impl State {
    /// After every input: what the store gained is decided now, and bursts whose second is up are posted.
    pub(crate) fn notify_pass(&mut self, dirty: bool) {
        let now = unix_now();
        let (items, links) = self.notify_scan_items(now);
        self.notify_check_awaiting(now);
        if dirty || items {
            self.notify_scan_people(now, &links);
            self.notify_scan_joins(now);
            self.notify_withdraw_read();
        }
        self.notify_flush(now, false);
    }

    fn own_device_key(&self) -> [u8; 32] {
        self.devices.engine.device_key()
    }

    /// When this device joined the profile: history from before it was copied, never news.
    fn joined_at(&self) -> f64 {
        self.store
            .connection()
            .query_row(
                "SELECT added_at FROM chain_devices WHERE device_pk = ?1",
                [self.own_device_key().to_vec()],
                |r| r.get::<_, f64>(0),
            )
            .optional()
            .ok()
            .flatten()
            .unwrap_or(0.0)
    }

    /// A conversation a focused window shows: one a client named with `set_focus`, or one an older client (without
    /// `notifications.focus`) holds open.
    pub(crate) fn notify_focused(&self, conversation: &str) -> bool {
        if self.notify.focus.values().any(|c| c == conversation) {
            return true;
        }
        self.clients.values().any(|client| {
            !client.audience.has("notifications.focus")
                && client
                    .subscriptions
                    .values()
                    .any(|s| s.view == ViewKind::Conversation && s.conversation_id.as_deref() == Some(conversation))
        })
    }

    /// The never-rules every friend's item passes: who sent it, where it came from, whether the person looks at it.
    fn notify_admits(&self, conversation: &str, now: f64, synced: Option<(f64, f64, &str)>) -> bool {
        if conversation == YOU || !self.notify.may_post() || self.notify_focused(conversation) {
            return false;
        }
        let friend = self.store.person_with_conversation(conversation).ok().flatten();
        if !friend.is_some_and(|p| p.relation == Relation::Friend) {
            return false;
        }
        if let Some((sent_at, received_at, item_id)) = synced {
            let read =
                szfriends_core::sync::read_marker_covers(self.store.connection(), conversation, received_at, item_id);
            if read || now - sent_at > SYNC_FRESH_SECONDS || sent_at < self.joined_at() {
                return false;
            }
        }
        true
    }

    /// New rows of `messages`; whether there were any, and the friend links they record by conversation.
    fn notify_scan_items(&mut self, now: f64) -> (bool, HashMap<String, PeopleNotice>) {
        let me = self.own_device_key().to_vec();
        let rows: Vec<(i64, NewItem)> = {
            let conn = self.store.connection();
            let Ok(mut statement) = conn.prepare(
                "SELECT m.seq, m.conversation_id, m.item_id, m.kind, m.direction, m.body, m.event_kind, m.sent_at, \
                 m.received_at, EXISTS (SELECT 1 FROM sync_origins o WHERE o.conversation_id = m.conversation_id \
                 AND o.item_id = m.item_id AND o.author <> ?2), t.state, t.accepted_automatically, t.file_name, \
                 m.transfer_id \
                 FROM messages m LEFT JOIN transfers t ON t.transfer_id = m.transfer_id AND m.kind = 1 \
                 WHERE m.seq > ?1 ORDER BY m.seq LIMIT 500",
            ) else {
                return (false, HashMap::new());
            };
            let mapped = statement.query_map(rusqlite::params![self.notify.last_seq, me], |r| {
                let state: Option<i64> = r.get(10)?;
                let transfer = match state {
                    Some(state) => {
                        Some(Transfer { state, automatic: r.get::<_, i64>(11)? != 0, name: r.get(12)?, id: r.get(13)? })
                    }
                    None => None,
                };
                Ok((
                    r.get::<_, i64>(0)?,
                    NewItem {
                        conversation: r.get(1)?,
                        item_id: r.get(2)?,
                        kind: r.get(3)?,
                        incoming: r.get::<_, i64>(4)? == 0,
                        body: r.get(5)?,
                        event_kind: r.get(6)?,
                        sent_at: r.get(7)?,
                        received_at: r.get(8)?,
                        by_sync: r.get(9)?,
                        transfer,
                    },
                ))
            });
            match mapped {
                Ok(rows) => rows.filter_map(Result::ok).collect(),
                Err(_) => Vec::new(),
            }
        };
        let mut links = HashMap::new();
        let any = !rows.is_empty();
        for (seq, item) in rows {
            self.notify.last_seq = self.notify.last_seq.max(seq);
            use szfriends_core::presentation::facts::event;
            if item.kind == 2 && !item.by_sync {
                match item.event_kind.as_deref() {
                    Some(event::ADDED_THROUGH_OUR_LINK) => _ = links.insert(item.conversation, PeopleNotice::LinkUsed),
                    Some(event::ADDED_THROUGH_THEIR_LINK) => {
                        _ = links.insert(item.conversation, PeopleNotice::LinkAdded)
                    }
                    _ => {}
                }
                continue;
            }
            if !item.incoming {
                continue; // the person's own, from here or another of their devices
            }
            let synced = item.by_sync.then_some((item.sent_at, item.received_at, item.item_id.as_str()));
            match (item.kind, &item.transfer) {
                (0, _) if self.notify_admits(&item.conversation, now, synced) => {
                    let text = item.body.clone().unwrap_or_default();
                    let entry = Entry { id: item.item_id.clone(), text, sent_at: item.sent_at };
                    self.notify_add(&item.conversation, BurstKind::Messages, entry, now);
                }
                (1, Some(transfer)) => {
                    if transfer.state == TransferState::WaitingForYou as i64 {
                        if self.notify_admits(&item.conversation, now, synced) {
                            let entry =
                                Entry { id: transfer.id.clone(), text: transfer.name.clone(), sent_at: item.sent_at };
                            self.notify_add(&item.conversation, BurstKind::Offers, entry, now);
                        }
                    } else if transfer.automatic && !item.by_sync {
                        // Accepted by itself: news once it is here, not before.
                        self.notify.awaiting.insert(transfer.id.clone(), (item.conversation.clone(), item.sent_at));
                        self.notify_check_awaiting(now);
                    }
                }
                _ => {}
            }
        }
        (any, links)
    }

    /// Files accepted automatically that finished arriving since the last pass.
    fn notify_check_awaiting(&mut self, now: f64) {
        if self.notify.awaiting.is_empty() {
            return;
        }
        let waiting: Vec<(String, String, f64)> =
            self.notify.awaiting.iter().map(|(t, (c, at))| (t.clone(), c.clone(), *at)).collect();
        for (transfer, conversation, sent_at) in waiting {
            let row: Option<(i64, String)> = self
                .store
                .connection()
                .query_row("SELECT state, file_name FROM transfers WHERE transfer_id = ?1", [&transfer], |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })
                .optional()
                .ok()
                .flatten();
            match row {
                Some((state, name)) if state == TransferState::Received as i64 => {
                    self.notify.awaiting.remove(&transfer);
                    if self.notify_admits(&conversation, now, None) {
                        let entry = Entry { id: transfer, text: name, sent_at };
                        self.notify_add(&conversation, BurstKind::Received, entry, now);
                    }
                }
                Some((state, _))
                    if state == TransferState::Receiving as i64 || state == TransferState::WaitingForYou as i64 => {}
                _ => _ = self.notify.awaiting.remove(&transfer),
            }
        }
    }

    fn notify_add(&mut self, conversation: &str, kind: BurstKind, entry: Entry, now: f64) {
        let bursts = &mut self.notify.bursts;
        match bursts.iter_mut().find(|b| b.conversation == conversation && b.kind == kind) {
            Some(burst) => burst.entries.push(entry),
            None => {
                bursts.push(Burst { conversation: conversation.to_owned(), kind, first_at: now, entries: vec![entry] })
            }
        }
    }

    /// Posts the bursts whose second is up (all of them with `all`).
    pub(crate) fn notify_flush(&mut self, now: f64, all: bool) {
        if !self.notify.bursts.iter().any(|b| all || now - b.first_at >= BURST_SECONDS) {
            return;
        }
        let (due, kept): (Vec<Burst>, Vec<Burst>) =
            std::mem::take(&mut self.notify.bursts).into_iter().partition(|b| all || now - b.first_at >= BURST_SECONDS);
        self.notify.bursts = kept;
        let builder = self.notification_builder();
        for burst in due {
            // Read meanwhile, or opened in a window: nothing to say any more.
            if self.notify_focused(&burst.conversation) || !self.notify.may_post() {
                continue;
            }
            let Some(person) = self.store.person_with_conversation(&burst.conversation).ok().flatten() else {
                continue;
            };
            let facts = self.person_facts(&person);
            if let Some(request) = self.burst_request(&builder, &facts, &burst) {
                self.notify.post(request);
            }
        }
    }

    fn burst_request(&self, builder: &SnapshotBuilder, person: &PersonFacts, burst: &Burst) -> Option<Request> {
        let newest = burst.entries.last()?;
        let preview = self.notify.prefs.preview;
        let conversation = burst.conversation.clone();
        let (key, kind, channel, words, reply) = match burst.kind {
            BurstKind::Messages => {
                let texts: Vec<&str> = burst.entries.iter().map(|e| e.text.as_str()).collect();
                let reply = builder.notify_reply(person);
                (
                    format!("message:{}", newest.id),
                    "message",
                    "messages",
                    builder.notify_messages(person, &texts, preview),
                    Some(Reply { label: reply.label, placeholder: reply.placeholder, send: reply.send }),
                )
            }
            BurstKind::Offers | BurstKind::Received => {
                let names: Vec<&str> = burst.entries.iter().map(|e| e.text.as_str()).collect();
                let received = burst.kind == BurstKind::Received;
                (
                    format!("file:{}", burst.entries[0].id),
                    "file",
                    "files",
                    builder.notify_files(person, &names, received, preview),
                    None,
                )
            }
        };
        Some(Request {
            key,
            kind,
            channel,
            conversation_id: Some(conversation.clone()),
            thread: conversation.clone(),
            title: words.title,
            body: words.body,
            time: szfriends_core::presentation::time::rfc3339(newest.sent_at),
            reply,
            open: self.notify_open(Some(&conversation)),
        })
    }

    fn notify_open(&self, conversation: Option<&str>) -> Open {
        let target = &self.notify.target;
        Open { url: target.url(conversation), app_id: target.app_id.clone(), app_path: target.app_path.clone() }
    }

    /// The words notifications are built from: this helper's catalog, mentions shown as the list shows them.
    fn notification_builder(&mut self) -> SnapshotBuilder {
        let audience = Audience {
            app_name: self.notify.target.app_name.clone(),
            capabilities: ["mentions".to_owned()].into_iter().collect(),
            helper_capabilities: self.capabilities.iter().cloned().collect(),
            time_zone: super::local_time_zone(),
            ..Audience::default()
        };
        let mut builder = SnapshotBuilder::new(audience, None);
        let (people, profile) = (self.people_facts(), self.profile_facts());
        builder.mention_directory = Some(MentionDirectory::new(&people, &profile));
        builder
    }

    /// Requests and acceptances: people whose relation changed since the last pass.
    fn notify_scan_people(&mut self, now: f64, links: &HashMap<String, PeopleNotice>) {
        let people = self.store.people_by_latest_interaction().unwrap_or_default();
        let before = std::mem::take(&mut self.notify.relations);
        self.notify.relations = people.iter().map(|p| (p.conversation_id.clone(), p.relation)).collect();
        let mut notices = Vec::new();
        for person in &people {
            let was = before.get(&person.conversation_id).copied();
            if was == Some(person.relation) {
                continue;
            }
            let notice = match (was, person.relation) {
                (_, Relation::Friend) if links.contains_key(&person.conversation_id) => links[&person.conversation_id],
                (Some(Relation::OutgoingRequest), Relation::Friend) => PeopleNotice::Accepted,
                (_, Relation::IncomingRequest) => {
                    // A request this device heard of late (from another of the person's devices) is old news.
                    let since = person.request_since.or(person.request_at).unwrap_or(now);
                    if now - since > SYNC_FRESH_SECONDS {
                        continue;
                    }
                    PeopleNotice::Request
                }
                _ => continue,
            };
            notices.push((person.clone(), notice));
        }
        if notices.is_empty() {
            return;
        }
        let builder = self.notification_builder();
        for (person, notice) in notices {
            let conversation = person.conversation_id.clone();
            if conversation == YOU || !self.notify.may_post() || self.notify_focused(&conversation) {
                continue;
            }
            let facts = self.person_facts(&person);
            let words = builder.notify_people(&facts, notice);
            let (key, kind) = match notice {
                PeopleNotice::LinkUsed | PeopleNotice::LinkAdded => (format!("link:{conversation}"), "link"),
                PeopleNotice::Request | PeopleNotice::Accepted => {
                    self.notify.requests += 1;
                    (format!("request:{conversation}:{}", self.notify.requests), "request")
                }
            };
            let request = Request {
                key,
                kind,
                channel: "requests",
                conversation_id: Some(conversation.clone()),
                thread: conversation.clone(),
                title: words.title,
                body: words.body,
                time: szfriends_core::presentation::time::rfc3339(now),
                reply: None,
                open: self.notify_open(Some(&conversation)),
            };
            self.notify.post(request);
        }
    }

    /// Computers and phones that asked to join since the last pass.
    fn notify_scan_joins(&mut self, now: f64) {
        let requests = self.join_request_facts(now);
        let ids: HashSet<String> = requests.iter().map(|r| r.join_id.clone()).collect();
        let new: Vec<_> = requests.into_iter().filter(|r| !self.notify.join_ids.contains(&r.join_id)).collect();
        self.notify.join_ids = ids;
        if self.notify.join_ids.is_empty() {
            self.notify.withdraw(JOIN_THREAD);
        }
        if new.is_empty() || !self.notify.may_post() {
            return;
        }
        let builder = self.notification_builder();
        for join in new {
            let words = builder.notify_join(&join.device_name);
            let request = Request {
                key: format!("join:{}", join.join_id),
                kind: "join",
                channel: "requests",
                conversation_id: None,
                thread: JOIN_THREAD.to_owned(),
                title: words.title,
                body: words.body,
                time: szfriends_core::presentation::time::rfc3339(join.received_at),
                reply: None,
                open: self.notify_open(None),
            };
            self.notify.post(request);
        }
    }

    /// A conversation read here or on another device: its notifications are withdrawn.
    fn notify_withdraw_read(&mut self) {
        let threads: Vec<(String, bool)> = self
            .notify
            .delivered
            .iter()
            .filter(|(t, _)| t.as_str() != JOIN_THREAD)
            .map(|(t, s)| (t.clone(), *s))
            .collect();
        for (thread, seen_unread) in threads {
            let unread: i64 = self
                .store
                .connection()
                .query_row("SELECT unread_count FROM friends WHERE conversation_id = ?1", [&thread], |r| r.get(0))
                .unwrap_or(0);
            if unread > 0 {
                self.notify.delivered.insert(thread, true);
            } else if seen_unread {
                self.notify.withdraw(&thread);
            }
        }
    }

    /// The person opened a conversation: its notifications go.
    pub(crate) fn notify_read(&mut self, conversation: &str) {
        self.notify.withdraw(conversation);
    }

    /// The app a click opens: the last client that used Friends, when it says its URL scheme.
    pub(crate) fn notify_remember(&mut self, client: u64) {
        let Some(connection) = self.clients.get(&client).map(|c| c.connection.clone()) else { return };
        let Some(info) = connection.client() else { return };
        let Some(scheme) = info.url_scheme else { return };
        let target = Target {
            url_scheme: scheme,
            app_id: info.app_id,
            app_name: info.app_name,
            app_path: connection.peer().executable.as_ref().map(|p| p.to_string_lossy().into_owned()),
        };
        if target != self.notify.target {
            target.save(self.store.state_dir());
            self.notify.target = target;
        }
    }

    pub(crate) fn notify_set_focus(&mut self, client: u64, conversation: Option<String>) {
        match conversation {
            Some(conversation) => {
                self.notify.focus.insert(client, conversation.clone());
                self.notify_remember(client);
                // Looking at it now: what is on screen needs no banner.
                self.notify.bursts.retain(|b| b.conversation != conversation);
            }
            None => _ = self.notify.focus.remove(&client),
        }
    }

    pub(crate) fn notify_set_prefs(&mut self, enabled: Option<bool>, preview: Option<bool>, background: Option<bool>) {
        let prefs = &mut self.notify.prefs;
        prefs.enabled = enabled.unwrap_or(prefs.enabled);
        prefs.preview = preview.unwrap_or(prefs.preview);
        prefs.background = background.unwrap_or(prefs.background);
        prefs.save(self.store.state_dir());
        if !self.notify.prefs.enabled {
            self.notify.bursts.clear();
        }
        self.changed();
    }

    pub(crate) fn notify_dismiss_ask(&mut self) {
        self.notify.prefs.ask_dismissed = true;
        self.notify.prefs.save(self.store.state_dir());
        self.changed();
    }

    pub(crate) fn notify_ask(&mut self) {
        if let Some(notifier) = &self.notify.notifier {
            notifier.ask();
        }
        self.changed();
    }

    /// This device's notifications for Settings and the ask card.
    pub(crate) fn notification_facts(&self) -> NotificationFacts {
        let prefs = self.notify.prefs;
        NotificationFacts {
            enabled: prefs.enabled,
            preview: prefs.preview,
            background: prefs.background,
            permission: self.notify.permission().into(),
            ios: cfg!(target_os = "ios"),
            ask_dismissed: prefs.ask_dismissed,
            activated: self.store.nearby_permissions_requested(),
        }
    }

    /// A phone's host (or a test) puts its own notifier in place.
    pub(crate) fn install_notifier(&mut self, notifier: Arc<dyn Notifier>) {
        self.notify.notifier = Some(notifier);
        self.changed();
    }

    /// A click or a reply on a notification posted here. Open: the platform's own routing does the rest (Linux and
    /// the sink open the URL through the notifier). Reply: sent in that conversation as `send_message` would, and the
    /// conversation is read.
    pub(crate) fn notification_response(&mut self, response: Response) -> Result<Value, &'static str> {
        let request = self.notify.find(response.key()).ok_or("not_found")?;
        match response {
            Response::Open { .. } => {
                if let Some(notifier) = &self.notify.notifier {
                    notifier.open(&request.open);
                }
                Ok(json!({}))
            }
            Response::Reply { text, .. } => {
                let conversation = request.conversation_id.filter(|_| request.reply.is_some()).ok_or("not_allowed")?;
                let mut token = [0u8; 16];
                szfriends_crypto::random_bytes(&mut token);
                let token: String = token.iter().map(|b| format!("{b:02x}")).collect();
                let sent = self.send_text(&conversation, text, token).map_err(|e| e.code)?;
                let _ = self
                    .store
                    .connection()
                    .execute("UPDATE friends SET unread_count = 0 WHERE conversation_id = ?1", [&conversation]);
                self.notify_read(&conversation);
                self.changed();
                Ok(sent)
            }
        }
    }
}

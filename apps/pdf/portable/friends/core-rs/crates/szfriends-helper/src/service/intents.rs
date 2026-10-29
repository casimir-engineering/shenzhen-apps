//! What each intent does (`SZFriendsIntentRouter*.m`). The fields are read and checked by `szfriends-core`'s
//! intents in the helper's order; this answers them from the store, the outbox and the sessions, with one reply per
//! intent and the snapshots reflecting it sent first.

use std::collections::BTreeSet;
use std::path::Path;

use serde_json::{json, Value};
use szfriends_core::intents::{admit, error_message, parse, Admission, Intent, IntentError, IntentState};
use szfriends_core::presentation::Strings;
use szfriends_core::store::{
    new_identifier, unix_now, Direction, Item, ItemKind, OutboxEntry, OutboxKind, OutboxState, Relation,
};
use szfriends_identity::friends_id::WordList;

use super::again::worded;
use super::views::{Subscription, ViewKind};
use super::State;
use crate::server::{Connection, Reply};

/// Intents whose areas have not come over yet: refused as unavailable rather than pretended. Links come with online
/// (the helper announces `links` only then); without it they stay here.
const NOT_YET: &[&str] = &[
    #[cfg(not(feature = "online"))]
    "receive_link",
    #[cfg(not(feature = "online"))]
    "make_download_link",
    #[cfg(not(feature = "online"))]
    "revoke_link",
    "search_messages",
    "set_picture",
    "accept_key_change",
    "retry_item",
    "dismiss_banner",
];

struct Context<'a> {
    state: &'a State,
    client: u64,
    capabilities: BTreeSet<String>,
}

impl IntentState for Context<'_> {
    fn relation(&self, conversation_id: &str) -> Option<Relation> {
        self.state.store.person_with_conversation(conversation_id).ok().flatten().map(|p| p.relation)
    }

    fn mention_target(&self, conversation_id: &str) -> Option<(Option<String>, String, [u8; 32])> {
        let person = self.state.store.person_with_conversation(conversation_id).ok().flatten()?;
        Some((person.name, person.friends_id?, person.identity_key?))
    }

    fn subscription_view(&self, subscription: &str) -> Option<String> {
        let client = self.state.clients.get(&self.client)?;
        client.subscriptions.get(subscription).map(|s| s.view.name().to_owned())
    }

    fn word_list(&self) -> Option<&WordList> {
        WordList::bundled()
    }

    fn client_capabilities(&self) -> &BTreeSet<String> {
        &self.capabilities
    }

    fn sent_before(&self, client_token: &str) -> bool {
        !self.state.store.outbox_entries_with_client_token(client_token).unwrap_or_default().is_empty()
    }
}

type Answer = Result<Value, IntentError>;

fn refused(code: &'static str) -> Answer {
    Err(IntentError::new(code))
}

impl State {
    /// A devices intent's outcome as a reply; the views are brought up to date either way.
    fn device_intent(&mut self, act: impl FnOnce(&mut Self) -> Result<(), &'static str>) -> Answer {
        let outcome = act(self);
        self.pump_sync();
        // An approval answers a code through the host from now on; a new code or request goes out at once.
        #[cfg(feature = "online")]
        self.offer_join_online();
        self.changed();
        outcome.map(|()| json!({})).map_err(IntentError::new)
    }

    pub fn intent(&mut self, connection: &Connection, frame: &Value, reply: Reply) {
        let client = connection.id();
        let Some(audience) = self.clients.get(&client).map(|c| c.audience.clone()) else {
            return reply.error("not_ready", None, json!({}));
        };
        let kind = frame["type"].as_str().unwrap_or_default().to_owned();
        let gate = Admission {
            has_store: true,
            has_identity: true,
            devices: true,
            links: self.capabilities.iter().any(|c| c == "links"),
            removed_computer: self.removed_computer(),
            received_folder: self.capabilities.iter().any(|c| c == "received.folder"),
            files_again: self.capabilities.iter().any(|c| c == "files.again"),
            notifications: self.capabilities.iter().any(|c| c == "notifications"),
            test_home: self.notify.test_home,
            ..Admission::default()
        };
        let parsed = admit(&kind, gate).and_then(|()| {
            let context = Context { state: self, client, capabilities: audience.capabilities.clone() };
            parse(frame, &context)
        });
        let answer = match parsed {
            Ok(Intent::DismissNotificationsBanner) => {
                self.notify_dismiss_ask();
                Ok(json!({}))
            }
            Ok(_) if NOT_YET.contains(&kind.as_str()) => refused("unavailable"),
            #[cfg(feature = "online")]
            Ok(Intent::MakeDownloadLink { file, expires_days }) => {
                // Answered once the file has been read, off this thread.
                return self.make_download_link(file, expires_days, audience, reply);
            }
            #[cfg(feature = "online")]
            Ok(Intent::RevokeLink { link_id }) => self.revoke_link(&link_id),
            #[cfg(feature = "online")]
            Ok(Intent::ReceiveLink {
                link: szfriends_core::intents::LinkPayload::Download { link_id, secret },
                ..
            }) => {
                // Answered once the sender's metadata arrived, or with why not.
                return self.receive_link(link_id, secret, audience, reply);
            }
            Ok(Intent::OpenLink { payload, link }) => self.open_link(&payload, &link, audience.clone()),
            Ok(Intent::AddFromLink { link, .. }) => self.add_from_link(&link, audience.clone()),
            Ok(Intent::AddFromMention { friends_id, identity_key, name }) => {
                self.add_from_mention(&friends_id, identity_key, &name, &Strings::new(audience.clone()), None)
            }
            Ok(intent) => self.act(client, intent),
            Err(error) => Err(error),
        };
        match answer {
            Ok(result) => reply.ok(result),
            Err(error) => {
                let message = error_message(&error, &Strings::new(audience));
                reply.error(error.code, message.as_deref(), Value::Object(error.details))
            }
        }
    }

    fn act(&mut self, client: u64, intent: Intent) -> Answer {
        match intent {
            Intent::Ping | Intent::Disable => Ok(json!({})),
            Intent::ApproveJoin { join_id } => self.device_intent(|s| s.approve_join(&join_id)),
            Intent::DenyJoin { join_id } => self.device_intent(|s| s.deny_join(&join_id)),
            Intent::JoinProfile { friends_id } => self.device_intent(|s| s.start_joining(&friends_id)),
            Intent::EnterJoinCode { code } => self.device_intent(|s| s.enter_join_code(&code)),
            Intent::CancelJoin => self.device_intent(|s| {
                s.cancel_joining();
                Ok(())
            }),
            Intent::RevokeDevice { device_id } => self.device_intent(|s| s.revoke_device(&device_id)),
            Intent::RenameDevice { name } => self.device_intent(|s| s.rename_device(&name)),
            Intent::FetchFromDevice { transfer_id } => {
                self.device_intent(|s| s.fetch_from_device(&transfer_id)).map_err(|e| worded(e, "fetch"))
            }
            Intent::FetchFromFriend { transfer_id } => {
                self.device_intent(|s| s.fetch_from_friend(&transfer_id)).map_err(|e| worded(e, "again"))
            }
            Intent::ResetFriendLink => self.reset_friend_link(),
            // A reset replaces the service, so whoever runs it answers before it gets here (`reset.rs`).
            Intent::ResetFriends => refused("unavailable"),
            Intent::DeleteHistory { conversation_id } => {
                self.delete_history(conversation_id.as_deref()).map_err(IntentError::new)?;
                Ok(json!({}))
            }
            Intent::Activate => {
                self.activate_nearby();
                self.notify_remember(client);
                self.changed();
                Ok(json!({}))
            }
            Intent::SetFocus { conversation_id } => {
                self.notify_set_focus(client, conversation_id);
                Ok(json!({}))
            }
            Intent::SetNotifications { enabled, preview, background } => {
                self.notify_set_prefs(enabled, preview, background);
                Ok(json!({}))
            }
            Intent::AllowNotifications => {
                self.notify_ask();
                Ok(json!({}))
            }
            Intent::TestNotificationResponse { key, reply_text } => {
                let response = match reply_text {
                    Some(text) => crate::notify::Response::Reply { key, text },
                    None => crate::notify::Response::Open { key },
                };
                self.notification_response(response).map_err(|code| match code {
                    "not_found" => IntentError::field("not_found", "key"),
                    code => IntentError::new(code),
                })
            }
            Intent::AcceptRequest { conversation_id } => self.accept_request(&conversation_id),
            Intent::DeclineRequest { conversation_id } => self.decline_request(&conversation_id),
            Intent::CancelRequest { conversation_id } => self.cancel_request(&conversation_id),
            Intent::SendRequest { nearby_id } => self.send_request(&nearby_id),
            Intent::AddById { friends_id } => {
                let audience = self.clients.get(&client).map(|c| c.audience.clone()).unwrap_or_default();
                self.add_by_id(&friends_id, &Strings::new(audience))
            }
            Intent::Block { conversation_id } => self.block(&conversation_id),
            Intent::Unblock { conversation_id } => self.unblock(&conversation_id),
            Intent::RemoveFriend { conversation_id, delete_history } => {
                self.remove_friend(&conversation_id, delete_history)
            }
            Intent::MarkVerified { conversation_id } => self.mark_verified(&conversation_id),
            Intent::StartVisibility => {
                let deadline = self.start_visibility();
                Ok(json!({"deadline": szfriends_core::presentation::time::rfc3339(deadline)}))
            }
            Intent::StopVisibility => {
                self.stop_visibility();
                Ok(json!({}))
            }
            Intent::Subscribe { view, conversation_id, .. } => {
                let name = format!("{view:?}").to_lowercase();
                let view = ViewKind::from_name(&name).ok_or(IntentError::new("unavailable"))?;
                if view == ViewKind::Received && !self.capabilities.iter().any(|c| c == "received.folder") {
                    return Err(IntentError::field("invalid_field", "view"));
                }
                if view == ViewKind::Details
                    && self
                        .store
                        .person_with_conversation(conversation_id.as_deref().unwrap_or_default())
                        .ok()
                        .flatten()
                        .is_none()
                {
                    return refused("not_found");
                }
                let id = self
                    .subscribe(client, Subscription::new(view, conversation_id))
                    .ok_or(IntentError::new("internal"))?;
                Ok(json!({"subscription": id}))
            }
            Intent::Unsubscribe { subscription } => {
                let removed = self.clients.get_mut(&client).and_then(|c| c.subscriptions.remove(&subscription));
                removed.map(|_| json!({})).ok_or(IntentError::field("not_found", "subscription"))
            }
            Intent::SetFilter { subscription, query } => {
                self.with_subscription(client, &subscription, |s| s.query = query)?;
                Ok(json!({}))
            }
            Intent::LoadEarlier { subscription } => {
                self.with_subscription(client, &subscription, |s| s.limit += super::facts::PAGE)?;
                Ok(json!({}))
            }
            Intent::OpenConversation { conversation_id, message_id } => {
                let _ = self
                    .store
                    .connection()
                    .execute("UPDATE friends SET unread_count = 0 WHERE conversation_id = ?1", [&conversation_id]);
                self.notify_read(&conversation_id);
                self.notify_remember(client);
                let mut subscription = Subscription::new(ViewKind::Conversation, Some(conversation_id.clone()));
                subscription.highlight = message_id;
                self.changed();
                let id = self.subscribe(client, subscription).ok_or(IntentError::new("internal"))?;
                Ok(json!({"subscription": id, "conversation_id": conversation_id}))
            }
            Intent::SendMessage { conversation_id, text, client_token, attachments, .. } => {
                self.friend(&conversation_id)?;
                // Files attached with nothing typed are only the files, as send_files sends them: an empty message
                // would reach the friend as an empty bubble above them. message_id is then "" (PROTOCOL.md § Files).
                let files_only = text.is_empty();
                let mut transfers = Vec::new();
                for (index, file) in attachments.iter().enumerate() {
                    let token = (files_only && index == 0).then(|| client_token.clone());
                    let path = Path::new(&file.path);
                    transfers.push(self.offer_file(&conversation_id, path, file.display_name.as_deref(), token)?);
                }
                if files_only {
                    self.after_send(&conversation_id);
                    return Ok(json!({"message_id": "", "transfer_ids": transfers}));
                }
                let mut sent = self.send_text(&conversation_id, text, client_token)?;
                sent["transfer_ids"] = json!(transfers);
                Ok(sent)
            }
            Intent::SendFiles { conversation_id, files, client_token, .. } => {
                self.friend(&conversation_id)?;
                let mut transfers = Vec::new();
                for (index, file) in files.iter().enumerate() {
                    // The token on the first offer: a retry of this press finds it (PROTOCOL.md § Intents).
                    let token = (index == 0).then(|| client_token.clone());
                    let path = Path::new(&file.path);
                    transfers.push(self.offer_file(&conversation_id, path, file.display_name.as_deref(), token)?);
                }
                self.after_send(&conversation_id);
                Ok(json!({"transfer_ids": transfers}))
            }
            Intent::Resend { client_token, message } => {
                let entries = self.store.outbox_entries_with_client_token(&client_token).unwrap_or_default();
                let ids = |kind: OutboxKind| -> Vec<String> {
                    entries.iter().filter(|e| e.kind == kind).filter_map(|e| e.item_id.clone()).collect()
                };
                Ok(if message {
                    // A message with files only has no message entry; its first offer carries the token.
                    let message_id = ids(OutboxKind::Message).into_iter().next().unwrap_or_default();
                    let transfers = if message_id.is_empty() { ids(OutboxKind::Offer) } else { Vec::new() };
                    json!({"message_id": message_id, "transfer_ids": transfers})
                } else {
                    json!({"transfer_ids": ids(OutboxKind::Offer)})
                })
            }
            Intent::AcceptOffer { transfer_id } => {
                if self.accept_offer(&transfer_id, false) {
                    Ok(json!({}))
                } else {
                    refused("stale")
                }
            }
            Intent::DeclineOffer { transfer_id } => {
                let record = self.store.decline_transfer(&transfer_id).map_err(|_| IntentError::new("stale"))?;
                self.queue_answer(
                    &record.conversation_id,
                    json!({"frame": "offer_reply", "transfer_id": transfer_id, "accept": false}),
                );
                self.changed();
                Ok(json!({}))
            }
            Intent::CancelTransfer { transfer_id } => {
                // Get again or Get on a file whose bytes are not here: the copy stops (again.rs, device_files.rs).
                if self.cancel_again(&transfer_id) || self.cancel_fetch_from_device(&transfer_id) {
                    return Ok(json!({}));
                }
                let record = self.store.cancel_transfer(&transfer_id).map_err(|_| IntentError::new("stale"))?;
                for session in self.sessions.map.values_mut() {
                    session.senders.remove(&transfer_id);
                    session.receivers.remove(&transfer_id);
                    session.block_senders.remove(&transfer_id);
                    session.block_receivers.remove(&transfer_id);
                }
                self.queue_answer(&record.conversation_id, json!({"frame": "cancel", "transfer_id": transfer_id}));
                self.changed();
                Ok(json!({}))
            }
            Intent::CancelMessage { message_id } => {
                let conversation =
                    self.conversation_of_item(&message_id).ok_or(IntentError::field("not_found", "message_id"))?;
                self.store.cancel_message(&message_id, &conversation).map_err(|_| IntentError::new("stale"))?;
                self.changed();
                Ok(json!({}))
            }
            Intent::SetName { name } => {
                if !self.set_own_name(name.as_deref().unwrap_or_default()) {
                    return refused("internal");
                }
                self.changed();
                Ok(json!({}))
            }
            Intent::SetAutoAccept { conversation_id, enabled } => {
                let mut person = self.friend(&conversation_id)?;
                person.auto_accept = enabled;
                self.store.save_person(&person).map_err(|_| IntentError::new("internal"))?;
                self.changed();
                Ok(json!({}))
            }
            Intent::SetReceivedFolder { path } => {
                use szfriends_core::intents::Wording;
                use szfriends_core::store::FolderRefusal;
                match self.store.set_received_folder(&path) {
                    Ok(()) => {}
                    Err(FolderRefusal::NotAbsolute) => return Err(IntentError::field("invalid_field", "path")),
                    Err(FolderRefusal::Missing) => {
                        let mut error = IntentError::new("file_missing").worded(Wording::ReceivedFolder);
                        error.details.insert("path".into(), json!(path));
                        return Err(error);
                    }
                    Err(FolderRefusal::NotAllowed) => {
                        return Err(IntentError::new("not_allowed").worded(Wording::ReceivedFolder))
                    }
                }
                self.changed();
                Ok(json!({}))
            }
            _ => refused("unavailable"),
        }
    }

    fn with_subscription(
        &mut self,
        client: u64,
        id: &str,
        change: impl FnOnce(&mut Subscription),
    ) -> Result<(), IntentError> {
        let subscription = self.clients.get_mut(&client).and_then(|c| c.subscriptions.get_mut(id));
        let subscription = subscription.ok_or(IntentError::field("not_found", "subscription"))?;
        change(subscription);
        self.changed();
        Ok(())
    }

    /// A friend messages and files may go to.
    fn friend(&self, conversation_id: &str) -> Result<szfriends_core::store::Person, IntentError> {
        match self.store.person_with_conversation(conversation_id).ok().flatten() {
            Some(person) if person.relation == Relation::Friend => Ok(person),
            Some(_) => Err(IntentError::new("not_friends")),
            None => Err(IntentError::field("not_found", "conversation_id")),
        }
    }

    /// Stages one file and queues its offer; the transfer id.
    fn offer_file(
        &mut self,
        conversation_id: &str,
        path: &Path,
        name: Option<&str>,
        token: Option<String>,
    ) -> Result<String, IntentError> {
        let record = self.store.stage_outgoing_file(path, name, conversation_id).map_err(|error| match error {
            szfriends_core::store::StoreError::FileMissing => IntentError::field("not_found", "path"),
            _ => IntentError::new("not_a_file"),
        })?;
        let entry = outbox_entry(conversation_id, OutboxKind::Offer, Some(record.transfer_id.clone()), token);
        self.store.enqueue(&entry, None).map_err(|_| IntentError::new("internal"))?;
        Ok(record.transfer_id)
    }

    /// A message to a friend, as send_message sends one (and a reply from a notification): queued, then delivered
    /// when a route is up.
    pub(crate) fn send_text(&mut self, conversation_id: &str, text: String, client_token: String) -> Answer {
        self.friend(conversation_id)?;
        let message_id = new_identifier();
        let now = unix_now();
        let item = Item {
            item_id: message_id.clone(),
            conversation_id: conversation_id.to_owned(),
            kind: ItemKind::Message,
            direction: Direction::Outgoing,
            text: Some(text),
            transfer_id: None,
            sent_at: now,
            received_at: now,
            via_assistant: false,
        };
        let entry = outbox_entry(conversation_id, OutboxKind::Message, Some(message_id.clone()), Some(client_token));
        self.store.enqueue(&entry, Some(&item)).map_err(|_| IntentError::new("internal"))?;
        self.after_send(conversation_id);
        Ok(json!({"message_id": message_id, "transfer_ids": []}))
    }

    fn after_send(&mut self, conversation_id: &str) {
        self.changed();
        self.deliver_to(conversation_id);
    }

    fn conversation_of_item(&self, item_id: &str) -> Option<String> {
        self.store
            .connection()
            .query_row("SELECT conversation_id FROM messages WHERE item_id = ?1", [item_id], |r| r.get(0))
            .ok()
    }
}

fn outbox_entry(
    conversation_id: &str,
    kind: OutboxKind,
    item_id: Option<String>,
    token: Option<String>,
) -> OutboxEntry {
    OutboxEntry {
        entry_id: new_identifier(),
        conversation_id: conversation_id.to_owned(),
        kind,
        state: OutboxState::Queued,
        created_at: unix_now(),
        queued_at: unix_now(),
        attempts: 0,
        item_id,
        client_token: token,
        failure_reason: None,
        payload: None,
    }
}

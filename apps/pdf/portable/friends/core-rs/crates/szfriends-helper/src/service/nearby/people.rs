//! The intents about people (`SZFriendsIntentRouter+People.m`): requests and their answers, Add by ID, block,
//! remove and verification. Each changes the store and queues what the other side must learn; a session delivers it
//! when a route exists. Removing or blocking someone tells them nothing: only our presence secret changes, so they
//! can no longer recognise us nearby.

use serde_json::{json, Value};
use szfriends_core::intents::IntentError;
use szfriends_core::presentation::Strings;
use szfriends_core::store::requests::event;
use szfriends_core::store::{
    new_identifier, unix_now, IdRequest, OutboxEntry, OutboxEvent, OutboxKind, OutboxState, Person, Relation,
    StoreError,
};

use crate::service::State;

type Answer = Result<Value, IntentError>;

fn store_error(error: StoreError) -> IntentError {
    IntentError::new(match error {
        StoreError::Constraint => "rate_limited",
        StoreError::NotFound => "not_found",
        StoreError::DiskFull => "disk_full",
        _ => "internal",
    })
}

impl State {
    /// An outbox entry with no history item (requests, answers, presence secrets).
    pub(crate) fn queue_entry(&mut self, conversation: &str, kind: OutboxKind, payload: Option<Value>) {
        let entry = OutboxEntry {
            entry_id: new_identifier(),
            conversation_id: conversation.to_owned(),
            kind,
            state: OutboxState::Queued,
            created_at: unix_now(),
            queued_at: unix_now(),
            attempts: 0,
            item_id: None,
            client_token: None,
            failure_reason: None,
            payload: payload.map(|p| p.to_string().into_bytes()),
        };
        if let Err(error) = self.store.enqueue(&entry, None) {
            crate::log!("could not queue an outbox entry: {error}");
        }
    }

    fn person_for(&self, conversation_id: &str) -> Result<Person, IntentError> {
        self.store
            .person_with_conversation(conversation_id)
            .ok()
            .flatten()
            .ok_or_else(|| IntentError::field("not_found", "conversation_id"))
    }

    fn save(&mut self, person: &Person) -> Result<(), IntentError> {
        self.store.save_person(person).map_err(store_error)
    }

    /// Remove and block: nothing still waiting for this person goes out any more.
    fn refuse_pending(&mut self, conversation: &str) {
        for entry in self.store.pending_outbox(conversation).unwrap_or_default() {
            let _ = self.store.apply_outbox_event(&entry.entry_id, OutboxEvent::Refused);
        }
    }

    /// A new presence secret after a remove or block, sent to every friend who remains.
    fn rotate_presence_secret_except(&mut self, conversation: &str) {
        let _ = self.store.set_own_presence_secret(&szfriends_core::nearby::callbacks::new_secret());
        for friend in self.store.people_with_relation(Relation::Friend) {
            if friend.identity_key.is_some() && friend.conversation_id != conversation {
                self.queue_presence_secret(&friend.conversation_id);
            }
        }
    }

    pub(crate) fn accept_request(&mut self, conversation_id: &str) -> Answer {
        let mut person = self.person_for(conversation_id)?;
        if person.relation != Relation::IncomingRequest {
            return Err(IntentError::new("stale"));
        }
        let _ = self.store.ensure_own_presence_secret();
        person.relation = Relation::Friend;
        person.last_interaction_at = unix_now();
        self.save(&person)?;
        let _ = self.store.record_event(conversation_id, event::NOW_FRIENDS);
        // The answer, then our presence secret, so the new friend can find us privately from now on.
        self.queue_entry(conversation_id, OutboxKind::Answer, Some(json!({"frame": "accept"})));
        self.queue_presence_secret(conversation_id);
        self.people_changed();
        Ok(json!({}))
    }

    pub(crate) fn decline_request(&mut self, conversation_id: &str) -> Answer {
        let mut person = self.person_for(conversation_id)?;
        if person.relation != Relation::IncomingRequest {
            return Err(IntentError::new("stale"));
        }
        // Removed, not blocked: the person can ask again later.
        person.relation = Relation::Removed;
        self.save(&person)?;
        self.queue_entry(conversation_id, OutboxKind::Answer, Some(json!({"frame": "decline"})));
        self.people_changed();
        Ok(json!({}))
    }

    pub(crate) fn cancel_request(&mut self, conversation_id: &str) -> Answer {
        let mut person = self.person_for(conversation_id)?;
        if person.relation != Relation::OutgoingRequest {
            return Err(IntentError::new("stale"));
        }
        person.relation = Relation::Removed;
        self.save(&person)?;
        let _ = self.store.delete_id_request(conversation_id);
        // A request still waiting must not go out after it was withdrawn; one already delivered is withdrawn.
        for entry in self.store.pending_outbox(conversation_id).unwrap_or_default() {
            if entry.kind == OutboxKind::Request {
                let _ = self.store.apply_outbox_event(&entry.entry_id, OutboxEvent::Refused);
            }
        }
        self.queue_entry(conversation_id, OutboxKind::Answer, Some(json!({"frame": "cancel"})));
        self.people_changed();
        Ok(json!({}))
    }

    /// send_request: only someone a browse identified; their key came from their own public entry's handshake.
    pub(crate) fn send_request(&mut self, nearby_id: &str) -> Answer {
        let stranger = self.stranger(nearby_id).ok_or_else(|| IntentError::field("not_found", "nearby_id"))?;
        let existing = self.store.person_with_identity_key(&stranger.identity_key).ok().flatten();
        match existing.as_ref().map(|p| p.relation) {
            Some(Relation::Friend) => return Err(IntentError::new("already_friends")),
            Some(Relation::Blocked) => return Err(IntentError::new("blocked")),
            Some(Relation::OutgoingRequest | Relation::IncomingRequest) => return Ok(json!({})),
            _ => {}
        }
        let now = unix_now();
        let mut person = existing.unwrap_or_else(|| Person::new(Relation::OutgoingRequest));
        person.identity_key = Some(stranger.identity_key);
        if person.static_key.is_none() {
            person.static_key = stranger.static_key;
        }
        person.name = stranger.name;
        person.friends_id = stranger.friends_id;
        person.relation = Relation::OutgoingRequest;
        person.request_at = Some(now);
        person.request_found_nearby = true;
        person.last_interaction_at = now;
        self.save(&person)?;
        // Delivered over XX to their public entry while they are visible; the outbox keeps it until then.
        self.queue_entry(&person.conversation_id, OutboxKind::Request, None);
        self.people_changed();
        Ok(json!({}))
    }

    pub(crate) fn add_by_id(&mut self, friends_id: &str, strings: &Strings) -> Answer {
        if friends_id == self.profile_facts().friends_id {
            return Err(IntentError::new("id_is_yours"));
        }
        // Online, the words no longer wait for being nearby.
        let message = strings.add_by_id_sent_message(friends_id, self.reaches_friends_online());
        let now = unix_now();
        let pending: Vec<String> = self.store.pending_id_requests(now).into_iter().map(|r| r.conversation_id).collect();
        // A row's Friends ID is whatever their PROFILE said: only a confirmed friend or blocked person, or our own
        // keyless request still out, stops a new request.
        for candidate in self.store.people_by_latest_interaction().unwrap_or_default() {
            if candidate.friends_id.as_deref() != Some(friends_id) {
                continue;
            }
            let confirmed = candidate.friends_id_confirmed;
            match candidate.relation {
                Relation::Friend if confirmed => return Err(IntentError::new("already_friends")),
                Relation::Blocked if confirmed => return Err(IntentError::new("blocked")),
                Relation::OutgoingRequest
                    if candidate.identity_key.is_none() && pending.contains(&candidate.conversation_id) =>
                {
                    return Ok(json!({"conversation_id": candidate.conversation_id, "message": message}));
                }
                _ => {}
            }
        }
        let mut request = IdRequest::new(friends_id, now);
        let conversation = self.store.start_id_request(&mut request).map_err(store_error)?;
        self.queue_entry(&conversation, OutboxKind::Request, None);
        // Its callback tags go on the air and the NN request goes to every device nearby, and to the ID's holder
        // through the Friends host.
        self.people_changed();
        #[cfg(feature = "online")]
        self.request_by_id_online(&request.request_token);
        Ok(json!({"conversation_id": conversation, "message": message}))
    }

    pub(crate) fn block(&mut self, conversation_id: &str) -> Answer {
        let mut person = self.person_for(conversation_id)?;
        if person.relation == Relation::Blocked {
            return Ok(json!({}));
        }
        let was_friend = person.relation == Relation::Friend;
        person.relation = Relation::Blocked;
        person.auto_accept = false;
        self.save(&person)?;
        let _ = self.store.delete_id_request(conversation_id);
        self.refuse_pending(conversation_id);
        let _ = self.store.record_event(conversation_id, event::BLOCKED);
        if was_friend {
            self.rotate_presence_secret_except(conversation_id);
        }
        self.people_changed();
        Ok(json!({}))
    }

    pub(crate) fn unblock(&mut self, conversation_id: &str) -> Answer {
        let mut person = self.person_for(conversation_id)?;
        if person.relation != Relation::Blocked {
            return Err(IntentError::new("stale"));
        }
        // Back to removed: friendship needs a new request from either side rather than resuming silently.
        person.relation = Relation::Removed;
        self.save(&person)?;
        let _ = self.store.record_event(conversation_id, event::UNBLOCKED);
        self.people_changed();
        Ok(json!({}))
    }

    pub(crate) fn remove_friend(&mut self, conversation_id: &str) -> Answer {
        let mut person = self.person_for(conversation_id)?;
        if person.relation != Relation::Friend {
            return Err(IntentError::new("not_friends"));
        }
        person.relation = Relation::Removed;
        person.auto_accept = false;
        self.save(&person)?;
        self.refuse_pending(conversation_id);
        let _ = self.store.record_event(conversation_id, event::REMOVED);
        self.rotate_presence_secret_except(conversation_id);
        self.people_changed();
        Ok(json!({}))
    }

    pub(crate) fn mark_verified(&mut self, conversation_id: &str) -> Answer {
        let person = self.person_for(conversation_id)?;
        if person.relation != Relation::Friend {
            return Err(IntentError::new("not_friends"));
        }
        let changed = self
            .store
            .connection()
            .execute(
                "UPDATE friends SET verified = 1, verified_at = ?1 WHERE conversation_id = ?2 AND verified = 0",
                rusqlite::params![unix_now(), conversation_id],
            )
            .unwrap_or(0);
        if changed > 0 {
            let _ = self.store.record_event(conversation_id, event::VERIFIED);
            self.changed();
        }
        Ok(json!({}))
    }
}

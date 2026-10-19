//! Mentions and friend links in the Rust helper (`SZFriendsIntentRouter+Mentions.m`, `+Links.m`,
//! `SZFriendsNearbyService+Mentions.m`, `+Invites.m`; PROTOCOL.md § Mentions, § Links): Add from a mention, the card
//! open_link answers with, Add from a friend link (a mention's request presenting the link's invite), Reset, and the
//! invite on both sides of Add by ID: the requester proves it holds the invite on its REQUEST_BY_ID (InviteProof,
//! bound to the session), and the holder accepts such a request at once while the invite is live, at most 20 a day
//! through the standing link.
//!
//! A mention's request is bound to the mentioned key with no store change: its token is a keyed hash of that key under
//! the request's own callback secret, so only that key's answer is admitted (`policy.rs`).

use serde_json::{json, Value};
use szfriends_core::intents::{friend_link_payload, IntentError, LinkPayload, Wording};
use szfriends_core::presentation::mentions::mention_name;
use szfriends_core::presentation::{Audience, SnapshotBuilder, Strings};
use szfriends_core::store::{unix_now, IdRequest, OutboxKind, Person, Relation, StoreError, ID_REQUEST_MAX_PENDING};
use szfriends_core::wire::{tag, Frame};

use super::State;

const MENTION_DOMAIN: &[u8] = b"SZFriends mention request v1";

type Answer = Result<Value, IntentError>;

/// The token of a request bound to `key` (`SZFriendsMentionRequestToken`): BLAKE2b-128 keyed with the request's
/// callback secret over the domain and the key.
pub fn mention_request_token(callback_secret: &[u8; 32], key: &[u8; 32]) -> [u8; 16] {
    szfriends_core::crypto::blake2b::<16>(Some(callback_secret), &[MENTION_DOMAIN, key])
}

impl State {
    /// Whether requests also travel through the Friends host now.
    pub(crate) fn reaches_friends_online(&self) -> bool {
        #[cfg(feature = "online")]
        return self.online.as_ref().is_some_and(|o| o.is_available());
        #[cfg(not(feature = "online"))]
        false
    }

    /// Whether this person's own data gives `friends_id` to another key than the mention's: their own ID, a friend's,
    /// or one confirmed for someone. Then Add would reach someone else.
    fn friends_id_belongs_to_other_key(&mut self, friends_id: &str, key: &[u8; 32]) -> bool {
        if friends_id == self.profile_facts().friends_id {
            return true;
        }
        self.store.people_by_latest_interaction().unwrap_or_default().iter().any(|person| {
            person.friends_id.as_deref() == Some(friends_id)
                && person.identity_key.is_some_and(|k| k != *key)
                && (person.relation == Relation::Friend || person.friends_id_confirmed)
        })
    }

    /// add_from_mention: Add by ID for exactly the mentioned key; with `invite`, the request presents a friend link's.
    pub(crate) fn add_from_mention(
        &mut self,
        friends_id: &str,
        key: [u8; 32],
        name: &str,
        strings: &Strings,
        invite: Option<[u8; 16]>,
    ) -> Answer {
        if key == self.identity.public_key() {
            return Err(IntentError::new("id_is_yours"));
        }
        let known = self.store.person_with_identity_key(&key).ok().flatten();
        let mut refusal = match known.as_ref().map(|p| p.relation) {
            Some(Relation::Friend) => Some("already_friends"),
            Some(Relation::Blocked) => Some("blocked"),
            Some(Relation::IncomingRequest) => Some("stale"), // the card offers Accept
            _ => None,
        };
        if refusal.is_none() && self.friends_id_belongs_to_other_key(friends_id, &key) {
            refusal = Some("mention_mismatch");
        }
        if let Some(code) = refusal {
            return Err(IntentError::new(code).worded(Wording::Named(name.to_owned())));
        }
        let message = strings.add_from_mention_sent_message(name, self.reaches_friends_online());
        let now = unix_now();
        let pending = self.store.pending_id_requests(now);
        if let Some(person) = known.as_ref().filter(|p| p.relation == Relation::OutgoingRequest) {
            // Asked already, and still waiting: the same request, as add_by_id answers.
            let waiting =
                person.request_found_nearby || pending.iter().any(|r| r.conversation_id == person.conversation_id);
            if waiting {
                if let Some(invite) = invite {
                    let _ = self.store.set_invite_token_for_id_request(&person.conversation_id, &invite);
                }
                return Ok(json!({"conversation_id": person.conversation_id, "message": message}));
            }
        }
        // At most four pending (ADR 0004); checked before the row exists, so a refusal leaves no "Request sent".
        if pending.len() >= ID_REQUEST_MAX_PENDING {
            return Err(IntentError::new("rate_limited"));
        }
        let mut person = known.unwrap_or_else(|| {
            let mut fresh = Person::new(Relation::OutgoingRequest);
            fresh.identity_key = Some(key);
            fresh.friends_id = Some(friends_id.to_owned());
            fresh.name = Some(name.to_owned()); // until their own profile says otherwise
            fresh
        });
        person.relation = Relation::OutgoingRequest;
        person.request_at = Some(now);
        person.request_found_nearby = false;
        person.last_interaction_at = now;
        // What an old friendship earned does not come back with a new request.
        person.comparison_code = None;
        person.auto_accept = false;
        let mut request = IdRequest::new(friends_id, now);
        request.request_token = mention_request_token(&request.callback_secret, &key);
        let conversation = self.store.start_keyed_id_request(&person, &mut request).map_err(|error| match error {
            StoreError::Constraint => IntentError::new("rate_limited"),
            _ => IntentError::new("internal"),
        })?;
        if let Some(invite) = invite {
            let _ = self.store.set_invite_token_for_id_request(&conversation, &invite);
        }
        self.queue_entry(&conversation, OutboxKind::Request, None);
        // Its callback tags go on the air and the NN request goes to every device nearby, and through the host.
        self.people_changed();
        #[cfg(feature = "online")]
        self.request_by_id_online(&request.request_token);
        Ok(json!({"conversation_id": conversation, "message": message}))
    }

    /// open_link: the card, before anything happens. Only what the link's own bytes say, and whether they are a
    /// friend here already.
    pub(crate) fn open_link(&mut self, payload: &str, link: &LinkPayload, audience: Audience) -> Answer {
        let builder = SnapshotBuilder::new(audience, None);
        let LinkPayload::Friend { identity_key, friends_id, name, .. } = link else {
            return Ok(json!({"card": builder.download_link_card(payload)}));
        };
        if *identity_key == self.identity.public_key() {
            return Err(IntentError::new("id_is_yours"));
        }
        let known = self.store.person_with_identity_key(identity_key).ok().flatten();
        let friend = known.is_some_and(|p| p.relation == Relation::Friend);
        Ok(json!({"card": builder.friend_link_card(Some(name), friends_id, payload, friend)}))
    }

    /// add_from_link: add_from_mention for the link's key and ID, presenting its invite, which the inviter's computer
    /// checks and then accepts at once.
    pub(crate) fn add_from_link(&mut self, link: &LinkPayload, audience: Audience) -> Answer {
        let LinkPayload::Friend { identity_key, invite_token, friends_id, name } = link else {
            return Err(IntentError::field("invalid_field", "payload"));
        };
        let list = szfriends_identity::friends_id::WordList::bundled();
        let friends_id = list.and_then(|l| l.normalized_id(friends_id));
        let friends_id = friends_id.ok_or_else(|| IntentError::field("id_invalid", "friends_id"))?;
        let name = mention_name(Some(name), Some(&friends_id));
        let strings = Strings::new(audience.clone());
        let sent = self.add_from_mention(&friends_id, *identity_key, &name, &strings, Some(*invite_token))?;
        let builder = SnapshotBuilder::new(audience, None);
        let message = builder.link_request_sent_message(&name, self.reaches_friends_online());
        Ok(json!({"conversation_id": sent["conversation_id"], "message": message}))
    }

    /// reset_friend_link: the old link stops working, and the profile shows the new one.
    pub(crate) fn reset_friend_link(&mut self) -> Answer {
        self.store.reset_standing_invite(unix_now()).map_err(|_| IntentError::new("internal"))?;
        self.changed();
        Ok(json!({}))
    }

    /// The friend link's page URL (`<origin>/f#<base64url>`), with the standing invite made on first use.
    #[cfg_attr(not(feature = "online"), allow(dead_code))]
    pub(crate) fn friend_link_url(&mut self, origin: &str, friends_id: &str, name: &str) -> Option<String> {
        let invite = self.store.standing_invite(true).ok().flatten()?;
        let payload = friend_link_payload(&self.identity.public_key(), &invite.token, friends_id, name)?;
        Some(format!("{origin}/f#{}", payload.strip_prefix("f.")?))
    }

    /// REQUEST_BY_ID for our request in `conversation_id`, with the invite it presents bound to this session.
    pub(crate) fn with_invite_proof(&self, frame: Frame, conversation_id: &str, h: &[u8]) -> Frame {
        let proof = self.store.invite_token_for_id_request(conversation_id);
        match proof.and_then(|invite| szfriends_core::crypto::invite::invite_proof(&invite, h)) {
            Some(proof) => frame.with(tag::INVITE_PROOF, proof.to_vec()),
            None => frame,
        }
    }

    /// The holder's side: the request proves a live invite of ours, which is then used (or counted, for the standing
    /// one, refused past its daily limit).
    pub(crate) fn request_uses_live_invite(&mut self, frame: &Frame, h: &[u8]) -> bool {
        let Some(proof) = frame.get(tag::INVITE_PROOF).filter(|p| p.len() == 32) else { return false };
        let now = unix_now();
        for invite in self.store.live_invites(now) {
            let expected = szfriends_core::crypto::invite::invite_proof(&invite.token, h);
            let same = expected.is_some_and(|e| e.iter().zip(proof).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0);
            if same {
                return self.store.use_invite(&invite.token, now).is_ok();
            }
        }
        false
    }

    /// Our request whose answer just arrived presented a friend link's invite.
    pub(crate) fn request_token_came_from_link(&self, token: &[u8]) -> bool {
        let request = self.store.id_request_with_token(token, unix_now());
        request.is_some_and(|r| self.store.invite_token_for_id_request(&r.conversation_id).is_some())
    }
}

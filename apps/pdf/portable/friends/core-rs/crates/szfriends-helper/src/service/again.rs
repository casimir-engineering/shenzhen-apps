//! Get again in the Rust helper (`nearby/SZFriendsNearbyService+Again.m`, ADR 0016, PROTOCOL.md § Getting a file
//! again): the friend's computer answers our WANTs with the file it sent us, and ours answers theirs; AGAIN rides a
//! friend's session whose negotiated minor is 3 or more, never one with our own devices. The exchange itself is the
//! core's (`szfriends_core::sync::again*`).

use std::collections::HashMap;

use szfriends_core::intents::{IntentError, Wording};
use szfriends_core::presentation::{AgainState, ItemFacts};
use szfriends_core::store::sync_log::YOU;
use szfriends_core::store::{sync_files, unix_now, Relation};
use szfriends_core::sync::holds_transfer;
use szfriends_core::sync::{again_state, set_again_state, AgainFile, AgainMessage, AgainRequester, AgainServer};
use szfriends_core::wire::{tag, Frame, FrameType, Pattern};

use super::State;

/// The session minor that brought AGAIN.
const AGAIN_MINOR: u16 = 3;

/// What this helper run keeps of Get again: the sender's limits and checks, and each friend session's copy.
#[derive(Debug, Default)]
pub struct AgainArea {
    pub server: AgainServer,
    pub requesters: HashMap<u64, AgainRequester>,
}

/// A devices intent's not_found in its own words ("fetch", "again").
pub(crate) fn worded(error: IntentError, reason: &'static str) -> IntentError {
    if error.code == "not_found" {
        error.worded(Wording::Devices(reason))
    } else {
        error
    }
}

impl State {
    /// A session with someone in the list as a friend, at minor 3 or more, not with one of our own devices.
    fn again_session(&self, id: u64) -> Option<String> {
        let session = self.sessions.map.get(&id)?;
        if session.channel.pattern() == Pattern::NN
            || session.channel.negotiated_minor() < AGAIN_MINOR
            || self.devices.exchanges.contains_key(&id)
        {
            return None;
        }
        let conversation = session.conversation.clone()?;
        let person = self.store.person_with_conversation(&conversation).ok().flatten()?;
        (person.relation == Relation::Friend && !self.is_own_device(&person.identity_key?)).then_some(conversation)
    }

    /// An AGAIN frame: a WANT for a file we sent them, or the PART or NONE answering ours.
    pub(crate) fn again_frame(&mut self, id: u64, frame: &Frame) {
        let Some(conversation) = self.again_session(id) else { return };
        let Some(message) = frame.get(tag::AGAIN).and_then(AgainMessage::decode) else { return };
        if matches!(message, AgainMessage::Want { .. }) {
            let mut server = std::mem::take(&mut self.again.server);
            let answers = server.answer(&self.store, &conversation, &message, unix_now(), &|k| self.is_own_device(k));
            self.again.server = server;
            for answer in answers.iter().filter_map(AgainMessage::encode) {
                self.send_on(id, &Frame::new(FrameType::Again).with(tag::AGAIN, answer));
            }
            return;
        }
        let Some(mut requester) = self.again.requesters.remove(&id) else { return };
        let changed = requester.receive(&mut self.devices.engine, &self.store, &message);
        self.again.requesters.insert(id, requester);
        self.flush_again(id);
        if changed {
            // A finished copy is held here again: our other computers hear it.
            self.pump_sync();
            self.changed();
        }
    }

    fn flush_again(&mut self, id: u64) {
        let messages = self.again.requesters.get_mut(&id).map(AgainRequester::take_messages).unwrap_or_default();
        for message in messages {
            self.send_on(id, &Frame::new(FrameType::Again).with(tag::AGAIN, message));
        }
    }

    /// The session carrying a friend's traffic: what was asked again of them starts copying.
    pub(crate) fn again_start(&mut self, id: u64, conversation: &str) {
        if self.again_session(id).is_none() || !self.has_asked_again(conversation) {
            return;
        }
        let requester = self.again.requesters.entry(id).or_insert_with(|| AgainRequester::new(conversation));
        requester.start_next(&self.devices.engine, &self.store);
        self.flush_again(id);
        self.changed();
    }

    /// Someone with a file asked again: reached nearby and online like someone with something to deliver.
    pub(crate) fn has_asked_again(&self, conversation: &str) -> bool {
        !AgainFile::asked(&self.store, conversation).is_empty()
    }

    /// What other areas keep per session ends with it: joining, our own devices' sync, Get again.
    pub(crate) fn session_closed_elsewhere(&mut self, id: u64) {
        self.join_session_closed(id);
        self.own_device_session_closed(id);
        self.again.requesters.remove(&id);
    }

    /// Get again: a file a friend sent, on none of the person's computers anymore, from that friend.
    pub fn fetch_from_friend(&mut self, transfer_id: &str) -> Result<(), &'static str> {
        if self.removed_computer() {
            return Err("not_allowed");
        }
        let conn = self.store.connection();
        let row = sync_files::transfer(conn, transfer_id).ok().flatten();
        let record = sync_files::sync_file(conn, transfer_id).ok().flatten();
        if row.is_none() && record.is_none() {
            return Err("not_found");
        }
        let file = AgainFile::of(&self.store, transfer_id).ok_or("not_allowed")?;
        // A file this person received, whose bytes are not here.
        let received = match &row {
            Some(row) => row.state == 6 && !holds_transfer(&self.store, row),
            None => record.as_ref().is_some_and(|r| r.state == 6),
        };
        // Another of our computers holds it: Get applies.
        let elsewhere = record.is_some_and(|r| r.holders.iter().any(|h| self.is_own_device(h)));
        let person = self.store.person_with_conversation(&file.conversation_id).ok().flatten().ok_or("not_found")?;
        let friend = person.relation == Relation::Friend && file.conversation_id != YOU;
        if !received || elsewhere || !friend {
            return Err("not_allowed");
        }
        set_again_state(&self.store, transfer_id, AgainState::Asked).map_err(|_| "internal")?;
        match self.sessions.live_for(&file.conversation_id) {
            Some(id) => self.again_start(id, &file.conversation_id),
            // That friend is reached nearby and online (has_asked_again).
            None => self.schedule_reconsider(),
        }
        self.changed();
        Ok(())
    }

    /// Cancel after Get again: the copy stops, what arrived stays for another Get again. `false` when not asked.
    pub(crate) fn cancel_again(&mut self, transfer_id: &str) -> bool {
        if again_state(&self.store, transfer_id) != AgainState::Asked {
            return false;
        }
        let _ = set_again_state(&self.store, transfer_id, AgainState::None);
        let ids: Vec<u64> = self.again.requesters.keys().copied().collect();
        for id in ids {
            if let Some(requester) = self.again.requesters.get_mut(&id) {
                requester.stop_copy(transfer_id);
                requester.start_next(&self.devices.engine, &self.store);
            }
            self.flush_again(id);
        }
        self.changed();
        true
    }

    /// An item's Get again facts: asked or gone, whether a session with that friend can copy it now, how much arrived.
    pub(crate) fn again_facts(&self, item: &mut ItemFacts, transfer_id: &str, conversation: &str) {
        item.again = again_state(&self.store, transfer_id);
        if item.again != AgainState::Asked {
            return;
        }
        let live = self.sessions.live_for(conversation);
        item.again_connected = live.is_some_and(|id| self.again_session(id).is_some());
        let copying = self.again.requesters.values().filter_map(AgainRequester::copying);
        item.again_fraction = copying.filter(|(id, _)| *id == transfer_id).map(|(_, f)| f).next().unwrap_or(0.0);
    }
}

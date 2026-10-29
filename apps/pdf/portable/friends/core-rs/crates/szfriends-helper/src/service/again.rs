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
    /// Files given again by blocks, by session and transfer (ADR 0018 § 4): what to send, and where the bytes are.
    /// Own-device copies by blocks are served here too (`sync`: answered by SYNC, else by AGAIN).
    pub serving: HashMap<(u64, String), Serving>,
}

pub use super::serving::Serving;

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
        // A holder's answer to a pull from several holders (pulls.rs).
        if let Some((transfer, answer)) = super::pulls::again_pull_message(&message) {
            if self.pull_message(id, &transfer, answer) {
                return;
            }
        }
        // More blocks of a file already given again by blocks on this session (a pull asks bit by bit): the same
        // serve takes them, so what it was asked before stays asked; its tree and leaves go again, for a requester
        // that started over.
        if let AgainMessage::WantBlocks { id: transfer, ranges, shift } = &message {
            if let Some(serving) = self.again.serving.get_mut(&(id, transfer.clone())) {
                if serving.serve.geometry().shift == *shift && serving.serve.want(ranges).is_ok() {
                    serving.heard();
                    let (hashes, root) = (serving.serve.hashes_frames(), serving.root);
                    let follow = AgainMessage::BlocksFollow { id: transfer.clone(), root, shift: *shift };
                    if let Some(bytes) = follow.encode() {
                        self.send_on(id, &Frame::new(FrameType::Again).with(tag::AGAIN, bytes));
                    }
                    for frame in hashes {
                        self.send_on(id, &frame);
                    }
                    return;
                }
            }
        }
        if matches!(message, AgainMessage::WantBlocks { .. }) && self.fast_session(id) {
            let mut server = std::mem::take(&mut self.again.server);
            let served =
                server.answer_blocks(&self.store, &conversation, &message, unix_now(), &|k| self.is_own_device(k));
            self.again.server = server;
            match served {
                Ok(blocks) => {
                    if let Some(follow) = blocks.follow.encode() {
                        self.send_on(id, &Frame::new(FrameType::Again).with(tag::AGAIN, follow));
                    }
                    for frame in blocks.serve.hashes_frames() {
                        self.send_on(id, &frame);
                    }
                    let root = match &blocks.follow {
                        AgainMessage::BlocksFollow { root, .. } => *root,
                        _ => [0; 32],
                    };
                    let serving = Serving::new(blocks.serve, blocks.path, false, root);
                    self.again.serving.insert((id, message.id().to_owned()), serving);
                }
                Err(answers) => {
                    for answer in answers.iter().filter_map(AgainMessage::encode) {
                        self.send_on(id, &Frame::new(FrameType::Again).with(tag::AGAIN, answer));
                    }
                }
            }
            return;
        }
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
        let frames = self.again.requesters.get_mut(&id).map(AgainRequester::take_frames).unwrap_or_default();
        for frame in frames {
            self.send_on(id, &frame);
        }
    }

    /// HASHES, PART or HAVE of a copy by blocks Get again runs on this session (ADR 0018 § 4): `true` when it was
    /// one, whichever side this computer is.
    pub(crate) fn again_block_frame(&mut self, id: u64, frame: &Frame) -> bool {
        if matches!(frame.frame_type, FrameType::Hashes | FrameType::Part) && self.pull_frame(id, frame) {
            return true; // a pull from several holders (pulls.rs)
        }
        let Some(transfer) = frame.get(tag::ID).map(super::hex) else { return false };
        match frame.frame_type {
            FrameType::Have => {
                let Some(serving) = self.again.serving.get_mut(&(id, transfer.clone())) else { return false };
                let ranges = szfriends_core::transfer::frames::ranges_of(frame, tag::RANGES).unwrap_or_default();
                let _ = serving.serve.have(&ranges);
                serving.heard();
                let sync = serving.sync;
                if serving.serve.all_acknowledged() {
                    self.again.serving.remove(&(id, transfer));
                }
                if sync {
                    self.changed(); // the You row says how far the copy is
                }
                true
            }
            FrameType::Hashes | FrameType::Part if self.devices.exchanges.contains_key(&id) => {
                let Some(mut exchange) = self.devices.exchanges.remove(&id) else { return false };
                if exchange.copying_by_blocks() != Some(transfer.as_str()) {
                    self.devices.exchanges.insert(id, exchange);
                    return false;
                }
                if frame.frame_type == FrameType::Hashes {
                    let (index, hashes) = (frame.integer(tag::INDEX).unwrap_or(0) as u32, frame.get(tag::HASHES));
                    exchange.hashes(&transfer, index, hashes.unwrap_or_default());
                } else {
                    let (offset, data) =
                        (frame.integer(tag::OFFSET).unwrap_or(0), frame.get(tag::DATA).unwrap_or_default());
                    exchange.part(&mut self.devices.engine, &self.store, &transfer, offset, data);
                }
                self.devices.exchanges.insert(id, exchange);
                self.flush_own_exchange(id);
                self.changed();
                true
            }
            FrameType::Hashes | FrameType::Part => {
                let copying = self.again.requesters.get(&id).and_then(AgainRequester::copying_by_blocks);
                if copying != Some(transfer.as_str()) {
                    return false;
                }
                let Some(mut requester) = self.again.requesters.remove(&id) else { return false };
                let changed = if frame.frame_type == FrameType::Hashes {
                    let (index, hashes) = (frame.integer(tag::INDEX).unwrap_or(0) as u32, frame.get(tag::HASHES));
                    requester.hashes(&transfer, index, hashes.unwrap_or_default());
                    false
                } else {
                    let (offset, data) =
                        (frame.integer(tag::OFFSET).unwrap_or(0), frame.get(tag::DATA).unwrap_or_default());
                    requester.part(&mut self.devices.engine, &self.store, &transfer, offset, data).1
                };
                self.again.requesters.insert(id, requester);
                self.flush_again(id);
                if changed {
                    self.pump_sync();
                }
                self.changed();
                true
            }
            _ => false,
        }
    }

    /// The next parts of what this session gives again by blocks, while the channel has room.
    pub(crate) fn pump_again(&mut self, id: u64) {
        let keys: Vec<(u64, String)> = self.again.serving.keys().filter(|(s, _)| *s == id).cloned().collect();
        for key in keys {
            loop {
                let Some(session) = self.sessions.map.get_mut(&id) else { return };
                if !session.channel.is_established() || !super::blocks::bulk_has_room(&session.channel) {
                    return;
                }
                let Some(Serving { serve, path, sync, .. }) = self.again.serving.get_mut(&key) else { break };
                let sync = *sync;
                if let Some(part) = serve.next_part() {
                    session.channel.send_frame(&part, szfriends_core::session::monotonic_now());
                    continue;
                }
                let Some(block) = serve.next_block() else { break };
                let (offset, length) = serve.geometry().span(block);
                let mut data = vec![0u8; length];
                let read = std::fs::File::open(&*path)
                    .and_then(|f| szfriends_core::transfer::tree::read_exact_at(&f, &mut data, offset));
                if read.is_err() || serve.load_block(block, data).is_err() {
                    // Changed or gone since it was checked: the other side hears it is gone (and the You row stops
                    // saying it is being copied).
                    self.again.serving.remove(&key);
                    self.changed();
                    if sync {
                        let mut none = vec![6u8, key.1.len() as u8];
                        none.extend_from_slice(key.1.as_bytes());
                        self.send_on(id, &Frame::new(FrameType::Sync).with(tag::SYNC, none));
                    } else if let Some(bytes) = (AgainMessage::None { id: key.1.clone(), reason: 0 }).encode() {
                        self.send_on(id, &Frame::new(FrameType::Again).with(tag::AGAIN, bytes));
                    }
                    break;
                }
            }
        }
    }

    /// The session carrying a friend's traffic: what was asked again of them starts copying.
    pub(crate) fn again_start(&mut self, id: u64, conversation: &str) {
        if self.again_session(id).is_none() || !self.has_asked_again(conversation) {
            return;
        }
        let fast = self.fast_session(id) && self.copies_by_blocks;
        let pulled = self.pulls_copies(id);
        let requester =
            self.again.requesters.entry(id).or_insert_with(|| AgainRequester::with_blocks(conversation, fast));
        // Copies by blocks are pulled from every holder at once (pulls.rs), not by this session's requester.
        requester.pulled = pulled;
        requester.start_next(&self.devices.engine, &self.store);
        if pulled {
            self.reconsider_pulls();
        }
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
        self.again.serving.retain(|(session, _), _| *session != id);
        self.pull_session_closed(id);
    }

    /// The friend's conversation when this session can carry Get again with them.
    pub(crate) fn again_session_conversation(&self, id: u64) -> Option<String> {
        self.again_session(id)
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
        self.room_for(file.size)?;
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
        self.pull_not_wanted(transfer_id);
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
        let by_requester = copying.filter(|(id, _)| *id == transfer_id).map(|(_, f)| f).next();
        item.again_fraction = self.pull_fraction(transfer_id).or(by_requester).unwrap_or(0.0);
    }
}

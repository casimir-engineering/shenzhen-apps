//! Lanes in the Rust peer, as the Rust helper runs them (`szfriends-helper/src/service/lanes.rs`, ADR 0018 § 6): a
//! session that negotiated fast transfers is the first of a group; `dial` with `"lane_of"` opens a lane of it (the
//! token from its handshake hash in IK message 1); the responder admits a lane whose token names a free index of the
//! group with the same identity, or closes it with CLOSE 6. When the first session goes, the lowest live lane takes its
//! place. Frames on a lane are the first session's, a PART's HAVE
//! goes back on its lane, and WP2's scheduler gives each block to a lane (`blocks.rs`). The bench dials the lanes
//! itself (one per emulated route), so lane requests from the scheduler are not dialed here.

use std::collections::{HashMap, HashSet};

use serde_json::{json, Value};
use szfriends_core::session::lanes::LaneGroup;
use szfriends_core::session::monotonic_now;
use szfriends_core::transfer::copies::lane_token;
use szfriends_core::transfer::scheduler::{Config, Scheduler, TransferKey};
use szfriends_core::wire::{CloseReason, RouteMethod};

use crate::peer::State;

/// One group: its lanes and its scheduler, with the transfers it knows by key.
pub(crate) struct Group {
    pub(crate) lanes: LaneGroup,
    pub(crate) scheduler: Scheduler,
    keys: HashMap<String, TransferKey>,
    next: TransferKey,
}

impl Group {
    pub(crate) fn key(&mut self, transfer: &str) -> TransferKey {
        if let Some(key) = self.keys.get(transfer) {
            return *key;
        }
        self.next += 1;
        self.keys.insert(transfer.to_owned(), self.next);
        self.next
    }

    pub(crate) fn name(&self, key: TransferKey) -> Option<String> {
        self.keys.iter().find(|(_, k)| **k == key).map(|(name, _)| name.clone())
    }

    /// Transfers that ended leave the scheduler.
    pub(crate) fn retain(&mut self, live: &[String]) {
        let gone: Vec<String> = self.keys.keys().filter(|k| !live.contains(k)).cloned().collect();
        for name in gone {
            if let Some(key) = self.keys.remove(&name) {
                self.scheduler.remove_transfer(key);
            }
        }
    }

    /// The group's lane events since the last call, to the scheduler.
    pub(crate) fn sync(&mut self) {
        let now = monotonic_now();
        for event in self.lanes.take_events() {
            self.scheduler.lane_event(event, now);
        }
    }
}

#[derive(Default)]
pub(crate) struct Lanes {
    pub(crate) groups: HashMap<u64, Group>,
    pub(crate) head_of: HashMap<u64, u64>,
    pub(crate) late_answered: HashSet<(u64, String, u32)>,
    /// Receiving: bytes of parts since the last HAVE naming pieces, by transfer.
    pub(crate) piece_bytes: HashMap<String, usize>,
}

impl State {
    pub(crate) fn head_of(&self, id: u64) -> u64 {
        self.lanes.head_of.get(&id).copied().unwrap_or(id)
    }

    /// A lane's route (the first session's own when it has no group).
    pub(crate) fn lane_route(&self, head: u64, lane: u64) -> RouteMethod {
        let group = self.lanes.groups.get(&head).and_then(|g| g.lanes.route_of(lane));
        group.or_else(|| self.sessions.get(&lane).map(|s| s.channel.initiator_route())).unwrap_or(RouteMethod::Lan)
    }

    /// `dial` with `"lane_of"`: the lane's token for one more lane of that session's group on `route`.
    pub(crate) fn reserve_lane(&mut self, head: u64, provisional: u64, route: RouteMethod) -> Option<[u8; 16]> {
        let group = self.lanes.groups.get_mut(&head)?;
        let (_, token) = group.lanes.reserve(provisional, route)?;
        self.lanes.head_of.insert(provisional, head);
        Some(token)
    }

    /// The dialed lane's session exists: its provisional id becomes the session's.
    pub(crate) fn lane_dialed(&mut self, head: u64, provisional: u64, id: u64) {
        self.lanes.head_of.remove(&provisional);
        if let Some(group) = self.lanes.groups.get_mut(&head) {
            group.lanes.rename(provisional, id);
            self.lanes.head_of.insert(id, head);
        }
    }

    pub(crate) fn lane_dial_failed(&mut self, head: u64, provisional: u64) {
        self.lanes.head_of.remove(&provisional);
        if let Some(group) = self.lanes.groups.get_mut(&head) {
            group.lanes.lane_down(provisional);
        }
    }

    /// A session went live: `true` when it is a lane (admitted, or refused and closing); otherwise a fast first
    /// session forms its group.
    pub(crate) fn lane_established(&mut self, id: u64, event: &Value) -> bool {
        let Some(session) = self.sessions.get(&id) else { return false };
        let channel = &session.channel;
        let (fast, initiator) = (channel.fast_transfers(), channel.is_initiator());
        if initiator {
            if let Some(&head) = self.lanes.head_of.get(&id) {
                match self.lanes.groups.get_mut(&head) {
                    Some(group) if fast => group.lanes.lane_up(id),
                    _ => self.close_lane(id, CloseReason::Normal),
                }
                self.emit(lane_event(event, head));
                return true;
            }
        } else if let Some(token) = channel.presented_lane().copied() {
            let (identity, route) = (channel.remote_identity().copied(), channel.initiator_route());
            let head = self.lanes.groups.iter().find(|(_, g)| Some(*g.lanes.identity()) == identity).map(|(h, _)| *h);
            let admitted = head.filter(|_| fast).and_then(|head| {
                let group = self.lanes.groups.get_mut(&head)?;
                group.lanes.admit(id, &token, route).ok().map(|_| head)
            });
            match admitted {
                Some(head) => {
                    self.lanes.head_of.insert(id, head);
                    if let Some(group) = self.lanes.groups.get_mut(&head) {
                        group.lanes.lane_up(id);
                    }
                    self.emit(lane_event(event, head));
                }
                None => self.close_lane(id, CloseReason::LaneRefused),
            }
            return true;
        }
        let (Some(h), Some(identity)) = (channel.handshake_hash().copied(), channel.remote_identity().copied()) else {
            return false;
        };
        if fast {
            let route = channel.initiator_route();
            let lanes = LaneGroup::new(id, identity, initiator, route, |i| lane_token(&h, i));
            let config =
                Config { phone: false, direct_wifi_keeps_internet: cfg!(any(target_os = "macos", target_os = "ios")) };
            let group = Group { lanes, scheduler: Scheduler::new(config), keys: HashMap::new(), next: 0 };
            self.lanes.groups.insert(id, group);
        }
        false
    }

    fn close_lane(&mut self, id: u64, reason: CloseReason) {
        if let Some(s) = self.sessions.get_mut(&id) {
            s.channel.close_with_reason(reason, monotonic_now());
        }
    }

    /// A session closed: a lane leaves its group (the scheduler gives its blocks to the others); a first session
    /// closes its lanes and ends the group.
    pub(crate) fn lane_closed(&mut self, id: u64) {
        if let Some(mut group) = self.lanes.groups.remove(&id) {
            // The first session went (ADR 0018 § 6: the group goes on with the rest): the lowest live lane takes over
            // what it held, its conversation and its files by blocks; the scheduler hears the lane go down.
            if group.lanes.lane_down(id) {
                return;
            }
            let head = group.lanes.first();
            self.lanes.head_of.remove(&head);
            for lane in self.lanes.head_of.values_mut() {
                *lane = head;
            }
            let (conversation, mut blocks) = match self.sessions.get_mut(&id) {
                Some(old) => (old.conversation.take(), std::mem::take(&mut old.blocks)),
                None => (None, crate::blocks::Blocks::default()),
            };
            for send in blocks.senders.values_mut() {
                send.lanes.remove(&id);
            }
            if let Some(new) = self.sessions.get_mut(&head) {
                new.conversation = conversation;
                new.blocks = blocks;
            }
            self.lanes.groups.insert(head, group);
            self.lanes.late_answered.retain(|(lane, _, _)| *lane != id);
            return;
        }
        let Some(head) = self.lanes.head_of.remove(&id) else { return };
        if let Some(group) = self.lanes.groups.get_mut(&head) {
            group.lanes.lane_down(id);
        }
        if let Some(session) = self.sessions.get_mut(&head) {
            for send in session.blocks.senders.values_mut() {
                send.lanes.remove(&id);
            }
        }
        self.lanes.late_answered.retain(|(lane, _, _)| *lane != id);
    }

    /// A write completed on a session's link, or bytes arrived from its peer: its group's scheduler hears it.
    pub(crate) fn lane_activity(&mut self, id: u64, heard: bool) {
        let head = self.head_of(id);
        // A write counts as the lane moving only while it carries parts: a PING's (sent every second while a file
        // moves) would keep a lane whose route went silent looking alive until the session's own 8 or 12 s.
        let carrying = self.sessions.get(&id).is_some_and(|s| s.channel.queued_frames().1 > 0)
            || self.sessions.get(&head).is_some_and(|s| {
                s.blocks.senders.values().any(|send| send.lanes.get(&id).is_some_and(|q| !q.is_empty()))
            });
        if !heard && !carrying {
            return;
        }
        let Some(group) = self.lanes.groups.get_mut(&head) else { return };
        let now = monotonic_now();
        if heard {
            group.scheduler.heard(id, now);
        } else {
            group.scheduler.written(id, now);
        }
    }
}

/// The `established` event of a lane names the session it joined.
fn lane_event(event: &Value, head: u64) -> Value {
    let mut event = event.clone();
    event["lane_of"] = json!(head);
    event
}

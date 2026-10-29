//! Lanes in the Rust helper (ADR 0018 § 6): more sessions with a friend's device, bound to the first by its handshake
//! hash, so a file goes over the local network, direct Wi-Fi and Bluetooth at once. A first session that negotiated
//! fast transfers forms a group when it is adopted; while it sends files by blocks, a scheduler (WP2,
//! `transfer::scheduler`) hears the group's lanes, the WANTs, HAVEs, writes and bytes heard, gives each block to a
//! lane and asks for lanes, which this side dials on the friend's routes; the other side admits a lane whose token names a free index of the group, or closes it with CLOSE
//! `LaneRefused`. Lanes never race, never carry a conversation of their own and never count against the person's
//! backoff: every frame on a lane is handled as if it came on the group's first session, and the first session's end
//! ends its lanes. `blocks.rs` spreads whole blocks over the group's live lanes.
//!
//! Lanes the scheduler asks for open one per route the friend's device is seen on, never the relay (the scheduler's
//! rules: Bluetooth only while the others measure below 4 MB/s, direct Wi-Fi only where it keeps the device on its
//! network). Another lane on the same route is never opened here: the helper decrypts on one thread, so it would add
//! no core, and nothing reports `cpu_bound`.

use std::collections::HashMap;

use szfriends_core::nearby::Method;
use szfriends_core::session::lanes::{LaneEvent, LaneGroup, LaneId};
use szfriends_core::store::unix_now;
use szfriends_core::transfer::copies::lane_token;
use szfriends_core::transfer::scheduler::{Config, Scheduler, TransferKey};
use szfriends_core::wire::{CloseReason, RouteMethod};

use super::nearby::{DialPlan, Purpose};
use super::State;
use crate::log;

/// A route whose lane failed or closed is dialed again after this long.
const REDIAL_SECONDS: f64 = 10.0;

/// One group's scheduler (or the first session's alone), and the transfers it knows by key.
pub struct Schedule {
    pub scheduler: Scheduler,
    keys: HashMap<String, TransferKey>,
    next: TransferKey,
}

impl Schedule {
    /// The key a transfer is known by (given the first time it is asked for).
    pub fn key(&mut self, transfer: &str) -> TransferKey {
        if let Some(key) = self.keys.get(transfer) {
            return *key;
        }
        self.next += 1;
        self.keys.insert(transfer.to_owned(), self.next);
        self.next
    }

    pub fn name(&self, key: TransferKey) -> Option<String> {
        self.keys.iter().find(|(_, k)| **k == key).map(|(name, _)| name.clone())
    }

    /// Transfers that ended (acknowledged, cancelled, failed) leave the scheduler.
    pub fn retain(&mut self, live: &[String]) {
        let gone: Vec<String> = self.keys.keys().filter(|k| !live.contains(k)).cloned().collect();
        for name in gone {
            if let Some(key) = self.keys.remove(&name) {
                self.scheduler.remove_transfer(key);
            }
        }
    }
}

/// One group: the core's bookkeeping, and when each route was last dialed.
pub struct Group {
    pub lanes: LaneGroup,
    dialed: HashMap<RouteMethod, f64>,
}

#[derive(Default)]
pub struct Groups {
    /// By the first session's id.
    pub by_head: HashMap<u64, Group>,
    /// The scheduler of each first session sending files by blocks.
    pub schedules: HashMap<u64, Schedule>,
    /// Receiving: bytes of parts since the last HAVE naming pieces, by transfer (§ 3).
    pub piece_bytes: HashMap<String, usize>,
    /// Receiving: (lane, transfer, block) whose late part was answered with a HAVE (§ 3: once per block per lane).
    pub late_answered: std::collections::HashSet<(u64, String, u32)>,
    /// Each lane's first session (dialing lanes under a provisional id until their session exists).
    pub head_of: HashMap<u64, u64>,
    next_provisional: u64,
}

impl Groups {
    fn provisional(&mut self) -> u64 {
        self.next_provisional += 1;
        u64::MAX - self.next_provisional
    }

    /// The route of one of a first session's lanes (the first session's own when it has no group).
    pub fn route_of(&self, head: u64, lane: u64) -> Option<RouteMethod> {
        self.by_head.get(&head).and_then(|g| g.lanes.route_of(lane))
    }

    /// The lanes to spread parts over: the group's live ones, or the session alone.
    pub fn live_lanes(&self, head: u64, route: RouteMethod) -> Vec<(LaneId, RouteMethod)> {
        match self.by_head.get(&head) {
            Some(group) => group.lanes.live().map(|(id, _, route)| (id, route)).collect(),
            None => vec![(head, route)],
        }
    }
}

/// Parts of a block cut for this route's lane (§ 9.8: 16 KiB on Bluetooth, a quarter of the writes of 4 KiB chunks).
pub fn part_bytes(route: RouteMethod) -> usize {
    if route == RouteMethod::Bluetooth {
        16 * 1024
    } else {
        szfriends_core::session::chunk_bytes_for_route(route)
    }
}

fn method_for(route: RouteMethod) -> Option<Method> {
    match route {
        RouteMethod::Lan | RouteMethod::PeerToPeerWifi => Some(Method::Network),
        RouteMethod::Bluetooth => Some(Method::Bluetooth),
        _ => None,
    }
}

impl State {
    /// A session's group head: itself unless it is a lane.
    pub(crate) fn head_of(&self, id: u64) -> u64 {
        self.sessions.groups.head_of.get(&id).copied().unwrap_or(id)
    }

    /// A first session just adopted: a group, when it negotiated fast transfers.
    pub(crate) fn form_group(&mut self, id: u64) {
        if !self.lanes || self.sessions.groups.by_head.contains_key(&id) {
            return;
        }
        let Some(session) = self.sessions.map.get(&id) else { return };
        let channel = &session.channel;
        let (Some(h), Some(identity)) = (channel.handshake_hash().copied(), channel.remote_identity().copied()) else {
            return;
        };
        if !channel.fast_transfers() || session.conversation.is_none() {
            return;
        }
        let route = session.meta.race_route(channel);
        let lanes = LaneGroup::new(id, identity, channel.is_initiator(), route, |i| lane_token(&h, i));
        self.sessions.groups.by_head.insert(id, Group { lanes, dialed: HashMap::new() });
    }

    /// The first session ended or lost the race: its lanes close with it.
    pub(crate) fn end_group(&mut self, head: u64) {
        self.sessions.groups.schedules.remove(&head);
        let Some(group) = self.sessions.groups.by_head.remove(&head) else { return };
        for lane in group.lanes.lanes_only() {
            self.sessions.groups.head_of.remove(&lane);
            self.close(lane, CloseReason::Normal);
        }
    }

    /// A session went live: `true` when it is a lane, admitted into its group (or refused and closing).
    pub(crate) fn lane_went_live(&mut self, id: u64) -> bool {
        let Some(session) = self.sessions.map.get(&id) else { return false };
        if session.channel.is_initiator() {
            if session.meta.purpose != Purpose::Lane {
                return false;
            }
            let head = self.head_of(id);
            let fast = session.channel.fast_transfers();
            match self.sessions.groups.by_head.get_mut(&head) {
                Some(group) if fast => group.lanes.lane_up(id),
                _ => self.close(id, CloseReason::Normal),
            }
            return true;
        }
        let Some(token) = session.channel.presented_lane().copied() else { return false };
        let (identity, static_key) =
            (session.channel.remote_identity().copied(), session.channel.remote_static().copied());
        let (fast, route) = (session.channel.fast_transfers(), session.channel.initiator_route());
        let head = self.sessions.groups.by_head.iter().find(|(head, group)| {
            Some(*group.lanes.identity()) == identity
                && self.sessions.map.get(head).and_then(|s| s.channel.remote_static().copied()) == static_key
        });
        // An AES-GCM lane only into a group whose first session agreed to them (both set bit 1).
        let aes = session.channel.cipher() == szfriends_core::wire::NoiseCipher::AesGcm;
        let cipher_ok = |head: &u64| !aes || self.sessions.map.get(head).is_some_and(|s| s.channel.aes_lanes());
        let admitted = match head {
            Some((head, _)) if fast && self.lanes && cipher_ok(head) => {
                let head = *head;
                let group = self.sessions.groups.by_head.get_mut(&head).expect("found");
                group.lanes.admit(id, &token, route).map(|index| (head, index))
            }
            _ => Err(szfriends_core::session::lanes::LaneRefusal::Token),
        };
        match admitted {
            Ok((head, _)) => {
                self.sessions.groups.head_of.insert(id, head);
                if let Some(group) = self.sessions.groups.by_head.get_mut(&head) {
                    group.lanes.lane_up(id);
                }
            }
            Err(refusal) => {
                log!("lane refused: {refusal:?}");
                self.close(id, CloseReason::LaneRefused);
            }
        }
        true
    }

    /// A session ended: a lane leaves its group and its blocks go back to the others; a first session ends its group.
    pub(crate) fn lane_closed(&mut self, id: u64) {
        if self.sessions.groups.by_head.contains_key(&id) {
            let superseded = self.sessions.map.get(&id).is_none_or(|s| s.meta.superseded);
            if superseded || !self.promote_lane(id) {
                self.end_group(id);
            }
            return;
        }
        let Some(head) = self.sessions.groups.head_of.remove(&id) else { return };
        if let Some(group) = self.sessions.groups.by_head.get_mut(&head) {
            let route = group.lanes.route_of(id);
            group.lanes.lane_down(id);
            if let Some(route) = route {
                group.dialed.insert(route, unix_now());
            }
        }
        self.lane_lost(head, id);
    }

    /// The first session's route went (cut or silent) while lanes live (ADR 0018 § 6: the group goes on with the
    /// rest): the lowest live lane carries the conversation from now on, with its files by blocks and the ACKs they
    /// await; what was written on the first session and not acknowledged goes again on it. `false` when no lane is
    /// live, and the group ends.
    fn promote_lane(&mut self, id: u64) -> bool {
        let Some(mut group) = self.sessions.groups.by_head.remove(&id) else { return false };
        if group.lanes.lane_down(id) {
            self.sessions.groups.by_head.insert(id, group);
            return false;
        }
        let head = group.lanes.first();
        let Some(old) = self.sessions.map.get_mut(&id) else { return false };
        let conversation = old.conversation.take();
        let adopted = std::mem::take(&mut old.meta.adopted);
        let carried = (
            std::mem::take(&mut old.block_senders),
            std::mem::take(&mut old.block_receivers),
            std::mem::take(&mut old.expecting),
            std::mem::take(&mut old.senders),
            std::mem::take(&mut old.receivers),
        );
        let lost: Vec<String> = old.in_flight.drain().collect();
        for entry in lost {
            let _ = self.store.apply_outbox_event(&entry, szfriends_core::store::OutboxEvent::SessionLost);
        }
        let Some(new) = self.sessions.map.get_mut(&head) else { return false };
        new.conversation = conversation.clone();
        new.meta.adopted = adopted;
        (new.block_senders, new.block_receivers, new.expecting, new.senders, new.receivers) = carried;
        for send in new.block_senders.values_mut() {
            send.lanes.remove(&id);
        }
        self.sessions.groups.head_of.remove(&head);
        for first in self.sessions.groups.head_of.values_mut() {
            *first = head;
        }
        self.sessions.groups.by_head.insert(head, group);
        if let Some(schedule) = self.sessions.groups.schedules.remove(&id) {
            self.sessions.groups.schedules.insert(head, schedule);
        }
        self.sessions.groups.late_answered.retain(|(lane, _, _)| *lane != id);
        log!("lane {head} carries the conversation: its first session {id} ended");
        if conversation.is_some() {
            self.deliver_pending(head);
        }
        self.changed();
        true
    }

    /// A lane's dial did not connect.
    pub(crate) fn lane_dial_failed(&mut self, plan: &DialPlan) {
        let Some((head, provisional)) = plan.lane else { return };
        self.sessions.groups.head_of.remove(&provisional);
        if let Some(group) = self.sessions.groups.by_head.get_mut(&head) {
            group.lanes.lane_down(provisional);
        }
    }

    /// A lane's stream arrived: the provisional id becomes the session's.
    pub(crate) fn lane_dialed(&mut self, plan: &DialPlan, id: u64) {
        let Some((head, provisional)) = plan.lane else { return };
        self.sessions.groups.head_of.remove(&provisional);
        match self.sessions.groups.by_head.get_mut(&head) {
            Some(group) => {
                group.lanes.rename(provisional, id);
                self.sessions.groups.head_of.insert(id, head);
            }
            None => self.close(id, CloseReason::Normal),
        }
    }

    /// The scheduler of a first session sending by blocks, made the first time, with what its group did since.
    pub(crate) fn schedule(&mut self, head: u64, route: RouteMethod) -> &mut Schedule {
        let now = szfriends_core::session::monotonic_now();
        let groups = &mut self.sessions.groups;
        if !groups.schedules.contains_key(&head) {
            let config = Config {
                phone: cfg!(any(target_os = "android", target_os = "ios")),
                // AWDL keeps a Mac or an iPhone on its Wi-Fi network beside a direct link; elsewhere direct Wi-Fi
                // would take the device off it.
                direct_wifi_keeps_internet: cfg!(any(target_os = "macos", target_os = "ios")),
            };
            let mut scheduler = Scheduler::new(config);
            // The lanes live now; what the group reports after this goes to the scheduler as it happens.
            match groups.by_head.get_mut(&head) {
                Some(group) => {
                    group.lanes.take_events();
                    for (lane, index, route) in group.lanes.live() {
                        scheduler.lane_event(LaneEvent::Up { lane, index, route }, now);
                    }
                }
                None => scheduler.lane_event(LaneEvent::Up { lane: head, index: 0, route }, now),
            }
            groups.schedules.insert(head, Schedule { scheduler, keys: HashMap::new(), next: 0 });
        }
        let schedule = groups.schedules.get_mut(&head).expect("made above");
        if let Some(group) = groups.by_head.get_mut(&head) {
            for event in group.lanes.take_events() {
                schedule.scheduler.lane_event(event, now);
            }
        }
        schedule
    }

    /// A write on a session's link completed, or bytes arrived from its peer: the scheduler of its group hears it.
    pub(crate) fn lane_written(&mut self, id: u64, heard: bool) {
        let head = self.head_of(id);
        // A write counts as the lane moving only while it carries parts: a PING's (sent every second while a file
        // moves) would keep a lane whose route went silent looking alive until the session's own 8 or 12 s.
        let carrying = self.sessions.map.get(&id).is_some_and(|s| s.channel.queued_frames().1 > 0)
            || self.sessions.map.get(&head).is_some_and(|s| {
                s.block_senders.values().any(|send| send.lanes.get(&id).is_some_and(|q| !q.is_empty()))
            });
        if !heard && !carrying {
            return;
        }
        let Some(schedule) = self.sessions.groups.schedules.get_mut(&head) else { return };
        let now = szfriends_core::session::monotonic_now();
        if heard {
            schedule.scheduler.heard(id, now);
        } else {
            schedule.scheduler.written(id, now);
        }
    }

    /// The scheduler asked for a lane on `route`: dialed to where the friend's device is seen on it, if anywhere.
    pub(crate) fn open_lane(&mut self, head: u64, route: RouteMethod) {
        if !self.lanes || matches!(route, RouteMethod::Relay | RouteMethod::Internet | RouteMethod::None) {
            return; // online lanes are data channels in the peer connection: not built yet
        }
        let Some(session) = self.sessions.map.get(&head) else { return };
        let (Some(conversation), Some(remote_static)) =
            (session.conversation.clone(), session.channel.remote_static().copied())
        else {
            return;
        };
        let Some(group) = self.sessions.groups.by_head.get(&head) else { return };
        let identity = *group.lanes.identity();
        let now = unix_now();
        if group.dialed.get(&route).is_some_and(|at| now - at < REDIAL_SECONDS) {
            return;
        }
        let sighting = self
            .nearby
            .merger
            .candidates()
            .iter()
            .filter(|c| c.conversation_id.as_deref() == Some(conversation.as_str()))
            .flat_map(|c| c.sightings.iter())
            .find(|s| s.route == route && method_for(route) == Some(s.method))
            .map(|s| (s.endpoint.clone(), s.method));
        let Some((endpoint, method)) = sighting else { return };
        let Some(person) = self.store.person_with_conversation(&conversation).ok().flatten() else { return };
        let provisional = self.sessions.groups.provisional();
        let group = self.sessions.groups.by_head.get_mut(&head).expect("looked up");
        group.dialed.insert(route, now);
        let Some((_, token)) = group.lanes.reserve(provisional, route) else { return };
        let mut options = self.ik_options(&person, route);
        options.remote_static = Some(remote_static);
        options.expected_identity = Some(identity);
        options.request_token = None;
        options.lane = Some(token);
        // ADR 0018 § 9.2: AES-256-GCM when both first handshakes said hardware AES; ChaChaPoly otherwise.
        if self.sessions.map.get(&head).is_some_and(|s| s.channel.aes_lanes()) {
            options.cipher = szfriends_core::wire::NoiseCipher::AesGcm;
        }
        let plan = DialPlan {
            method,
            endpoint: endpoint.clone(),
            route,
            purpose: Purpose::Lane,
            options,
            conversation: None,
            probe: false,
            request_token: None,
            attempt_key: None,
            dial_key: format!("lane|{head}|{}|{endpoint}", route as u8),
            lane: Some((head, provisional)),
        };
        self.sessions.groups.head_of.insert(provisional, head);
        if !self.dial(plan.clone(), 0.0) {
            self.lane_dial_failed(&plan);
        }
    }

    /// Whether a file moves by blocks within this session's group, and whether the peer owes us something: the
    /// liveness a fast session or lane asks of its channel (both sides ping on fast sessions, so watching is safe).
    pub(crate) fn block_liveness(&self, id: u64) -> (bool, bool) {
        let head = self.head_of(id);
        let Some(session) = self.sessions.map.get(&head) else { return (false, false) };
        let sending = !session.block_senders.is_empty();
        let receiving = !session.block_receivers.is_empty();
        let owed = session.block_senders.values().any(|s| !s.serve.all_acknowledged())
            || session.block_receivers.iter().any(|t| !self.store.blocks_all_durable(t));
        (sending || receiving, owed)
    }
}

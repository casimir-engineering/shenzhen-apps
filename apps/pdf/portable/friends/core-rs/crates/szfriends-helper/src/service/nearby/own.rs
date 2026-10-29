//! Sync between this person's own devices (`SZFriendsNearbyService+Sync.m`, ADR 0014 § Transport).
//!
//! Our devices find each other nearby by tags only they can match (each advertises a tag from the own-devices secret
//! and its device key in the first callback slot, and matches the others'), and online as the driver reaches a
//! friend. They connect with IK to the static key our chain gives each device, send the chain first, then run the
//! sync exchange over SYNC frames until the session ends. One session per pair: when both dial, the one the lower key
//! opened stays. Changes become events only while such a session is live.

use szfriends_core::identity::chain::DeviceChain;
use szfriends_core::nearby::callbacks::{window, window_end};
use szfriends_core::nearby::merger::Candidate;
use szfriends_core::nearby::racer::should_start;
use szfriends_core::nearby::Tag;
use szfriends_core::session::HandshakeOptions;
use szfriends_core::store::devices::{self, ChainMerge};
use szfriends_core::store::unix_now;
use szfriends_core::sync::{device_tag_secret, friend_device_tag_secret, SyncError, SyncExchange};
use szfriends_core::wire::{tag, CloseReason, Frame, FrameType, Pattern, RouteMethod};

use super::Purpose;
use crate::log;
use crate::service::{hex, unhex, State};

/// What the matcher names our own devices' sightings by: "dev-" and the device key in hex.
const OWN_DEVICE_PREFIX: &str = "dev-";
/// A dial to one of our devices is not repeated before this.
const OWN_DEVICE_REDIAL: f64 = 30.0;
/// Changes are captured at most this often while a session with another of our devices is live.
const CAPTURE_DELAY: f64 = 0.3;

fn key_of(hex_key: &str) -> Option<[u8; 32]> {
    unhex(hex_key).and_then(|k| k.try_into().ok())
}

impl State {
    pub(crate) fn own_root(&self) -> Option<[u8; 32]> {
        devices::root_for_device(self.store.connection(), &self.identity.public_key()).ok().flatten()
    }

    /// Another device our chain authorizes now.
    pub(crate) fn is_own_device(&self, key: &[u8; 32]) -> bool {
        let root = self.own_root();
        *key != self.identity.public_key()
            && root.is_some()
            && devices::root_for_device(self.store.connection(), key).ok().flatten() == root
            && !devices::is_revoked_device(self.store.connection(), key).unwrap_or(true)
    }

    fn sync_active(&self) -> bool {
        self.devices.engine.is_active(&self.store)
    }

    /// The matcher's entries for our other devices; when they changed (a device joined, or we learned the secret our
    /// devices find each other by), every adapter reads anew: their tags appear only in reads made from now on, and
    /// Bluetooth caches a read per window.
    pub(crate) fn own_device_tag_secrets_rereading(&mut self) -> Vec<(String, Vec<u8>)> {
        let own = self.own_device_tag_secrets();
        if own != self.devices.matched_own {
            self.devices.matched_own = own.clone();
            for adapter in &mut self.nearby.adapters {
                adapter.reread();
            }
        }
        own
    }

    /// The matcher's entries for our other devices.
    pub(crate) fn own_device_tag_secrets(&self) -> Vec<(String, Vec<u8>)> {
        let engine = &self.devices.engine;
        let Some(secret) = engine.own_devices_secret(&self.store).filter(|_| self.sync_active()) else {
            return Vec::new();
        };
        let others = engine.other_device_keys(&self.store);
        let named = others
            .iter()
            .filter_map(|d| Some((format!("{OWN_DEVICE_PREFIX}{}", hex(d)), device_tag_secret(&secret, d)?)));
        named.map(|(name, s)| (name, s.to_vec())).collect()
    }

    /// Our tag for our other devices this window.
    pub(crate) fn own_device_tag(&self, now: f64) -> Option<Tag> {
        let secret = self.devices.engine.own_devices_secret(&self.store).filter(|_| self.sync_active())?;
        let mine = device_tag_secret(&secret, &self.identity.public_key())?;
        Some(szfriends_core::crypto::presence::tag(&mine, window(now)))
    }

    /// One of several devices of this profile, not the first: friends who hold our chain find it by its own tag.
    pub(crate) fn own_friend_presence_tag(&self, now: f64) -> Option<Tag> {
        let me = self.identity.public_key();
        self.own_root().filter(|root| *root != me)?;
        let secret = self.store.own_presence_secret()?;
        let mine = friend_device_tag_secret(&secret, &me)?;
        Some(szfriends_core::crypto::presence::tag(&mine, window(now)))
    }

    pub(crate) fn own_device_live_link(&self, device: &[u8; 32]) -> Option<u64> {
        let id = *self.devices.links.get(device)?;
        self.sessions.map.get(&id).filter(|s| !s.channel.is_closed()).map(|_| id)
    }

    fn own_device_options(&self, device: &[u8; 32], route: RouteMethod) -> Option<HandshakeOptions> {
        let root = self.own_root()?;
        let static_key = devices::static_key_for_device(self.store.connection(), device, &root).ok().flatten()?;
        let mut options = HandshakeOptions::new(Pattern::IK, route);
        options.remote_static = Some(static_key);
        options.expected_identity = Some(*device);
        Some(options)
    }

    /// A candidate the matcher named after one of our devices; `false` for anyone else. Dialed as a friend is
    /// (`dial.rs`): every route the racer allows, staggered toward the better ones, and while a session carries our
    /// sync only a route that ranks before it, so the sync moves to it as a friend's files do (ADR 0001 § Session race).
    pub(crate) fn reach_own_device_candidate(&mut self, candidate: &Candidate) -> bool {
        let Some(name) = candidate.conversation_id.as_deref().and_then(|c| c.strip_prefix(OWN_DEVICE_PREFIX)) else {
            return false;
        };
        let Some(device) = key_of(name).filter(|d| self.is_own_device(d) && self.sync_active()) else { return true };
        let now = unix_now();
        let live = self.own_device_live_link(&device);
        let current = live.map_or(RouteMethod::None, |id| {
            let s = &self.sessions.map[&id];
            s.meta.race_route(&s.channel)
        });
        if live.is_none() && self.devices.dial_after.get(&device).is_some_and(|t| *t > now) {
            return true;
        }
        let attempts = self.nearby.racer.attempts(candidate, self.nearby.merger.matcher(), now);
        let mut started = false;
        for attempt in attempts.iter().filter(|a| !a.sighting.public) {
            if !should_start(attempt, current) {
                continue;
            }
            let Some(options) = self.own_device_options(&device, attempt.sighting.route) else { return true };
            let mut plan = self.plan(&attempt.sighting, Purpose::OwnDevice, options);
            plan.conversation = candidate.conversation_id.clone();
            started = self.dial(plan, attempt.delay) || started;
        }
        if started && live.is_none() {
            // Not again for a while, however it ends: a session that goes live clears this.
            self.devices.dial_after.insert(device, now + OWN_DEVICE_REDIAL);
        }
        true
    }

    /// A device that has not learned the own-devices secret yet cannot match its siblings' tags: IK at each
    /// unrecognised device nearby, once per device and window, for each of our devices with no session. A device
    /// that is not ours cannot decrypt IK's first message and learns nothing.
    pub(crate) fn probe_for_own_devices(&mut self) {
        if !self.sync_active() || self.devices.engine.own_devices_secret(&self.store).is_some() {
            return;
        }
        let unmatched: Vec<Candidate> = self.nearby.merger.unmatched().to_vec();
        let now = unix_now();
        for device in self.devices.engine.other_device_keys(&self.store) {
            if self.own_device_live_link(&device).is_some() {
                continue;
            }
            for candidate in &unmatched {
                let Some(sighting) = candidate.sightings.first().filter(|s| !s.public).cloned() else { continue };
                let key = format!("own|{}|{}|{}", hex(&device), sighting.endpoint, window(now));
                if self.nearby.attempts.contains_key(&key) {
                    continue;
                }
                self.nearby.attempts.insert(key, window_end(now));
                let Some(options) = self.own_device_options(&device, sighting.route) else { break };
                let mut plan = self.plan(&sighting, Purpose::OwnDevice, options);
                plan.probe = true;
                self.dial(plan, 0.0);
            }
        }
    }

    /// Our devices online needs to reach: no session with them on a route better than a direct Internet connection.
    /// Every one of our devices asks, whichever key sorts first, as the Mac helper's do: the driver settles two offers
    /// crossing. A computer that just joined must ask itself: the one it joined may have asked before this one's
    /// records were filed under the person, found nobody and is waiting out a backoff.
    #[cfg_attr(not(feature = "online"), allow(dead_code))]
    pub(crate) fn own_devices_to_reach_online(&self) -> Vec<[u8; 32]> {
        if !self.sync_active() {
            return Vec::new();
        }
        let me = self.identity.public_key();
        let others = self.devices.engine.other_device_keys(&self.store);
        others
            .into_iter()
            .filter(|d| {
                let live = self.own_device_live_link(d).map(|id| self.sessions.map[&id].channel.initiator_route());
                reach_online(&me, d, live)
            })
            .collect()
    }

    /// Our other devices as the online driver reaches them: the static key our chain gives each.
    #[cfg(feature = "online")]
    pub(crate) fn own_devices_online(&self) -> Vec<szfriends_online::driver::OnlineFriend> {
        if !self.sync_active() {
            return Vec::new();
        }
        let Some(root) = self.own_root() else { return Vec::new() };
        let presence = self.store.own_presence_secret();
        let others = self.devices.engine.other_device_keys(&self.store);
        others
            .into_iter()
            .filter_map(|device| {
                let static_key = devices::static_key_for_device(self.store.connection(), &device, &root).ok()??;
                Some(szfriends_online::driver::OnlineFriend {
                    identity_key: device,
                    static_key,
                    presence_secret: presence,
                    request_token: None,
                    // Every device of ours checks in for the person, so its records are filed under our root.
                    root_key: Some(root),
                })
            })
            .collect()
    }

    /// A live IK session with another of our devices becomes the sync session with it; `false` for anyone else.
    pub(crate) fn own_device_live(&mut self, id: u64) -> bool {
        let Some(session) = self.sessions.map.get(&id) else { return false };
        let Some(remote) = session.channel.remote_identity().copied().filter(|k| self.is_own_device(k)) else {
            return false;
        };
        if session.channel.pattern() != Pattern::IK || !self.sync_active() {
            self.close(id, CloseReason::Normal);
            return true;
        }
        let _ = devices::note_device_seen(self.store.connection(), &remote, unix_now());
        if let Some(current) = self.own_device_live_link(&remote).filter(|c| *c != id) {
            // Two sessions with one of our devices: the race friends' sessions run (links.rs), so the better route
            // carries the sync and what was copying resumes on it from the bytes already here.
            match self.race(id, current) {
                Some(true) => self.supersede_own_device(current),
                Some(false) => {
                    self.supersede_own_device(id);
                    return true;
                }
                None => return true, // standby until the initiator closes one (own_device_session_closed)
            }
        }
        self.start_own_device_sync(id, remote);
        true
    }

    /// The race's loser with one of our devices: its exchange stops (partial copies stay) and it closes.
    fn supersede_own_device(&mut self, id: u64) {
        self.stop_exchange(id);
        if let Some(session) = self.sessions.map.get_mut(&id) {
            session.meta.superseded = true;
        }
        self.close(id, CloseReason::Superseded);
    }

    /// The sync with `remote` runs on session `id` from now on.
    fn start_own_device_sync(&mut self, id: u64, remote: [u8; 32]) {
        self.devices.links.insert(remote, id);
        self.devices.dial_after.remove(&remote);
        // Our chain first, so a device that missed an addition or a removal hears it before any event.
        if let Some(chain) = devices::own_chain(self.store.connection()).ok().flatten() {
            self.send_on(id, &Frame::new(FrameType::Chain).with(tag::CHAIN, chain.encoded().to_vec()));
        }
        let mut exchange = SyncExchange::new(remote);
        exchange.set_fast(self.fast_session(id), self.copies_by_blocks);
        // Copies by blocks are pulled from every holder at once (pulls.rs), not by this exchange.
        exchange.set_pulled(self.pulls_copies(id));
        self.devices.engine.capture_local_changes(&self.store);
        exchange.start(&self.devices.engine, &self.store);
        self.devices.exchanges.insert(id, exchange);
        self.flush_exchange(id);
        self.reconsider_pulls();
        self.changed();
    }

    /// CHAIN and SYNC on a session with another of our devices; `false` for anything else.
    pub(crate) fn own_device_frame(&mut self, id: u64, frame: &Frame) -> bool {
        if !self.devices.exchanges.contains_key(&id) {
            return false;
        }
        match frame.frame_type {
            FrameType::Chain => self.own_chain_frame(id, frame.get(tag::CHAIN).unwrap_or_default()),
            FrameType::Sync => {
                let message = frame.get(tag::SYNC).unwrap_or_default().to_vec();
                // A holder's answer to a pull from several holders (pulls.rs).
                if let Some((transfer, answer)) = crate::service::pulls::sync_pull_message(&message) {
                    if self.pull_message(id, &transfer, answer) {
                        return true;
                    }
                }
                // More blocks of a file already served by blocks on this session (a pull asks bit by bit): the same
                // serve takes them; its tree and leaves go again, for a requester that started over.
                use szfriends_core::transfer::copies::CopyMessage;
                if let Some(CopyMessage::WantBlocks { id: transfer, ranges, shift }) =
                    CopyMessage::decode_sync(&message)
                {
                    if let Some(serving) = self.again.serving.get_mut(&(id, transfer.clone())) {
                        if serving.serve.geometry().shift == shift && serving.serve.want(&ranges).is_ok() {
                            let (hashes, root) = (serving.serve.hashes_frames(), serving.root);
                            if let Some(bytes) = (CopyMessage::BlocksFollow { id: transfer, root, shift }).encode_sync()
                            {
                                self.send_on(id, &Frame::new(FrameType::Sync).with(tag::SYNC, bytes));
                            }
                            for frame in hashes {
                                self.send_on(id, &frame);
                            }
                            return true;
                        }
                    }
                }
                let exchange = self.devices.exchanges.get_mut(&id).expect("checked");
                let result = exchange.receive(&mut self.devices.engine, &self.store, &message);
                self.flush_exchange(id);
                if let Err(error) = result {
                    let left = error == SyncError::Inactive;
                    log!("sync with one of our devices {}: {error}", if left { "ended" } else { "failed" });
                    self.close(id, if left { CloseReason::Normal } else { CloseReason::ProtocolError });
                }
                self.notice_own_devices_change();
            }
            _ => return false,
        }
        true
    }

    fn own_chain_frame(&mut self, id: u64, data: &[u8]) {
        let conn = self.store.connection();
        // Removed already, this computer still reads its profile's chain.
        let root = self.own_root().or_else(|| devices::own_chain(conn).ok().flatten().map(|c| *c.root_key()));
        let chain = root.and_then(|r| DeviceChain::decode(data, Some(&r)).ok());
        let merged = chain.and_then(|c| devices::merge_own_chain(conn, &c).ok());
        let Some(merged) = merged else {
            log!("refused a chain from one of our devices");
            return self.close(id, CloseReason::ProtocolError);
        };
        if merged == ChainMerge::Changed {
            self.notice_own_devices_change();
        }
        let remote = self.devices.exchanges.get(&id).map(|e| *e.peer_key());
        if self.removed_computer() || !remote.is_some_and(|r| self.is_own_device(&r)) {
            // This computer, or the one at the other end, was removed from the profile: the session ends here.
            self.close(id, CloseReason::Normal);
        }
    }

    /// What every exchange has to say after the engine changed.
    pub(crate) fn pump_sync(&mut self) {
        let ids: Vec<u64> = self.devices.exchanges.keys().copied().collect();
        for id in ids {
            if let Some(exchange) = self.devices.exchanges.get_mut(&id) {
                exchange.pump(&mut self.devices.engine, &self.store);
            }
            self.flush_exchange(id);
        }
    }

    /// What an exchange has to send now (`again.rs` calls it after a copy by blocks moved).
    pub(crate) fn flush_own_exchange(&mut self, id: u64) {
        self.flush_exchange(id);
    }

    fn flush_exchange(&mut self, id: u64) {
        let messages = self.devices.exchanges.get_mut(&id).map(SyncExchange::take_messages).unwrap_or_default();
        for message in messages {
            self.send_on(id, &Frame::new(FrameType::Sync).with(tag::SYNC, message));
        }
        // Copies by blocks (ADR 0018 § 4): HAVEs for ours, and files the other device asked for by blocks.
        let frames = self.devices.exchanges.get_mut(&id).map(SyncExchange::take_frames).unwrap_or_default();
        for frame in frames {
            self.send_on(id, &frame);
        }
        let served = self.devices.exchanges.get_mut(&id).map(SyncExchange::take_serve_blocks).unwrap_or_default();
        for blocks in served {
            for frame in blocks.serve.hashes_frames() {
                self.send_on(id, &frame);
            }
            let serving = crate::service::again::Serving {
                serve: blocks.serve,
                path: blocks.path,
                sync: true,
                root: blocks.root,
            };
            self.again.serving.insert((id, blocks.transfer_id), serving);
        }
        if !self.devices.engine.take_changes().is_empty() {
            // Friends, chats and the profile another of our devices changed: tags, sessions, the outbox follow.
            self.people_changed();
        }
        if self.devices.engine.take_new_events() {
            let others: Vec<u64> = self.devices.exchanges.keys().copied().filter(|o| *o != id).collect();
            for other in others {
                if let Some(exchange) = self.devices.exchanges.get_mut(&other) {
                    exchange.pump(&mut self.devices.engine, &self.store);
                }
                let messages = self.devices.exchanges.get_mut(&other).map(SyncExchange::take_messages);
                for message in messages.unwrap_or_default() {
                    self.send_on(other, &Frame::new(FrameType::Sync).with(tag::SYNC, message));
                }
            }
        }
    }

    /// Every session with our devices hears our chain now (a rename, a removal).
    pub(crate) fn send_own_chain_to_devices(&mut self) {
        let Some(chain) = devices::own_chain(self.store.connection()).ok().flatten() else { return };
        let ids: Vec<u64> = self.devices.exchanges.keys().copied().collect();
        for id in ids {
            self.send_on(id, &Frame::new(FrameType::Chain).with(tag::CHAIN, chain.encoded().to_vec()));
        }
        self.pump_sync();
    }

    fn stop_exchange(&mut self, id: u64) {
        if let Some(mut exchange) = self.devices.exchanges.remove(&id) {
            exchange.stop();
            let peer = *exchange.peer_key();
            if self.devices.links.get(&peer) == Some(&id) {
                self.devices.links.remove(&peer);
            }
        }
    }

    /// A session ended: its exchange stops, its partial copies stay for the next one.
    pub(crate) fn own_device_session_closed(&mut self, id: u64) {
        let Some(peer) = self.devices.exchanges.get(&id).map(|e| *e.peer_key()) else { return };
        self.stop_exchange(id);
        // The responder's copy of a double dial takes over at once, as a friend's standby session does.
        let standby = self.sessions.map.iter().find(|(other, s)| {
            **other != id
                && s.meta.live
                && !s.meta.superseded
                && !s.channel.is_closed()
                && s.channel.pattern() == Pattern::IK
                && s.channel.remote_identity() == Some(&peer)
                && !self.devices.exchanges.contains_key(other)
        });
        if let Some((other, _)) = standby {
            let other = *other;
            if self.is_own_device(&peer) && self.sync_active() {
                self.start_own_device_sync(other, peer);
            }
        }
        self.schedule_reconsider();
    }

    /// Our devices as the store lists them changed (one joined, was renamed or removed): matched, advertised, admitted
    /// and dialed anew; sessions with a computer no longer ours end after the chain reached it.
    pub(crate) fn own_devices_changed(&mut self) {
        self.devices.known = self.own_devices_fingerprint();
        if self.removed_computer() && self.online.take().is_some() {
            log!("this computer was removed from its profile: it reads, and sends nothing");
        }
        if self.sync_active() {
            let _ = self.devices.engine.ensure_own_devices_secret(&self.store);
            // You, as soon as the profile has a second computer (SZFriendsNearbyService+Devices.m does the same).
            let _ = szfriends_core::store::sync_history::ensure_you_conversation(self.store.connection());
        }
        let gone: Vec<u64> = self
            .devices
            .exchanges
            .iter()
            .filter(|(_, e)| !self.is_own_device(e.peer_key()))
            .map(|(id, _)| *id)
            .collect();
        for id in gone {
            self.stop_exchange(id);
            self.close_after(id, 2.0);
        }
        // Friends connected now hear of a computer added, removed or renamed at once (chain.rs).
        self.send_chain_to_friends();
        self.rebuild_matcher();
        self.refresh_advertisement();
        self.changed();
    }

    fn own_devices_fingerprint(&self) -> String {
        let me = self.identity.public_key();
        let mut known = format!("{}|", self.removed_computer());
        let root = self.own_root();
        for device in root.and_then(|r| devices::devices_of_root(self.store.connection(), &r).ok()).unwrap_or_default()
        {
            known.push_str(&format!("{}:{}:{};", hex(&device.device_key), device.state as i64, device.name));
        }
        if root.is_none() {
            known.push_str(&hex(&me));
        }
        known
    }

    pub(crate) fn notice_own_devices_change(&mut self) {
        if self.own_devices_fingerprint() != self.devices.known {
            self.own_devices_changed();
        }
    }

    /// From every change, at most once per `CAPTURE_DELAY`: what changed in the store becomes events while a session
    /// can carry them.
    pub(crate) fn schedule_sync_capture(&mut self) {
        if self.devices.capture_at.is_none() {
            self.devices.capture_at = Some(unix_now() + CAPTURE_DELAY);
        }
    }

    pub(crate) fn sync_tick(&mut self, now: f64) {
        if self.devices.capture_at.is_none_or(|at| at > now) {
            return;
        }
        self.devices.capture_at = None;
        self.notice_own_devices_change();
        if !self.devices.exchanges.is_empty() && self.devices.engine.capture_local_changes(&self.store) > 0 {
            self.pump_sync();
        }
    }
}

/// Whether online asks `device` (another of our devices, whose live session if any runs on `live`) for a session: while
/// no session with it ranks before a direct Internet connection, whichever of the two keys sorts first.
#[cfg_attr(not(feature = "online"), allow(dead_code))]
fn reach_online(_me: &[u8; 32], _device: &[u8; 32], live: Option<RouteMethod>) -> bool {
    live.is_none_or(|route| szfriends_core::nearby::is_better(RouteMethod::Internet, route))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_computer_asks_online_until_a_route_as_good_as_direct_carries_the_sync() {
        let (first, second) = ([1; 32], [2; 32]);
        assert!(reach_online(&first, &second, None));
        // The computer whose key sorts after the other's asks too: the Mac it just joined may be waiting out a backoff.
        assert!(reach_online(&second, &first, None), "the later key asks too");
        assert!(reach_online(&second, &first, Some(RouteMethod::Relay)), "the relay: a direct connection may come");
        assert!(!reach_online(&first, &second, Some(RouteMethod::Internet)));
        assert!(!reach_online(&second, &first, Some(RouteMethod::Lan)));
    }
}

//! The sync exchanges with the person's own computers (own.rs): pumped after the engine changes, flushed, stopped
//! when their session closes, and the chain and sync work a change to the person's devices starts.

use super::*;

impl State {
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

    pub(super) fn flush_exchange(&mut self, id: u64) {
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

    pub(super) fn stop_exchange(&mut self, id: u64) {
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

    pub(super) fn own_devices_fingerprint(&self) -> String {
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

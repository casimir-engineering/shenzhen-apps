//! One person's devices in the Rust peer, as the helper's nearby service drives them (`SZFriendsNearbyService+Join.m`,
//! `+Sync.m`): joining over NN with JOIN frames (the request, the approver's code, CPace, the welcome), and between
//! own devices CHAIN first and then the sync exchange over SYNC frames on IK. The Objective-C peer answers the same
//! commands with the helper's own classes (`tools/objc-session-peer/SZFSessionPeerDevices.m`). Joining's messages are
//! `devices_join.rs`.

use std::collections::HashMap;
use std::sync::Arc;

use serde_json::{json, Value};
use szfriends_core::identity::chain::{DeviceChain, DeviceState};
use szfriends_core::identity::join::{Approval, Approver, Attempt, Joiner};
use szfriends_core::identity::Identity;
use szfriends_core::session::monotonic_now;
use szfriends_core::store::sync_records::{self, Picture};
use szfriends_core::store::{devices, unix_now, Direction, Item, ItemKind};
use szfriends_core::sync::{self, SyncEngine, SyncExchange};
use szfriends_core::wire::{tag, CloseReason, Frame, FrameType, Pattern};

use crate::hex_bytes;
use crate::peer::State;

/// What a session dialed for joining does once it is live.
enum JoinDial {
    Request,
    Code(String),
}

pub(crate) struct Devices {
    pub(crate) identity: Arc<Identity>,
    pub(crate) engine: SyncEngine,
    pub(crate) approver: Approver,
    pub(crate) joiner: Option<Joiner>,
    dials: HashMap<u64, JoinDial>,
    pub(crate) attempts: HashMap<u64, Attempt>,
    pub(crate) approvals: HashMap<u64, Approval>,
    pub(crate) exchanges: HashMap<u64, SyncExchange>,
}

impl Devices {
    pub(crate) fn new(identity: &Identity, home: &std::path::Path) -> Self {
        let identity = Arc::new(Identity::from_secret_item(&identity.secret_item()).expect("its own item"));
        Self {
            engine: SyncEngine::new(identity.clone(), home.join("received")),
            approver: Approver::new(identity.clone()),
            identity,
            joiner: None,
            dials: HashMap::new(),
            attempts: HashMap::new(),
            approvals: HashMap::new(),
            exchanges: HashMap::new(),
        }
    }
}

fn key(value: &Value) -> Option<[u8; 32]> {
    value.as_str().and_then(hex_bytes).and_then(|b| b.try_into().ok())
}

pub(crate) fn join_frame(message: Vec<u8>) -> Frame {
    Frame::new(FrameType::Join).with(tag::JOIN, message)
}

impl State {
    pub(crate) fn own_root(&self) -> Option<[u8; 32]> {
        devices::root_for_device(self.store.connection(), &self.devices.identity.public_key()).ok().flatten()
    }

    /// The key policy admits our own devices over IK.
    pub(crate) fn refresh_own_devices(&mut self) {
        let me = self.devices.identity.public_key();
        let own: Vec<[u8; 32]> = self
            .own_root()
            .and_then(|root| devices::devices_of_root(self.store.connection(), &root).ok())
            .unwrap_or_default()
            .into_iter()
            .filter(|d| d.state == DeviceState::Authorized && d.device_key != me)
            .map(|d| d.device_key)
            .collect();
        self.set_own_devices(own);
    }

    pub(crate) fn send_on(&mut self, id: u64, frame: &Frame) {
        if let Some(session) = self.sessions.get_mut(&id) {
            session.channel.send_frame(frame, monotonic_now());
        }
    }

    pub(crate) fn close(&mut self, id: u64, reason: CloseReason) {
        if let Some(session) = self.sessions.get_mut(&id) {
            session.channel.close_with_reason(reason, monotonic_now());
        }
    }

    pub(crate) fn device_command(&mut self, name: &str, command: &Value) -> Option<Value> {
        let conn = self.store.connection();
        let now = unix_now();
        Some(match name {
            "set_profile" => {
                let picture = Picture::placeholder();
                sync_records::set_profile(conn, command["name"].as_str(), &picture).ok()?;
                let id = command["friends_id"].as_str().map_or(rusqlite::types::Value::Null, |s| s.to_owned().into());
                sync_records::set_profile_value(conn, "friends_id", id).ok()?;
                if sync_records::own_presence_secret(conn).ok()?.is_none() {
                    let mut secret = [0u8; 32];
                    szfriends_core::crypto::random_bytes(&mut secret);
                    sync_records::set_own_presence_secret(conn, Some(&secret)).ok()?;
                }
                json!({})
            }
            "device_genesis" => {
                let (name, system) = (command["name"].as_str()?, command["system"].as_str()?);
                let chain = devices::own_chain_creating_genesis(conn, &self.devices.identity, name, system).ok()?;
                json!({ "root": hex::encode(chain.root_key()) })
            }
            "join_start" => {
                let joiner = Joiner::new(
                    self.devices.identity.clone(),
                    command["friends_id"].as_str()?,
                    command["name"].as_str()?,
                    command["system"].as_str()?,
                    None,
                );
                let request_id = hex::encode(joiner.request_id());
                self.devices.joiner = Some(joiner);
                json!({ "request_id": request_id })
            }
            "join_send_request" | "join_code" => {
                let reply = self.dial(&json!({ "port": command["port"], "pattern": "NN" }));
                let id = reply["session"].as_u64()?;
                let dial = match command["code"].as_str() {
                    Some(code) => JoinDial::Code(code.to_owned()),
                    None => JoinDial::Request,
                };
                self.devices.dials.insert(id, dial);
                reply
            }
            "join_approve" => {
                devices::own_chain_creating_genesis(conn, &self.devices.identity, "Rust device", "Linux").ok()?;
                let request: [u8; 16] = command["request_id"].as_str().and_then(hex_bytes)?.try_into().ok()?;
                json!({ "code": self.devices.approver.approve(&request, now) })
            }
            "sync_dial" => {
                let device = key(&command["device_key"])?;
                let root = self.own_root()?;
                let static_key = devices::static_key_for_device(conn, &device, &root).ok()??;
                self.dial(&json!({
                    "port": command["port"], "pattern": "IK", "remote_static": hex::encode(static_key),
                    "expected_identity": hex::encode(device),
                }))
            }
            "add_message" => {
                let person = self.store.person_with_identity_key(&key(&command["identity_key"])?).ok()??;
                let at = command["at"].as_f64().unwrap_or(now);
                let direction = if command["direction"] == "out" { Direction::Outgoing } else { Direction::Incoming };
                let item = Item {
                    item_id: command["id"].as_str()?.to_owned(),
                    conversation_id: person.conversation_id,
                    kind: ItemKind::Message,
                    direction,
                    text: command["text"].as_str().map(str::to_owned),
                    transfer_id: None,
                    sent_at: at,
                    received_at: at,
                    via_assistant: false,
                };
                json!({ "inserted": self.store.insert_item(&item).ok()? })
            }
            "erase_history" => {
                let person = self.store.person_with_identity_key(&key(&command["identity_key"])?).ok()??;
                let result = self.devices.engine.delete_history(&self.store, Some(&person.conversation_id));
                self.pump_all();
                json!({ "ok": result.is_ok() })
            }
            "revoke_device" => {
                let device = key(&command["device_key"])?;
                let chain = devices::own_chain(conn).ok()??;
                let revoked = chain.revoking(&device, &self.devices.identity, now).ok()?;
                devices::merge_own_chain(conn, &revoked).ok()?;
                let recorded = self.devices.engine.record_revocation(&self.store, &device).is_ok();
                self.refresh_own_devices();
                let ids: Vec<u64> = self.devices.exchanges.keys().copied().collect();
                for id in ids {
                    self.send_on(id, &Frame::new(FrameType::Chain).with(tag::CHAIN, revoked.encoded().to_vec()));
                }
                self.pump_all();
                json!({ "recorded": recorded })
            }
            "capture" => {
                let count = self.devices.engine.capture_local_changes(&self.store);
                self.pump_all();
                json!({ "captured": count })
            }
            "device_state" => self.device_state(),
            _ => return None,
        })
    }

    fn device_state(&self) -> Value {
        let conn = self.store.connection();
        let me = self.devices.identity.public_key();
        let chain = devices::own_chain(conn).ok().flatten();
        let devices: Vec<Value> = chain
            .as_ref()
            .map(|c| {
                c.devices()
                    .iter()
                    .map(|d| {
                        json!({ "key": hex::encode(d.device_key), "state": d.state as i64,
                "name": d.name })
                    })
                    .collect()
            })
            .unwrap_or_default();
        let mut people = Vec::new();
        for person in self.store.people_by_latest_interaction().unwrap_or_default() {
            let mut statement = conn
                .prepare(
                    "SELECT body FROM messages WHERE conversation_id = ?1 AND kind = 0 ORDER BY received_at, item_id",
                )
                .expect("a query");
            let texts: Vec<String> = statement
                .query_map([&person.conversation_id], |r| r.get::<_, Option<String>>(0))
                .expect("rows")
                .filter_map(|r| r.ok().flatten())
                .collect();
            people.push(json!({
                "identity_key": person.identity_key.map(hex::encode), "name": person.name,
                "relation": person.relation as i64, "messages": texts,
            }));
        }
        let profile = sync_records::profile(conn).ok().and_then(|(name, _)| name);
        json!({
            "root": chain.as_ref().map(|c| hex::encode(c.root_key())),
            "removed": chain.as_ref().is_some_and(|c| c.revokes(&me)),
            "devices": devices, "people": people, "profile_name": profile,
        })
    }

    /// Sends what every exchange has to say after the engine changed.
    fn pump_all(&mut self) {
        let ids: Vec<u64> = self.devices.exchanges.keys().copied().collect();
        for id in ids {
            if let Some(exchange) = self.devices.exchanges.get_mut(&id) {
                exchange.pump(&mut self.devices.engine, &self.store);
            }
            self.flush_exchange(id);
        }
    }

    fn flush_exchange(&mut self, id: u64) {
        let messages = self.devices.exchanges.get_mut(&id).map(SyncExchange::take_messages).unwrap_or_default();
        for message in messages {
            self.send_on(id, &Frame::new(FrameType::Sync).with(tag::SYNC, message));
        }
        if !self.devices.engine.take_changes().is_empty() {
            self.emit(json!({ "event": "sync_changed" }));
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

    pub(crate) fn devices_established(&mut self, id: u64) {
        let Some(session) = self.sessions.get(&id) else { return };
        let (pattern, remote) = (session.channel.pattern(), session.channel.remote_identity().copied());
        let hash = session.channel.handshake_hash().map(|h| h.to_vec()).unwrap_or_default();
        match self.devices.dials.remove(&id) {
            Some(JoinDial::Request) => {
                let message = self.devices.joiner.as_ref().and_then(|j| j.request_message(unix_now()));
                match message {
                    Some(message) => self.send_on(id, &join_frame(message)),
                    None => self.close(id, CloseReason::Normal),
                }
                return;
            }
            Some(JoinDial::Code(code)) => {
                let attempt = self.devices.joiner.as_ref().and_then(|j| j.attempt(&code, &hash, None));
                match attempt {
                    Some(attempt) => {
                        self.send_on(id, &join_frame(attempt.code_message().to_vec()));
                        self.devices.attempts.insert(id, attempt);
                    }
                    None => self.close(id, CloseReason::Normal),
                }
                return;
            }
            None => {}
        }
        let own = remote.is_some_and(|r| self.own_root().is_some() && self.is_own_device(&r));
        if pattern != Pattern::IK || !own {
            return;
        }
        let chain = devices::own_chain(self.store.connection()).ok().flatten();
        if let Some(chain) = chain {
            self.send_on(id, &Frame::new(FrameType::Chain).with(tag::CHAIN, chain.encoded().to_vec()));
        }
        let mut exchange = SyncExchange::new(remote.expect("own"));
        self.devices.engine.capture_local_changes(&self.store);
        exchange.start(&self.devices.engine, &self.store);
        self.devices.exchanges.insert(id, exchange);
        self.flush_exchange(id);
        self.emit(json!({ "event": "sync_started", "session": id }));
    }

    fn is_own_device(&self, key: &[u8; 32]) -> bool {
        let root = self.own_root();
        *key != self.devices.identity.public_key()
            && root.is_some()
            && devices::root_for_device(self.store.connection(), key).ok().flatten() == root
    }

    pub(crate) fn devices_closed(&mut self, id: u64) {
        self.devices.dials.remove(&id);
        self.devices.attempts.remove(&id);
        if let Some(mut approval) = self.devices.approvals.remove(&id) {
            self.devices.approver.abandon(&mut approval, unix_now());
        }
        if let Some(mut exchange) = self.devices.exchanges.remove(&id) {
            exchange.stop();
        }
    }

    /// JOIN, CHAIN and SYNC frames; `false` for anything else.
    pub(crate) fn devices_frame(&mut self, id: u64, frame: &Frame) -> bool {
        match frame.frame_type {
            FrameType::Join => {
                let message = frame.get(tag::JOIN).unwrap_or_default().to_vec();
                let initiator = self.sessions.get(&id).is_some_and(|s| s.channel.is_initiator());
                if initiator {
                    self.joining_message(id, &message);
                } else {
                    self.approving_message(id, &message);
                }
                true
            }
            FrameType::Chain if self.devices.exchanges.contains_key(&id) => {
                self.own_chain_frame(id, frame.get(tag::CHAIN).unwrap_or_default());
                true
            }
            FrameType::Sync if self.devices.exchanges.contains_key(&id) => {
                let message = frame.get(tag::SYNC).unwrap_or_default().to_vec();
                let exchange = self.devices.exchanges.get_mut(&id).expect("checked");
                let result = exchange.receive(&mut self.devices.engine, &self.store, &message);
                self.flush_exchange(id);
                self.refresh_own_devices();
                self.check_removed(id);
                if let Err(error) = result {
                    let reason = if error == sync::SyncError::Inactive {
                        CloseReason::Normal
                    } else {
                        CloseReason::ProtocolError
                    };
                    self.emit(json!({ "event": "sync_error", "session": id, "error": error.to_string() }));
                    self.close(id, reason);
                }
                true
            }
            _ => false,
        }
    }

    fn own_chain_frame(&mut self, id: u64, data: &[u8]) {
        let conn = self.store.connection();
        let root = self.own_root().or_else(|| devices::own_chain(conn).ok().flatten().map(|c| *c.root_key()));
        let chain = root.and_then(|r| DeviceChain::decode(data, Some(&r)).ok());
        if chain.is_none_or(|c| devices::merge_own_chain(conn, &c).is_err()) {
            self.close(id, CloseReason::ProtocolError);
            return;
        }
        self.refresh_own_devices();
        self.check_removed(id);
    }

    /// This computer, or the one at the other end, was removed from the profile: the session ends here.
    fn check_removed(&mut self, id: u64) {
        let conn = self.store.connection();
        let me = self.devices.identity.public_key();
        let removed = devices::own_chain(conn).ok().flatten().is_some_and(|c| c.revokes(&me));
        let remote = self.devices.exchanges.get(&id).map(|e| *e.peer_key());
        let other_gone = remote.is_some_and(|r| !self.is_own_device(&r));
        if removed {
            self.emit(json!({ "event": "removed" }));
        }
        if removed || other_gone {
            self.close(id, CloseReason::Normal);
        }
    }
}

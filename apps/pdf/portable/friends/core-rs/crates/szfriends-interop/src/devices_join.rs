//! Joining in the Rust peer (`SZFriendsNearbyService+Join.m`): the approving device's side of JOIN frames on NN
//! responder sessions, and the new computer's, which ends with the profile's chain, profile and secrets adopted.

use serde_json::json;
use szfriends_core::identity::chain::DeviceChain;
use szfriends_core::identity::join::{self, Receipt, Step};
use szfriends_core::store::sync_records::{self, Picture};
use szfriends_core::store::{devices, unix_now};
use szfriends_core::sync::{self, Fields};
use szfriends_core::wire::{tag, CloseReason, Frame, FrameType};

use crate::devices::join_frame;
use crate::peer::State;

impl State {
    pub(crate) fn approving_message(&mut self, id: u64, message: &[u8]) {
        let conn = self.store.connection();
        let now = unix_now();
        let chain = devices::own_chain(conn).ok().flatten();
        let friends_id = match sync_records::profile_value(conn, "friends_id") {
            Ok(rusqlite::types::Value::Text(id)) => Some(id),
            _ => None,
        };
        match join::message_kind(message) {
            Some(join::MessageKind::Request) => {
                let receipt =
                    self.devices.approver.receive_request(message, friends_id.as_deref(), chain.as_ref(), now);
                if let Receipt::Ended(reason) = receipt {
                    self.send_on(id, &join_frame(join::ended_message(reason)));
                }
                if matches!(receipt, Receipt::Added | Receipt::Refreshed) {
                    let rows = self.devices.approver.open_requests(chain.as_ref(), now);
                    for row in rows {
                        self.emit(json!({ "event": "join_request", "request_id": hex::encode(row.request_id),
                            "name": row.name, "system": row.system }));
                    }
                }
                self.close(id, CloseReason::Normal);
            }
            Some(join::MessageKind::Code) => {
                let hash = self.sessions.get(&id).and_then(|s| s.channel.handshake_hash().copied());
                let (Some(chain), Some(hash)) = (chain, hash) else { return self.close(id, CloseReason::Normal) };
                match self.devices.approver.approval(message, &hash, chain.root_key(), now, None) {
                    Ok(approval) => {
                        self.send_on(id, &join_frame(approval.reply_message.clone()));
                        self.devices.approvals.insert(id, approval);
                    }
                    Err(reason) => {
                        if let Some(reason) = reason {
                            self.send_on(id, &join_frame(join::ended_message(reason)));
                        }
                        self.close(id, CloseReason::Normal);
                    }
                }
            }
            Some(join::MessageKind::Confirm) => {
                let approval = self.devices.approvals.remove(&id);
                let profile = self.welcome_profile();
                let state = match sync_records::profile_value(self.store.connection(), "friends_id_state") {
                    Ok(rusqlite::types::Value::Integer(state)) => state,
                    _ => 0,
                };
                let welcome = match (approval, chain, profile) {
                    (Some(mut approval), Some(chain), Some(profile)) => {
                        let welcome =
                            self.devices.approver.welcome(message, &mut approval, &chain, &profile, state, now);
                        welcome.map(|w| (w, approval.request_id))
                    }
                    _ => None,
                };
                let Some((welcome, request)) = welcome else { return self.close(id, CloseReason::Normal) };
                if devices::merge_own_chain(self.store.connection(), &welcome.chain).is_err() {
                    return self.close(id, CloseReason::Normal);
                }
                for part in welcome.parts {
                    self.send_on(id, &join_frame(part));
                }
                self.devices.approver.finish(&request);
                self.refresh_own_devices();
                self.emit(json!({ "event": "join_approved" }));
            }
            _ => self.close(id, CloseReason::Normal),
        }
    }

    /// The PROFILE friends receive, the presence secret and the own-devices secret.
    fn welcome_profile(&self) -> Option<Vec<u8>> {
        let conn = self.store.connection();
        let (name, _) = sync_records::profile(conn).ok()?;
        let mut frame = Frame::new(FrameType::Profile);
        if let Some(name) = name {
            frame = frame.with(tag::NAME, name.into_bytes());
        }
        if let Ok(rusqlite::types::Value::Text(id)) = sync_records::profile_value(conn, "friends_id") {
            frame = frame.with(tag::FRIENDS_ID, id.into_bytes());
        }
        let presence = sync_records::own_presence_secret(conn).ok()??;
        let devices_secret = sync::own_devices_secret_in_store(&self.store, true)?;
        let mut fields = Fields::new();
        fields.set_data(1, Some(&frame.encode().ok()?));
        fields.set_data(2, Some(&presence));
        fields.set_data(3, Some(&devices_secret));
        Some(fields.encode())
    }

    pub(crate) fn joining_message(&mut self, id: u64, message: &[u8]) {
        let Some(attempt) = self.devices.attempts.get_mut(&id) else {
            if let Some(reason) = join::end_reason(message) {
                self.emit(json!({ "event": "join_ended", "reason": reason as u8 }));
            }
            return self.close(id, CloseReason::Normal);
        };
        match attempt.receive(message) {
            Step::Send(reply) => self.send_on(id, &join_frame(reply)),
            Step::Wait => {}
            Step::Joined { chain, profile, friends_id_state } => {
                self.devices.attempts.remove(&id);
                let joined = self.complete_join(&chain, &profile, friends_id_state);
                self.emit(json!({ "event": if joined { "joined" } else { "join_failed" },
                    "root": hex::encode(chain.root_key()) }));
                self.close(id, CloseReason::Normal);
            }
            other => {
                self.devices.attempts.remove(&id);
                self.emit(json!({ "event": "join_failed", "step": format!("{other:?}") }));
                self.close(id, CloseReason::Normal);
            }
        }
    }

    fn complete_join(&mut self, chain: &DeviceChain, profile: &[u8], state: u8) -> bool {
        let Some(welcome) = Fields::decode(profile) else { return false };
        let frame = welcome.data(1).and_then(|d| Frame::decode(d).ok()).filter(|f| f.frame_type == FrameType::Profile);
        let (presence, devices_secret) = (welcome.data(2), welcome.data(3));
        let name = frame.as_ref().and_then(|f| f.text(tag::NAME)).map(str::to_owned);
        let friends_id = frame.as_ref().and_then(|f| f.text(tag::FRIENDS_ID)).map(str::to_owned);
        let typed = self.devices.joiner.as_ref().map(|j| j.friends_id().to_owned());
        let conn = self.store.connection();
        let ok = friends_id.is_some()
            && friends_id == typed
            && presence.is_some_and(|p| p.len() == 32)
            && devices_secret.is_some_and(|d| d.len() == 32)
            && devices::adopt_own_chain(conn, chain, &self.devices.identity.public_key()).is_ok();
        if !ok {
            return false;
        }
        let _ = sync_records::set_profile(conn, name.as_deref(), &Picture::placeholder());
        let _ = sync_records::set_profile_value(conn, "friends_id", friends_id.expect("checked").into());
        let _ = sync_records::set_profile_value(conn, "friends_id_state", i64::from(state).into());
        let _ = sync_records::set_own_presence_secret(conn, presence);
        sync::adopt_own_devices_secret(&self.store, devices_secret.expect("checked"));
        self.devices.joiner = None;
        self.refresh_own_devices();
        true
    }
}

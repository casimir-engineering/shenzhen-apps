//! Files on another of the person's computers in the Rust helper (`SZFriendsNearbyService+Devices.m` § Files): which
//! files another computer holds and this one does not, whether the copy is running, and Get (`fetch_from_device`).
//! A file the person moved or deleted here is one this computer does not hold either (ADR 0016).

use std::collections::BTreeMap;

use szfriends_core::presentation::DeviceFileFacts;
use szfriends_core::store::sync_files;
use szfriends_core::sync::{copies_automatically, local_path_of_transfer};

use super::devices::local_device_name;
use super::State;

impl State {
    /// Files another authorized computer of ours holds whose bytes are not here: never here, or moved or deleted
    /// here. `names` names the profile's computers.
    pub(crate) fn device_file_facts(&self, names: &BTreeMap<[u8; 32], String>) -> BTreeMap<String, DeviceFileFacts> {
        let conn = self.store.connection();
        let mut copying = BTreeMap::new();
        for exchange in self.devices.exchanges.values() {
            if let Some((transfer, fraction)) = exchange.copying() {
                copying.insert(transfer.to_owned(), fraction);
            }
        }
        let mut files = BTreeMap::new();
        for file in sync_files::sync_files(conn).unwrap_or_default() {
            let row = sync_files::transfer(conn, &file.transfer_id).ok().flatten();
            if row.as_ref().is_some_and(|t| local_path_of_transfer(self.store.state_dir(), t).is_some()) {
                continue;
            }
            // A holder that is connected now, else the first.
            let (mut holder, mut connected) = (None, false);
            for key in file.holders.iter().filter(|k| self.is_own_device(k)) {
                let live = self.own_device_live_link(key).is_some();
                if holder.is_none() || (live && !connected) {
                    holder = Some(*key);
                }
                connected = connected || live;
            }
            let Some(holder) = holder else { continue };
            // What the person moved or deleted here copies only after Get.
            let fetching = self.devices.engine.is_file_requested(&self.store, &file.transfer_id)
                || (row.is_none() && copies_automatically(file.size, &file.conversation_id));
            let facts = DeviceFileFacts {
                device_name: names.get(&holder).cloned().unwrap_or_else(local_device_name),
                fetching,
                holder_connected: connected,
                fraction: copying.get(&file.transfer_id).copied().unwrap_or(0.0),
            };
            files.insert(file.transfer_id, facts);
        }
        files
    }

    /// Get: copy here a file another of our computers holds. Allowed while its bytes are not here (never copied, or
    /// moved or deleted here); the computer holding it is reached nearby or online.
    pub fn fetch_from_device(&mut self, transfer_id: &str) -> Result<(), &'static str> {
        if self.removed_computer() {
            return Err("not_allowed");
        }
        let conn = self.store.connection();
        let row = sync_files::transfer(conn, transfer_id).ok().flatten();
        if row.is_some_and(|t| local_path_of_transfer(self.store.state_dir(), &t).is_some()) {
            return Err("not_allowed");
        }
        let file = sync_files::sync_file(conn, transfer_id).ok().flatten().ok_or("not_found")?;
        if !file.holders.iter().any(|h| self.is_own_device(h)) {
            return Err("not_found");
        }
        self.devices.engine.request_file(&self.store, transfer_id).map_err(|_| "internal")?;
        self.pump_sync();
        // The computer holding it is dialed, nearby or online.
        self.schedule_reconsider();
        self.changed();
        Ok(())
    }

    /// Cancel after Get: the copy stops; what arrived waits for another Get. `false` when nothing was asked.
    pub(crate) fn cancel_fetch_from_device(&mut self, transfer_id: &str) -> bool {
        if !self.devices.engine.is_file_requested(&self.store, transfer_id) {
            return false;
        }
        let _ = self.devices.engine.cancel_file_request(&self.store, transfer_id);
        self.pump_sync();
        self.changed();
        true
    }
}

//! One profile on several computers in the Rust helper (`SZFriendsNearbyService+Devices.m`, `+Join.m`): what Your
//! computers, the join rows, the `join` view and files on another computer show, read from the store's chain, the
//! sync engine and the join state; and the intents that change them (approve, deny, start or cancel joining, type a
//! code, remove or rename a computer, Get a file).
//!
//! Joining and sync ride the routes friends use: nearby in every home, online where this helper is online
//! (`nearby/join.rs`, `nearby/own.rs`).

use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use szfriends_core::identity::chain::{chain_label, DeviceState, NAME_MAX};
use szfriends_core::identity::join::{normalized_code, Approval, Approver, Attempt, Joiner, RequestState};
use szfriends_core::identity::Identity;
use szfriends_core::presentation::{
    DeviceFacts, DevicesFacts, JoinRequestFacts, JoiningFacts, JoiningState, PersonFacts,
};
use szfriends_core::store::devices;
use szfriends_core::store::sync_history;
use szfriends_core::store::sync_log::YOU;
use szfriends_core::store::unix_now;
use szfriends_core::sync::{SyncEngine, SyncExchange};

use super::{hex, State};
use szfriends_core::wire::RouteMethod;

/// "d_" and the first 8 bytes of the device key, as the helper names a computer to its views.
pub fn device_id(key: &[u8; 32]) -> String {
    format!("d_{}", hex(&key[..8]))
}

static DEVICE_NAME: std::sync::OnceLock<String> = std::sync::OnceLock::new();

/// A phone's own name, as its system gives it (the app sets it before Friends starts): what the person's other
/// computers call it ("On Pixel 9"), where a computer's comes from its host name.
pub fn set_local_device_name(name: &str) {
    let label = chain_label(name, NAME_MAX);
    if !label.is_empty() {
        let _ = DEVICE_NAME.set(label);
    }
}

/// The local computer's name and system, for a chain's first link.
pub fn local_device_name() -> String {
    if let Some(name) = DEVICE_NAME.get() {
        return name.clone();
    }
    let name = std::env::var("COMPUTERNAME").or_else(|_| std::env::var("HOSTNAME")).unwrap_or_default();
    let label = chain_label(&name, NAME_MAX);
    if label.is_empty() {
        "Computer".to_owned()
    } else {
        label
    }
}

pub fn local_device_system() -> String {
    match std::env::consts::OS {
        "windows" => "Windows".to_owned(),
        "linux" => "Linux".to_owned(),
        "android" => "Android".to_owned(),
        "ios" => "iOS".to_owned(),
        other => other.to_owned(),
    }
}

/// How long a typed code waits for the approving computer to answer before the view says it was not reached.
pub const JOIN_CODE_WINDOW: f64 = 10.0;

/// What the service keeps of devices and joining between inputs.
pub struct DeviceArea {
    pub identity: Arc<Identity>,
    pub engine: SyncEngine,
    pub approver: Approver,
    pub joiner: Option<Joiner>,
    pub phase: JoiningState,
    pub code: Option<String>,
    /// Bumped by every request, code and end: what an earlier one left running does nothing.
    pub generation: u64,
    /// The code typed in this generation counts as not reached at this time.
    pub code_deadline: Option<(u64, f64)>,
    /// The new computer's runs of its code, by session.
    pub attempts: HashMap<u64, Attempt>,
    /// The approving computer's runs, by session.
    pub approvals: HashMap<u64, Approval>,
    /// Sessions with our other devices, each with its sync exchange; and which session carries which device.
    pub exchanges: HashMap<u64, SyncExchange>,
    pub links: HashMap<[u8; 32], u64>,
    /// Not dialed again before this time, by device.
    pub dial_after: HashMap<[u8; 32], f64>,
    /// Changes become events this soon while a session with another of our devices is live.
    pub capture_at: Option<f64>,
    /// A snapshot found a file moved or deleted here: the next capture tells our other devices (ADR 0016).
    pub missing_seen: std::cell::Cell<bool>,
    /// The device list last acted on, to notice a joined, renamed or removed computer.
    pub known: String,
    /// When the join rows change by themselves (a code or a request expires).
    pub refresh_at: Option<f64>,
    /// Joining's legs through the host, by number: which side, and the hash once established.
    pub pipes: HashMap<u64, JoinPipe>,
    /// The new computer's request last went to the host at this time; its code in this generation.
    #[cfg_attr(not(feature = "online"), allow(dead_code))]
    pub request_sent_online_at: Option<f64>,
    #[cfg_attr(not(feature = "online"), allow(dead_code))]
    pub code_sent_online: Option<u64>,
}

impl DeviceArea {
    pub fn new(identity: &Identity, received: std::path::PathBuf) -> Self {
        let identity = Arc::new(Identity::from_secret_item(&identity.secret_item()).expect("its own secret item"));
        Self {
            engine: SyncEngine::new(identity.clone(), received),
            approver: Approver::new(identity.clone()),
            identity,
            joiner: None,
            phase: JoiningState::Idle,
            code: None,
            generation: 0,
            code_deadline: None,
            attempts: HashMap::new(),
            approvals: HashMap::new(),
            exchanges: HashMap::new(),
            links: HashMap::new(),
            dial_after: HashMap::new(),
            capture_at: None,
            missing_seen: std::cell::Cell::new(false),
            known: String::new(),
            refresh_at: None,
            pipes: HashMap::new(),
            request_sent_online_at: None,
            code_sent_online: None,
        }
    }
}

/// One leg of a join run through the Friends host.
#[derive(Clone, Debug, Default)]
pub struct JoinPipe {
    #[cfg_attr(not(feature = "online"), allow(dead_code))]
    pub initiator: bool,
    pub hash: Vec<u8>,
}

/// Set once the host turned this computer away as removed (HOST-PROTOCOL.md § Devices; the Mac helper's key).
pub const REMOVED_BY_HOST: &str = "checkin_removed_by_host";
/// Set when this computer joins a profile, cleared once a host confirms the release of the Friends ID it had reserved
/// for itself before (the Mac helper's key; `szfriends_online::host::release`).
pub const PRE_JOIN_RELEASE: &str = "checkin_release_pre_join";

/// Whether the release of the ID from before joining is still owed.
#[cfg_attr(not(feature = "online"), allow(dead_code))]
pub fn release_owed(conn: &rusqlite::Connection) -> bool {
    szfriends_core::store::sync_log::state(conn, PRE_JOIN_RELEASE)
        .is_ok_and(|v| v == rusqlite::types::Value::Integer(1))
}

impl State {
    fn local_key(&self) -> [u8; 32] {
        self.identity.public_key()
    }

    /// Another of the person's computers removed this one: its chain says so, or the host did.
    pub fn removed_computer(&self) -> bool {
        let conn = self.store.connection();
        let by_host = szfriends_core::store::sync_log::state(conn, REMOVED_BY_HOST);
        devices::is_revoked_device(conn, &self.local_key()).unwrap_or(false)
            || by_host.is_ok_and(|v| v == rusqlite::types::Value::Integer(1))
    }

    /// Joining is offered to a computer with nobody in its list and no profile shared with another one.
    fn join_available(&self) -> bool {
        let people = self.store.people_by_latest_interaction().map(|p| p.is_empty()).unwrap_or(false);
        people && self.profile_here_only()
    }

    /// This computer's profile is on no other computer.
    fn profile_here_only(&self) -> bool {
        let chain = devices::own_chain(self.store.connection()).ok().flatten();
        chain.is_none_or(|c| c.devices().len() <= 1)
    }

    pub fn joining_facts(&self) -> JoiningFacts {
        let area = &self.devices;
        let mut state = area.phase;
        if state == JoiningState::Idle && !self.join_available() {
            state = JoiningState::Unavailable;
        }
        // What carries the join now: a session with another of our computers once joined (the sync), else a nearby
        // session running the code; the best of them in the owner's order.
        let joined = state == JoiningState::Joined;
        let carrying = self.sessions.map.values().filter(|s| {
            let ours = joined && s.channel.remote_identity().is_some_and(|k| self.is_own_device(k));
            let code = !joined && s.meta.purpose == super::nearby::Purpose::Join;
            (ours || code) && s.meta.live && !s.meta.superseded && !s.channel.is_closed()
        });
        let route = carrying.map(|s| s.meta.race_route(&s.channel)).fold(RouteMethod::None, |best, route| {
            if best == RouteMethod::None || szfriends_core::nearby::is_better(route, best) {
                route
            } else {
                best
            }
        });
        JoiningFacts {
            state,
            friends_id: area.joiner.as_ref().map(|j| j.friends_id().to_owned()),
            route: super::nearby::view_route(route),
        }
    }

    pub fn join_request_facts(&mut self, now: f64) -> Vec<JoinRequestFacts> {
        let chain = devices::own_chain(self.store.connection()).ok().flatten();
        let rows = self.devices.approver.open_requests(chain.as_ref(), now);
        self.devices.refresh_at = self.devices.approver.next_change_after(now);
        rows.into_iter()
            .map(|r| JoinRequestFacts {
                join_id: hex(&r.request_id),
                device_name: r.name,
                system: r.system,
                received_at: r.received_at,
                approved: r.state == RequestState::Approved,
                code: r.code,
                code_expires_at: r.code_expires_at,
            })
            .collect()
    }

    pub fn devices_facts(&self, now: f64, people: &[PersonFacts]) -> DevicesFacts {
        let conn = self.store.connection();
        let me = self.local_key();
        let root = devices::root_for_device(conn, &me)
            .ok()
            .flatten()
            .or_else(|| devices::own_chain(conn).ok().flatten().map(|c| *c.root_key()));
        let records = root.and_then(|r| devices::devices_of_root(conn, &r).ok()).unwrap_or_default();
        let mut this = DeviceFacts {
            device_id: device_id(&me),
            name: local_device_name(),
            system: local_device_system(),
            this_computer: true,
            connected: true,
            last_seen_at: None,
        };
        let mut others = Vec::new();
        for record in &records {
            if record.device_key == me {
                this.name = record.name.clone();
                this.system = record.system.clone();
            } else if record.state == DeviceState::Authorized {
                others.push(record);
            }
        }
        others.sort_by(|a, b| a.added_at.total_cmp(&b.added_at).then(a.device_key.cmp(&b.device_key)));
        let mut computers = vec![this];
        computers.extend(others.iter().map(|d| DeviceFacts {
            device_id: device_id(&d.device_key),
            name: d.name.clone(),
            system: d.system.clone(),
            this_computer: false,
            connected: self.own_device_live_link(&d.device_key).is_some(),
            last_seen_at: d.last_seen_at,
        }));
        let removed = self.removed_computer();
        // Files another of our computers holds: its bytes are there, its name says where (device_files.rs).
        let names: BTreeMap<[u8; 32], String> = records.iter().map(|d| (d.device_key, d.name.clone())).collect();
        let files = self.device_file_facts(&names);
        let you = people.iter().find(|p| p.conversation_id == YOU).cloned();
        let join_offered = !removed && self.join_available();
        let friends_id: Option<String> =
            conn.query_row("SELECT friends_id FROM profile WHERE id = 1", [], |r| r.get(0)).ok().flatten();
        DevicesFacts {
            now,
            join_offered,
            // Joining after Reset Friends: a profile here only, with people in it that joining would replace.
            join_replaces: !removed && !join_offered && self.profile_here_only(),
            friends_id,
            removed,
            // With other computers, or with something in it (the person's own notes stay reachable on one computer).
            you: you.filter(|you| computers.len() >= 2 || you.last_preview_item_id.is_some()),
            computers,
            files,
            ..DevicesFacts::default()
        }
    }

    /// approve_join, deny_join, join_profile, enter_join_code, cancel_join, revoke_device, rename_device,
    /// fetch_from_device: `Err` with the protocol's code.
    pub fn approve_join(&mut self, join_id: &str) -> Result<(), &'static str> {
        let request: [u8; 16] = super::unhex(join_id).and_then(|b| b.try_into().ok()).ok_or("not_found")?;
        let (name, system) = (local_device_name(), local_device_system());
        devices::own_chain_creating_genesis(self.store.connection(), &self.devices.identity, &name, &system)
            .map_err(|_| "not_found")?;
        self.devices.approver.approve(&request, unix_now()).map(|_| ()).ok_or("not_found")
    }

    pub fn deny_join(&mut self, join_id: &str) -> Result<(), &'static str> {
        let request: [u8; 16] = super::unhex(join_id).and_then(|b| b.try_into().ok()).ok_or("not_found")?;
        self.devices.approver.deny(&request, unix_now()).then_some(()).ok_or("not_found")
    }

    pub fn start_joining(&mut self, friends_id: &str) -> Result<(), &'static str> {
        let own = szfriends_core::store::sync_records::profile_value(self.store.connection(), "friends_id");
        if matches!(own, Ok(rusqlite::types::Value::Text(ref id)) if id == friends_id) {
            return Err("id_is_yours");
        }
        if !self.join_available() {
            return Err("not_allowed");
        }
        self.end_join_legs();
        let joiner =
            Joiner::new(self.devices.identity.clone(), friends_id, &local_device_name(), &local_device_system(), None);
        self.devices.joiner = Some(joiner);
        self.devices.phase = JoiningState::Waiting;
        self.devices.code = None;
        self.devices.generation += 1;
        self.schedule_reconsider();
        Ok(())
    }

    pub fn enter_join_code(&mut self, code: &str) -> Result<(), &'static str> {
        let phase = self.devices.phase;
        let waiting = matches!(phase, JoiningState::Waiting | JoiningState::WrongCode | JoiningState::NotReached);
        if self.devices.joiner.is_none() || !waiting {
            return Err("not_allowed");
        }
        self.devices.code = Some(normalized_code(code).ok_or("invalid_field")?);
        self.end_join_legs();
        self.devices.phase = JoiningState::Checking;
        self.devices.generation += 1;
        // Nobody answered within the window: no computer holding an approval was reachable.
        self.devices.code_deadline = Some((self.devices.generation, unix_now() + JOIN_CODE_WINDOW));
        self.schedule_reconsider();
        Ok(())
    }

    pub fn cancel_joining(&mut self) {
        self.end_join_legs();
        self.devices.joiner = None;
        self.devices.code = None;
        self.devices.generation += 1;
        if self.devices.phase != JoiningState::Joined {
            self.devices.phase = JoiningState::Idle;
        }
    }

    fn own_device_with_id(&self, device: &str) -> Option<szfriends_core::store::devices::DeviceRecord> {
        let conn = self.store.connection();
        let root = devices::root_for_device(conn, &self.local_key()).ok().flatten()?;
        devices::devices_of_root(conn, &root).ok()?.into_iter().find(|d| device_id(&d.device_key) == device)
    }

    pub fn revoke_device(&mut self, device: &str) -> Result<(), &'static str> {
        if self.removed_computer() || device == device_id(&self.local_key()) {
            return Err("not_allowed");
        }
        let target = self.own_device_with_id(device).filter(|d| d.state == DeviceState::Authorized);
        let target = target.ok_or("not_found")?;
        let conn = self.store.connection();
        let chain = devices::own_chain(conn).ok().flatten().ok_or("internal")?;
        let revoked = chain.revoking(&target.device_key, &self.devices.identity, unix_now()).map_err(|_| "internal")?;
        devices::merge_own_chain(conn, &revoked).map_err(|_| "internal")?;
        let _ = self.devices.engine.record_revocation(&self.store, &target.device_key);
        let _ = self.devices.engine.renew_secrets_after_revocation(&self.store);
        // Every session with our devices hears it first, the removed computer included.
        self.send_own_chain_to_devices();
        self.own_devices_changed();
        Ok(())
    }

    pub fn rename_device(&mut self, typed: &str) -> Result<(), &'static str> {
        if self.removed_computer() {
            return Err("not_allowed");
        }
        let name = typed.trim();
        if name.is_empty() || name.len() > NAME_MAX || name.chars().any(char::is_control) {
            return Err("name_invalid");
        }
        let conn = self.store.connection();
        let (system_name, system) = (local_device_name(), local_device_system());
        let held = devices::own_chain_creating_genesis(conn, &self.devices.identity, &system_name, &system)
            .map_err(|_| "internal")?;
        let me = held.device(&self.local_key()).ok_or("not_allowed")?.clone();
        if me.name == name {
            return Ok(());
        }
        let renamed = held.renaming(name, &me.system, &self.devices.identity, unix_now()).map_err(|_| "internal")?;
        devices::merge_own_chain(conn, &renamed).map_err(|_| "internal")?;
        self.send_own_chain_to_devices();
        self.own_devices_changed();
        Ok(())
    }

    /// Delete history (`None`: every chat). With other computers on this profile it is a deletion every one of them
    /// applies, which sync carries; otherwise it is this store's alone. Transfers whose rows went stop at once.
    pub fn delete_history(&mut self, conversation: Option<&str>) -> Result<(), &'static str> {
        let erased = if self.devices.engine.is_active(&self.store) {
            self.devices.engine.delete_history(&self.store, conversation).is_ok()
        } else {
            sync_history::delete_history(self.store.connection(), self.store.state_dir(), conversation).is_ok()
        };
        if !erased {
            return Err("internal");
        }
        let store = &self.store;
        let kept = |transfer: &String| store.transfer(transfer).ok().flatten().is_some();
        for session in self.sessions.map.values_mut() {
            session.senders.retain(|transfer, _| kept(transfer));
            session.receivers.retain(|transfer, _| kept(transfer));
        }
        self.pump_sync();
        self.changed();
        Ok(())
    }
}

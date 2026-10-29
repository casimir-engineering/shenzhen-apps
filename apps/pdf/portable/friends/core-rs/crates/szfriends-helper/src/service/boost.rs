//! ADR 0019's Wi-Fi Direct boost in the Rust helper: watches groups that run over Bluetooth alone, proposes the boost
//! for a large file, carries BOOST on the group's first session, asks the person where the device would lose its only
//! Internet, hosts or joins through the platform ([`crate::nearby::direct_wifi`]), dials or admits the link's lane, and
//! brings the device back to its own Wi-Fi network when it ends, after a crash at the next launch too. The decisions
//! are `szfriends_core::transfer::boost`'s.
//!
//! The host's lane listener is its own, bound to the link's address for the boost only; what arrives on it goes
//! through the ordinary admission and is admitted only as a lane of a live group (ADR 0018 § 6).

use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, SocketAddr, TcpListener};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use szfriends_core::nearby::Method;
use szfriends_core::presentation::facts::{BoostFacts, BoostStage, StaysOnline};
use szfriends_core::session::monotonic_now;
use szfriends_core::store::unix_now;
use szfriends_core::transfer::boost::{
    self, Boost, Cost, Effect, Estimate, Phase, Rejoin, RejoinEffect, Saved, Situation,
};
use szfriends_core::wire::{CloseReason, Frame, RouteMethod};

use super::nearby::{DialPlan, Purpose};
use super::{Input, State};
use crate::log;
use crate::nearby::direct_wifi::{self, DirectWifi};
use crate::nearby::Event;

/// The record of the network to come back to (ADR 0019 § 4), in the state directory.
pub const RECORD: &str = "direct-wifi.json";

/// One boost, by the group's first session.
struct Live {
    boost: Boost,
    transfer: String,
    estimate: Estimate,
    /// The direct lane, once up.
    lane: Option<u64>,
    listener: Option<Arc<AtomicBool>>,
}

#[derive(Default)]
struct Watch {
    bluetooth_since: Option<Instant>,
    network_failures: u32,
}

/// Everything the boost keeps between ticks.
pub struct BoostArea {
    platform: Option<Arc<dyn DirectWifi>>,
    boosts: HashMap<u64, Live>,
    watch: HashMap<u64, Watch>,
    /// Transfers a person said Not now to, on either side: never proposed again.
    declined: HashSet<String>,
    rejoin: Rejoin,
    /// The transfer whose row shows the way back, and how it went.
    after: Option<(String, BoostStage)>,
    /// The network it did not get back on, for the row's words once the record is gone.
    failed_name: Option<String>,
    record: PathBuf,
}

impl BoostArea {
    pub fn new(state_dir: &std::path::Path, test_home: bool) -> Self {
        Self {
            platform: direct_wifi::for_helper(state_dir, test_home),
            boosts: HashMap::new(),
            watch: HashMap::new(),
            declined: HashSet::new(),
            rejoin: Rejoin::default(),
            after: None,
            failed_name: None,
            record: state_dir.join(RECORD),
        }
    }

    /// Whether this helper sets capability bit 5: it can host or join.
    pub fn available(&self) -> bool {
        self.platform.is_some()
    }
}

fn transfer_bytes(transfer: &str) -> Option<[u8; 16]> {
    hex::decode(transfer).ok()?.try_into().ok()
}

impl State {
    /// At launch: a record left by a run that crashed or was killed away from its network brings it back first.
    pub(crate) fn boost_launched(&mut self) {
        let record = std::fs::read(&self.boost.record)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .and_then(|value| Saved::from_json(&value));
        if record.is_some() {
            log!("direct Wi-Fi: back to the network written down before the last run ended");
        }
        self.boost.rejoin = Rejoin::launched(record, monotonic_now());
        self.apply_rejoin();
    }

    /// Periodic work: proposals, lanes coming and going, rates, timeouts, the way back.
    pub(crate) fn boost_tick(&mut self) {
        let now = monotonic_now();
        if self.boost.platform.is_some() {
            self.watch_groups();
            self.follow_boosts(now);
        }
        self.boost.rejoin.tick(now);
        self.apply_rejoin();
    }

    /// The app quits: every boost ends, and the device goes back to its network (the record stays until a launch
    /// sees it back online).
    pub(crate) fn boost_quitting(&mut self) {
        let heads: Vec<u64> = self.boost.boosts.keys().copied().collect();
        for head in heads {
            self.with_boost(head, |boost, now| boost.quitting(now));
        }
    }

    /// The group's first session ended with no lane left to carry it.
    pub(crate) fn boost_group_ended(&mut self, head: u64) {
        self.boost.watch.remove(&head);
        self.with_boost(head, |boost, now| boost.session_lost(now));
        self.boost.boosts.remove(&head);
    }

    /// A lane took over from the first session: the boost follows the group.
    pub(crate) fn boost_group_moved(&mut self, from: u64, to: u64) {
        if let Some(live) = self.boost.boosts.remove(&from) {
            self.boost.boosts.insert(to, live);
        }
        if let Some(watch) = self.boost.watch.remove(&from) {
            self.boost.watch.insert(to, watch);
        }
    }

    /// A lane dial on the network failed: one of the network's chances (§ 1).
    pub(crate) fn boost_network_dial_failed(&mut self, head: u64) {
        self.boost.watch.entry(head).or_default().network_failures += 1;
    }

    /// BOOST from a friend.
    pub(crate) fn boost_frame(&mut self, id: u64, frame: &Frame) {
        let head = self.head_of(id);
        let Ok((transfer, message)) = boost::decode(frame) else {
            log!("direct Wi-Fi: a BOOST this side refuses");
            return;
        };
        let now = monotonic_now();
        let transfer_hex = hex::encode(transfer);
        if self.boost.boosts.contains_key(&head) {
            if let boost::Message::Decline { reason } = &message {
                if *reason == szfriends_core::wire::consts::boost_reason::NOT_NOW {
                    self.boost.declined.insert(transfer_hex);
                }
            }
            self.with_boost(head, |boost, now| boost.message(message, now));
            return;
        }
        let boost::Message::Propose { abilities: peer } = message else { return };
        let Some(platform) = self.boost.platform.clone() else { return };
        if self.boost.declined.contains(&transfer_hex) {
            let decline = boost::Message::Decline { reason: szfriends_core::wire::consts::boost_reason::NOT_NOW };
            self.send_on(head, &boost::encode(&transfer, &decline));
            return;
        }
        let sorts_first = self.sorts_first(head);
        let boost = Boost::proposed(transfer, platform.abilities(), peer, platform.connectivity(), sorts_first, now);
        let remaining = self.receiving_remaining(head, &transfer_hex);
        let live = Live {
            boost,
            transfer: transfer_hex,
            estimate: boost::estimate(remaining, 0.0),
            lane: None,
            listener: None,
        };
        self.boost.boosts.insert(head, live);
        self.with_boost(head, |_, _| {});
    }

    /// The person answered the question on a transfer's row.
    pub(crate) fn boost_answer(&mut self, transfer: &str, go_faster: bool) -> bool {
        let asking = |l: &Live| l.transfer == transfer && l.boost.phase() == Phase::Asking;
        let Some(head) = self.boost.boosts.iter().find(|(_, l)| asking(l)).map(|(h, _)| *h) else {
            return false;
        };
        if !go_faster {
            self.boost.declined.insert(transfer.to_owned());
        }
        self.with_boost(head, |boost, now| boost.answer(go_faster, now));
        true
    }

    /// `boost_transfer` and `skip_boost`: `stale` when the question is no longer there.
    pub(crate) fn answer_boost(&mut self, transfer: &str, go_faster: bool) -> super::intents::Answer {
        if self.boost_answer(transfer, go_faster) {
            Ok(serde_json::json!({}))
        } else {
            Err(szfriends_core::intents::IntentError::new("stale"))
        }
    }

    /// What a transfer's row says of the boost.
    pub(crate) fn boost_facts(&self, transfer: &str) -> BoostFacts {
        let device = self.boost.platform.as_ref().map(|p| p.device()).unwrap_or_default();
        let system_asks_too = self.boost.platform.as_ref().is_some_and(|p| p.system_asks_too());
        let network = self.boost.platform.as_ref().and_then(|p| p.connectivity().wifi_name);
        let mut facts = BoostFacts { device, system_asks_too, network, ..BoostFacts::default() };
        if let Some(live) = self.boost.boosts.values().find(|l| l.transfer == transfer) {
            facts.stage = match live.boost.phase() {
                Phase::Asking => BoostStage::Asking,
                Phase::Hosting | Phase::Joining => BoostStage::Connecting,
                Phase::Agreed if live.boost.role().is_some() => BoostStage::Connecting,
                Phase::Direct => BoostStage::Direct,
                _ => BoostStage::None,
            };
            facts.bluetooth_seconds = live.estimate.bluetooth_seconds;
            facts.direct_seconds = live.estimate.direct_seconds;
            match live.boost.cost() {
                Cost::Nothing => {}
                Cost::LeavesWifi { network, over_mobile } => {
                    facts.leaves_wifi = true;
                    facts.network = network.clone();
                    facts.stays_online = Some(if *over_mobile { StaysOnline::Mobile } else { StaysOnline::Ethernet });
                }
                Cost::LeavesInternet { network } => {
                    facts.leaves_wifi = true;
                    facts.network = network.clone();
                }
            }
            if facts.stage != BoostStage::None {
                return facts;
            }
        }
        if let Some((after, stage)) = &self.boost.after {
            if after == transfer {
                facts.stage = *stage;
                facts.network = match stage {
                    BoostStage::RejoinFailed => self.boost.failed_name.clone(),
                    _ => self.boost_saved_name(),
                }
                .or(facts.network);
            }
        }
        facts
    }

    fn boost_saved_name(&self) -> Option<String> {
        std::fs::read(&self.boost.record)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .and_then(|value| Saved::from_json(&value))
            .and_then(|saved| saved.network_name)
    }

    // ----- watching -----

    fn sorts_first(&self, head: u64) -> bool {
        let ours = self.identity.public_key();
        let theirs = self.sessions.map.get(&head).and_then(|s| s.channel.remote_identity().copied());
        theirs.is_none_or(|theirs| ours < theirs)
    }

    fn receiving_remaining(&self, head: u64, transfer: &str) -> u64 {
        let _ = head;
        self.store.transfer(transfer).ok().flatten().map_or(0, |t| t.size.saturating_sub(t.verified_bytes))
    }

    /// Each group sending by blocks over Bluetooth alone: propose once § 1 holds.
    fn watch_groups(&mut self) {
        let heads: Vec<u64> = self.sessions.groups.by_head.keys().copied().collect();
        self.boost.watch.retain(|head, _| heads.contains(head));
        for head in heads {
            let Some(group) = self.sessions.groups.by_head.get(&head) else { continue };
            let live: Vec<RouteMethod> = group.lanes.live().map(|(_, _, route)| route).collect();
            let bluetooth_only = !live.is_empty() && live.iter().all(|r| *r == RouteMethod::Bluetooth);
            let watch = self.boost.watch.entry(head).or_default();
            if !bluetooth_only {
                watch.bluetooth_since = None;
                continue;
            }
            let since = *watch.bluetooth_since.get_or_insert_with(Instant::now);
            let failures = watch.network_failures;
            if self.boost.boosts.contains_key(&head) {
                continue;
            }
            let Some(session) = self.sessions.map.get(&head) else { continue };
            if !session.channel.direct_wifi_boost() {
                continue;
            }
            let conversation = session.conversation.clone();
            let biggest = session
                .block_senders
                .iter()
                .filter(|(transfer, _)| !self.boost.declined.contains(*transfer))
                .map(|(transfer, send)| (transfer.clone(), send.serve.remaining_bytes()))
                .max_by_key(|(_, remaining)| *remaining);
            let Some((transfer, remaining)) = biggest else { continue };
            let seen_on_network = self.nearby.merger.candidates().iter().any(|c| {
                c.conversation_id.is_some()
                    && c.conversation_id == conversation
                    && c.sightings.iter().any(|s| s.method == Method::Network)
            });
            let situation = Situation {
                bluetooth_only,
                bluetooth_only_for: since.elapsed(),
                seen_on_network,
                network_failures: failures,
            };
            if !boost::not_on_same_network(&situation) {
                continue;
            }
            let rate = self
                .sessions
                .groups
                .schedules
                .get(&head)
                .map_or(0.0, |s| s.scheduler.route_rate(RouteMethod::Bluetooth));
            let Some(estimate) = boost::worth_it(remaining, rate) else { continue };
            let (Some(platform), Some(bytes)) = (self.boost.platform.clone(), transfer_bytes(&transfer)) else {
                continue;
            };
            // Android's permission may not be there (yet): nothing to propose.
            if !platform.abilities().any() {
                continue;
            }
            log!(
                "direct Wi-Fi: proposed for a file {:.0} s over Bluetooth, {:.0} s direct",
                estimate.bluetooth_seconds,
                estimate.direct_seconds
            );
            let sorts_first = self.sorts_first(head);
            let boost = Boost::propose(bytes, platform.abilities(), platform.connectivity(), sorts_first);
            self.boost.boosts.insert(head, Live { boost, transfer, estimate, lane: None, listener: None });
            self.with_boost(head, |_, _| {});
        }
    }

    /// Lanes up and down, rates, timeouts, and transfers that ended.
    fn follow_boosts(&mut self, now: Duration) {
        let heads: Vec<u64> = self.boost.boosts.keys().copied().collect();
        for head in heads {
            let Some(live) = self.boost.boosts.get(&head) else { continue };
            let transfer = live.transfer.clone();
            let still = self
                .sessions
                .map
                .get(&head)
                .is_some_and(|s| s.block_senders.contains_key(&transfer) || s.block_receivers.contains(&transfer));
            if !still {
                self.with_boost(head, |boost, now| boost.transfer_ended(now));
            }
            let direct_lane = self.sessions.groups.by_head.get(&head).and_then(|g| {
                g.lanes.live().find(|(_, index, route)| *index != 0 && *route == RouteMethod::PeerToPeerWifi)
            });
            let Some(live) = self.boost.boosts.get_mut(&head) else { continue };
            match (live.boost.phase(), direct_lane, live.lane) {
                (Phase::Hosting | Phase::Joining, Some((lane, _, _)), _) => {
                    live.lane = Some(lane);
                    live.boost.lane_up(now);
                    log!("direct Wi-Fi: the lane is up");
                }
                (Phase::Direct, None, Some(_)) => live.boost.lane_down(now),
                _ => {}
            }
            if live.boost.direct() {
                if let Some(schedule) = self.sessions.groups.schedules.get(&head) {
                    let direct = schedule.scheduler.route_rate(RouteMethod::PeerToPeerWifi);
                    let bluetooth = schedule.scheduler.route_rate(RouteMethod::Bluetooth);
                    live.boost.rates(direct, bluetooth, now);
                }
            }
            live.boost.tick(now);
            self.with_boost(head, |_, _| {});
        }
        self.boost.boosts.retain(|_, live| live.boost.phase() != Phase::Ended);
    }
}

/// Accepts on the boost's listener until stopped; each connection goes through the ordinary admission.
fn spawn_listener(listener: TcpListener, stop: Arc<AtomicBool>, input: std::sync::mpsc::Sender<Input>) {
    if listener.set_nonblocking(true).is_err() {
        return;
    }
    std::thread::spawn(move || {
        while !stop.load(Ordering::SeqCst) {
            match listener.accept() {
                Ok((stream, peer)) => {
                    let _ = stream.set_nonblocking(false);
                    let event = Event::Accepted {
                        stream: stream.into(),
                        route: RouteMethod::PeerToPeerWifi,
                        public: false,
                        listener: "direct-wifi".into(),
                        address: Some(peer.ip().to_string()),
                    };
                    if input.send(Input::Nearby(event)).is_err() {
                        return;
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(100));
                }
                Err(_) => std::thread::sleep(Duration::from_millis(250)),
            }
        }
    });
}

#[path = "boost_effects.rs"]
mod effects;

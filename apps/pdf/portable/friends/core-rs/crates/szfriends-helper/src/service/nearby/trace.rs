//! What the log says about reaching people, so the log alone answers "why is this friend not connected, and why did
//! that not send": each dial and what came of it, each session up and down with both sides' close reasons, the
//! session race, which routes were tried for a friend and why the others were not, what online was asked for, and
//! each transfer's start and end with its route and average rate.
//!
//! Friends appear by the first 8 characters of their conversation id, transfers by the first 8 of theirs; never a
//! name, key, address or file name. Lines that could repeat go through [`Trace::say`]: the same line under one key at
//! most once a minute, and at most a few lines a minute under one key whatever they say, with how many were left out.

use std::collections::HashMap;

use szfriends_core::session::SessionError;
use szfriends_core::store::{unix_now, TransferState};
use szfriends_core::wire::{CloseReason, RouteMethod};

use super::{DialPlan, LinkMeta, Purpose};
use crate::log;
use crate::service::{hex, State};

/// The same line under one key goes out again only after this long.
const REPEAT_SECONDS: f64 = 60.0;
/// Lines under one key in one minute, whatever they say.
const PER_KEY_PER_MINUTE: u32 = 6;
const KEYS_MAX: usize = 2048;

/// A friend's conversation as the log names it.
pub(crate) fn short(conversation: &str) -> &str {
    conversation.get(..8).unwrap_or(conversation)
}

/// Who a link is with: a friend's conversation, another of our devices, or nobody known yet.
pub(crate) fn who(purpose: Purpose, conversation: Option<&str>) -> String {
    match (purpose, conversation) {
        (Purpose::OwnDevice | Purpose::Join, _) => "own device".into(),
        (_, Some(c)) if c.starts_with("dev-") => "own device".into(),
        (_, Some(c)) => format!("friend {}", short(c)),
        (_, None) => "unknown".into(),
    }
}

pub(crate) fn reason(code: u8) -> String {
    let name = match code {
        x if x == CloseReason::Normal as u8 => "normal",
        x if x == CloseReason::ProtocolError as u8 => "protocol error",
        x if x == CloseReason::Superseded as u8 => "superseded (lost the race)",
        x if x == CloseReason::Expired as u8 => "expired",
        x if x == CloseReason::ShuttingDown as u8 => "shutting down",
        x if x == CloseReason::CodeMismatch as u8 => "code mismatch",
        x if x == CloseReason::LaneRefused as u8 => "lane refused",
        _ => "unknown",
    };
    format!("{name} ({code})")
}

/// Why a session ended, from both sides: the peer's CLOSE reason, or what else ended it, and ours if we closed it.
pub(crate) fn end_text(error: Option<&SessionError>, ours: Option<u8>) -> String {
    let theirs = match error {
        None => "closed here".to_owned(),
        Some(SessionError::PeerClosed(code)) => format!("peer closed: {}", reason(*code)),
        Some(SessionError::StreamClosed) => "link dropped without CLOSE".to_owned(),
        Some(other) => format!("{other:?} (error {})", other.code()),
    };
    match ours {
        Some(code) => format!("{theirs}; our close: {}", reason(code)),
        None => theirs,
    }
}

/// Bytes per second, readably.
fn rate(bytes: u64, seconds: f64) -> String {
    let per_second = bytes as f64 / seconds.max(0.001);
    match per_second {
        r if r >= 1_048_576.0 => format!("{:.1} MB/s", r / 1_048_576.0),
        r if r >= 1024.0 => format!("{:.0} KB/s", r / 1024.0),
        r => format!("{r:.0} B/s"),
    }
}

#[derive(Debug)]
struct Said {
    line: String,
    at: f64,
    minute: f64,
    in_minute: u32,
    left_out: u32,
}

/// One transfer moving on one session.
#[derive(Debug)]
struct Run {
    conversation: String,
    outgoing: bool,
    route: RouteMethod,
    started: f64,
    from: u64,
    size: u64,
}

/// See the module documentation.
#[derive(Debug, Default)]
pub struct Trace {
    said: HashMap<String, Said>,
    runs: HashMap<(u64, String), Run>,
    /// What the store held for a transfer's routes before this helper run first wrote them: the route meter counts
    /// this run only, so each write is this plus the meter's counts.
    route_bases: HashMap<String, Vec<(String, u64)>>,
}

/// The protocol's name for a route, as transfers.route_bytes and the views' segments name it.
fn route_key(route: RouteMethod) -> Option<&'static str> {
    match route {
        RouteMethod::Lan => Some("lan"),
        RouteMethod::PeerToPeerWifi => Some("p2p_wifi"),
        RouteMethod::Internet => Some("internet"),
        RouteMethod::Bluetooth => Some("bluetooth"),
        RouteMethod::Relay => Some("relay"),
        _ => None,
    }
}

impl Trace {
    /// Logs `line` under `key` unless the same line went out under it within a minute, or the key has had its share
    /// of lines this minute; the next line that goes out says how many were left out.
    pub fn say(&mut self, key: &str, line: String) {
        let now = unix_now();
        if self.said.len() >= KEYS_MAX && !self.said.contains_key(key) {
            self.said.retain(|_, s| now - s.at < REPEAT_SECONDS);
        }
        let said = self.said.entry(key.to_owned()).or_insert_with(|| Said {
            line: String::new(),
            at: f64::MIN,
            minute: now,
            in_minute: 0,
            left_out: 0,
        });
        if now - said.minute >= 60.0 {
            said.minute = now;
            said.in_minute = 0;
        }
        if (said.line == line && now - said.at < REPEAT_SECONDS) || said.in_minute >= PER_KEY_PER_MINUTE {
            said.left_out += 1;
            return;
        }
        match std::mem::take(&mut said.left_out) {
            0 => log!("{line}"),
            n => log!("{line} ({n} lines like it left out)"),
        }
        said.line = line;
        said.at = now;
        said.in_minute += 1;
    }
}

impl State {
    /// A dial started, could not start, or got no stream.
    pub(crate) fn trace_dial(&mut self, plan: &DialPlan, dial: Option<u64>, what: &str) {
        let who = who(plan.purpose, plan.conversation.as_deref());
        let number = dial.map_or(String::new(), |d| format!(" #{d}"));
        let probe = if plan.probe { ", probe" } else { "" };
        let line = format!("dial{number} {who} via {:?} ({:?}{probe}): {what}", plan.route, plan.purpose);
        let key = format!("dial|{who}|{:?}|{:?}", plan.route, plan.purpose);
        self.nearby.trace.say(&key, line);
    }

    /// A session went live: who, which route, who dialed.
    pub(crate) fn trace_up(&mut self, id: u64) {
        let Some(s) = self.sessions.map.get(&id) else { return };
        let meta = &s.meta;
        let mut who = who(meta.purpose, s.conversation.as_deref().or(meta.race_name.as_deref()));
        if !s.channel.is_initiator() && s.conversation.is_none() && meta.race_name.is_none() {
            // Someone dialed us: who they are is known once their handshake is, before the session is attached. A
            // phone in the background, which cannot scan, is reached only this way.
            who = match s.channel.remote_identity().copied() {
                Some(key) if self.is_own_device(&key) => format!("own device {}", &hex(&key)[..8]),
                Some(key) => match self.store.person_with_identity_key(&key).ok().flatten() {
                    Some(person) => format!("friend {}", short(&person.conversation_id)),
                    None => "someone not in the list".to_owned(),
                },
                None => who,
            };
        }
        let Some(s) = self.sessions.map.get(&id) else { return };
        let meta = &s.meta;
        let side = if s.channel.is_initiator() { "we dialed" } else { "they dialed" };
        let line = format!("session up #{id} ({:?}, {:?}, {side}) {who}", meta.purpose, meta.race_route(&s.channel));
        self.nearby.trace.say(&format!("up|{who}"), line);
    }

    /// A session ended: who, the route, how long it was live, both sides' reasons.
    pub(crate) fn trace_end(
        &mut self,
        id: u64,
        meta: &LinkMeta,
        conversation: Option<&str>,
        error: Option<&SessionError>,
    ) {
        let who = who(meta.purpose, conversation.or(meta.race_name.as_deref()));
        let live = match meta.live_at {
            Some(at) => format!("live {:.1} s", unix_now() - at),
            None => "handshaking".to_owned(),
        };
        let line = format!(
            "session ended #{id} (purpose {:?}, route {:?}, {live}) {who}: {}",
            meta.purpose,
            meta.dialed_route,
            end_text(error, meta.our_close)
        );
        self.nearby.trace.say(&format!("end|{who}|{:?}", meta.dialed_route), line);
    }

    /// The session race for a conversation, and what came of it.
    pub(crate) fn trace_race(&mut self, id: u64, current: Option<u64>, outcome: &str) {
        let describe = |state: &State, link: u64| -> String {
            state.sessions.map.get(&link).map_or(format!("#{link}"), |s| {
                let side = if s.channel.is_initiator() { "ours" } else { "theirs" };
                format!("#{link} ({:?}, {side})", s.meta.race_route(&s.channel))
            })
        };
        let conversation = self.sessions.map.get(&id).and_then(|s| s.conversation.clone()).unwrap_or_default();
        let against = current.map_or(String::new(), |c| format!(" against {}", describe(self, c)));
        let line = format!("race friend {}: {}{against}: {outcome}", short(&conversation), describe(self, id));
        self.nearby.trace.say(&format!("race|{conversation}"), line);
    }

    /// Which routes were tried for a friend sighted nearby, and why the others were not.
    pub(crate) fn trace_routes(&mut self, conversation: &str, line: String) {
        self.nearby
            .trace
            .say(&format!("routes|{conversation}"), format!("routes friend {}: {line}", short(conversation)));
    }

    /// The same for another of our devices (`who`), under the name the racer knows it by.
    pub(crate) fn trace_routes_of(&mut self, who: &str, name: &str, line: &str) {
        self.nearby.trace.say(&format!("routes|{name}"), format!("routes {who}: {line}"));
    }

    /// Transfers that started or ended on this session since it was last looked at: route, size, average rate.
    pub(crate) fn trace_transfers(&mut self, id: u64) {
        let moving: Vec<(String, bool)> = match self.sessions.map.get(&id) {
            Some(s) => s
                .senders
                .keys()
                .chain(s.block_senders.keys())
                .map(|t| (t.clone(), true))
                .chain(s.receivers.keys().chain(s.block_receivers.iter()).map(|t| (t.clone(), false)))
                .collect(),
            None => Vec::new(),
        };
        let ended: Vec<String> = self
            .nearby
            .trace
            .runs
            .keys()
            .filter(|(session, transfer)| *session == id && !moving.iter().any(|(t, _)| t == transfer))
            .map(|(_, t)| t.clone())
            .collect();
        for transfer in ended {
            let Some(run) = self.nearby.trace.runs.remove(&(id, transfer.clone())) else { continue };
            let record = self.store.transfer(&transfer).ok().flatten();
            let (outcome, done) = match record.as_ref().map(|r| (r.state, r.verified_bytes)) {
                Some((TransferState::Delivered | TransferState::Received, _)) => ("finished", run.size),
                Some((TransferState::Cancelled, done)) => ("cancelled", done),
                Some((TransferState::Declined, done)) => ("declined", done),
                Some((TransferState::Failed, done)) => ("failed", done),
                Some((_, done)) if !run.outgoing && done >= run.size => {
                    ("all bytes here, being checked and saved", done)
                }
                Some((_, done)) => ("stopped on this session (session ended or moved)", done),
                None => ("gone", run.from),
            };
            let seconds = unix_now() - run.started;
            let moved = done.saturating_sub(run.from);
            let line = format!(
                "transfer {} {} friend {} via {:?} #{id}: {outcome} after {seconds:.1} s, {moved} of {} bytes this run, \
                 average {}",
                short(&transfer),
                if run.outgoing { "to" } else { "from" },
                short(&run.conversation),
                run.route,
                run.size,
                rate(moved, seconds)
            );
            self.nearby.trace.say(&format!("transfer|{transfer}"), line);
            if record.is_some() {
                self.keep_routes(&transfer);
            }
        }
        let Some(s) = self.sessions.map.get(&id) else { return };
        let (route, conversation) = (s.meta.race_route(&s.channel), s.conversation.clone().unwrap_or_default());
        for (transfer, outgoing) in moving {
            if self.nearby.trace.runs.contains_key(&(id, transfer.clone())) {
                continue;
            }
            let record = self.store.transfer(&transfer).ok().flatten();
            let (size, from) = record.as_ref().map_or((0, 0), |r| (r.size, r.verified_bytes));
            let line = format!(
                "transfer {} {} friend {} via {:?} #{id}: started at {from} of {size} bytes",
                short(&transfer),
                if outgoing { "to" } else { "from" },
                short(&conversation),
                route
            );
            self.nearby.trace.say(&format!("transfer|{transfer}"), line);
            let run = Run { conversation: conversation.clone(), outgoing, route, started: unix_now(), from, size };
            self.nearby.trace.runs.insert((id, transfer), run);
        }
    }
}

impl State {
    /// How the file went through, kept with the transfer when a run of it ends, so its card can still show it once the
    /// file is delivered, received, cancelled or failed, after a restart too (PROTOCOL.md § Fast transfers, Progress
    /// by route): what earlier runs of the helper recorded plus what the route meter counted in this one, the same
    /// counts the moving bar was split by.
    fn keep_routes(&mut self, transfer: &str) {
        let counted = self.meter.borrow().route_bytes(transfer);
        if counted.is_empty() {
            return;
        }
        let base = match self.nearby.trace.route_bases.get(transfer) {
            Some(base) => base.clone(),
            None => {
                let base = self.store.transfer_route_bytes(transfer).unwrap_or_default();
                self.nearby.trace.route_bases.insert(transfer.to_owned(), base.clone());
                base
            }
        };
        let mut total = base;
        for (route, bytes) in counted {
            let Some(key) = route_key(route) else { continue };
            match total.iter_mut().find(|(name, _)| name == key) {
                Some((_, sum)) => *sum = sum.saturating_add(bytes),
                None => total.push((key.to_owned(), bytes)),
            }
        }
        if let Err(error) = self.store.set_transfer_route_bytes(transfer, &total) {
            log!("transfer {}: could not keep its routes: {error}", short(transfer));
        }
    }
}

#[cfg(feature = "online")]
impl State {
    /// Whom online is asked to reach, and why each other friend is not asked: logged when it changes.
    pub(crate) fn trace_online_wanted(&mut self) {
        use szfriends_core::nearby::is_better;
        use szfriends_core::store::Relation;
        let mut asked = Vec::new();
        let mut not = Vec::new();
        for person in self.store.people_by_latest_interaction().unwrap_or_default() {
            if person.relation != Relation::Friend {
                continue;
            }
            let c = short(&person.conversation_id).to_owned();
            let live = self.sessions.live_for(&person.conversation_id);
            let live_route = live.map(|id| self.sessions.map[&id].channel.initiator_route());
            let waiting = self.has_deliverable(&person)
                || !self.store.unfinished_incoming_transfers(&person.conversation_id).unwrap_or_default().is_empty();
            match live_route {
                Some(route) if !is_better(RouteMethod::Internet, route) => not.push(format!("{c} (live on {route:?})")),
                _ if !waiting => not.push(format!("{c} (nothing waiting)")),
                _ => asked.push(c),
            }
        }
        let line = format!("online: asking for [{}]; not asking for [{}]", asked.join(", "), not.join(", "));
        self.nearby.trace.say("online|wanted", line);
    }

    /// The online driver's account of one attempt with a friend or one of our devices.
    pub(crate) fn trace_online_attempt(&mut self, friend: &[u8; 32], entry: &szfriends_online::order::LogEntry) {
        let who = self.online_who(friend);
        let line = format!(
            "online attempt with {who} ended: {:?} after {} technique(s), first {:?}, last {:?}, {:.1} s to a stream, \
             relay asked {} needed {}, NAT here {:?} there {:?}",
            entry.end_reason,
            entry.techniques_tried,
            entry.first_technique,
            entry.final_technique,
            entry.seconds_to_first_stream,
            entry.relay_requested,
            entry.relay_needed,
            entry.local_class,
            entry.remote_class
        );
        self.nearby.trace.say(&format!("online|attempt|{who}"), line);
    }

    /// A data channel arrived for a friend or one of our devices.
    pub(crate) fn trace_online_stream(&mut self, friend: &[u8; 32], route: RouteMethod, initiator: bool) {
        let who = self.online_who(friend);
        let side = if initiator { "we start the handshake" } else { "they start it" };
        self.nearby
            .trace
            .say(&format!("online|stream|{who}"), format!("online stream with {who} via {route:?}: {side}"));
    }

    fn online_who(&self, key: &[u8; 32]) -> String {
        if self.is_own_device(key) {
            return "own device".into();
        }
        match self.store.person_with_identity_key(key).ok().flatten() {
            Some(person) => format!("friend {}", short(&person.conversation_id)),
            None => "someone not in the list".into(),
        }
    }
}

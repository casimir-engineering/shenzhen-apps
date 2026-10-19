//! One attempt's NAT techniques (`SZFriendsOnlineAttempt+NAT.m`; ADR 0011): predicted ports of a per-destination NAT,
//! and the hard-NAT prober with its probe handover connection. The order says when; this says how. Router port
//! mapping is not asked in this core yet (loopback tests never ask a router; see `nat/portmap.rs`).

use std::net::SocketAddr;

use super::attempt::Attempt;
use super::{Ctx, CONNECTIONS_MAX};
use crate::nat::classifier::NatClass;
use crate::nat::prober::{self, Hit, ProbeError, ProbeRole, Prober, ProberConfig, ProberEvent};
use crate::order::Phase;
use crate::signal::items::{nat_class, tag, Item};
use crate::transport::candidate::{line_for, predicted_candidates, CandidateType};
use crate::transport::{Kind, Role, Technique};

/// The probes' short-term credentials, from this attempt's authenticated signalling on both sides: each role's ufrag
/// and password come from its own export, so neither travels.
fn probe_credentials(session: &crate::signal::SignalingSession, role: Role) -> Option<(String, String)> {
    let label = if role == Role::Offerer { "SZFriends probe offerer v1" } else { "SZFriends probe answerer v1" };
    let key = session.export_key(label)?;
    let hex: String = key.iter().map(|b| format!("{b:02x}")).collect();
    Some((hex[..8].to_owned(), hex[16..].to_owned()))
}

impl Attempt {
    pub(super) fn start_prediction(&mut self, ctx: &mut Ctx<'_>) {
        self.prediction_pending = true;
        // The offerer's order tells the answerer, whose order then hears that the hard-NAT step began.
        if self.role == Role::Offerer {
            if let Some(number) = self.direct {
                self.send_items(vec![Item::start(number, Kind::ProbeHandover as u8)]);
            }
        }
        self.predict_if_possible(ctx);
    }

    /// The easy side adds the hard side's next mappings, continuing from its reflexive port in its step.
    pub(super) fn predict_if_possible(&mut self, ctx: &mut Ctx<'_>) {
        if !self.prediction_pending {
            return;
        }
        let (local, remote, step) = (ctx.context.nat_class(), self.remote_nat, i32::from(self.remote_step));
        let Some(slot) = self.direct.and_then(|n| self.slots.get_mut(&n)) else { return };
        let Some(reflexive) = slot.remote_reflexive.filter(|_| slot.remote_ready) else { return };
        if local != NatClass::EndpointIndependent || remote != NatClass::PerDestination {
            return;
        }
        self.prediction_pending = false;
        for line in predicted_candidates(reflexive, step, slot.remote_candidates) {
            if slot.connection.as_mut().is_some_and(|c| c.add_remote_candidate(&line, Technique::PredictedPort).is_ok())
            {
                slot.remote_candidates += 1;
            }
        }
    }

    fn prober_config(&self, ctx: &mut Ctx<'_>, role: ProbeRole, remote: SocketAddr) -> Option<ProberConfig> {
        let session = self.session.as_ref()?;
        let (local_ufrag, local_password) = probe_credentials(session, self.role)?;
        let (remote_ufrag, remote_password) = probe_credentials(session, self.role.other())?;
        let mut config = ProberConfig::new(role, self.friend.identity_key.to_vec(), remote);
        config.presented = match role {
            ProbeRole::Easy => self.direct.and_then(|n| self.slots.get(&n)).map(|s| s.remote_endpoints.clone()),
            ProbeRole::Hard => self.probe_remote.map(|r| vec![r]),
        }
        .unwrap_or_default();
        config.stun_server = ctx.context.stun_primary;
        config.local_ufrag = local_ufrag;
        config.local_password = local_password;
        config.remote_ufrag = remote_ufrag;
        config.remote_password = remote_password;
        config.loopback_only = ctx.context.loopback_only;
        Some(config)
    }

    /// Only one side's NAT maps per destination here (the order checked): that side opens many sockets, the other
    /// probes random ports of its public address from one socket.
    pub(super) fn start_probing(&mut self, ctx: &mut Ctx<'_>) {
        if self.prober.is_some() {
            return;
        }
        if !prober::AVAILABLE {
            return self.probing_refused(ctx);
        }
        let local = ctx.context.nat_class();
        if local == NatClass::PerDestination {
            // Hard side: waits for the easy prober's own address, which the signalling brings.
            self.probe_waits_for_remote = true;
            if let Some(remote) = self.probe_remote {
                self.prober_address_arrived(ctx, remote);
            }
            return;
        }
        let public = self.direct.and_then(|n| self.slots.get(&n)).and_then(|s| s.remote_reflexive);
        let config = match public {
            Some(public) if local == NatClass::EndpointIndependent => self.prober_config(ctx, ProbeRole::Easy, public),
            _ => None,
        };
        let Some(config) = config else {
            self.probing_refused(ctx);
            return;
        };
        self.prober = Some(Prober::spawn(config, ctx.context.prober_report(self.id)));
    }

    fn probing_refused(&mut self, ctx: &mut Ctx<'_>) {
        let (now, random) = (ctx.context.now(), ctx.context.random());
        let actions = self.order.probing_ended(true, now, random);
        self.perform(ctx, actions);
    }

    pub(super) fn prober_address_arrived(&mut self, ctx: &mut Ctx<'_>, endpoint: SocketAddr) {
        self.probe_remote = Some(endpoint);
        if !self.probe_waits_for_remote || self.prober.is_some() {
            return;
        }
        self.probe_waits_for_remote = false;
        let config = self.prober_config(ctx, ProbeRole::Hard, endpoint).filter(|_| prober::AVAILABLE);
        let Some(config) = config else {
            self.probing_refused(ctx);
            return;
        };
        self.prober = Some(Prober::spawn(config, ctx.context.prober_report(self.id)));
    }

    /// What the prober reports: the easy side's own address for the signalling, then its result.
    pub fn prober_event(&mut self, ctx: &mut Ctx<'_>, event: ProberEvent) {
        if self.ended || self.prober.is_none() {
            return;
        }
        match event {
            ProberEvent::Prepared(Some(reflexive)) => {
                let number = self.direct.unwrap_or(0);
                let line = line_for(reflexive, CandidateType::ServerReflexive, false, 0);
                self.send_items(vec![Item::candidate(number, Technique::ProbeHandover as u8, &line)]);
            }
            ProberEvent::Prepared(None) => {}
            ProberEvent::Finished(Ok(hit)) => {
                self.prober = None;
                self.probe_did_hit(ctx, hit);
            }
            ProberEvent::Finished(Err(error)) => {
                self.prober = None;
                let (now, random) = (ctx.context.now(), ctx.context.random());
                let actions = self.order.probing_ended(error == ProbeError::Budget, now, random);
                self.perform(ctx, actions);
            }
        }
        self.flush(ctx);
    }

    /// The offerer opens the probe handover connection bound to exactly its winning port; the answerer answers it
    /// from its own winning port.
    fn probe_did_hit(&mut self, ctx: &mut Ctx<'_>, hit: Hit) {
        self.probe_hit = Some(hit);
        if self.role == Role::Offerer {
            let number = self.next_number;
            self.next_number += 1;
            let opened = (number < CONNECTIONS_MAX)
                .then(|| self.open_slot(ctx, Kind::ProbeHandover, number as u8, None, None, hit.local_port))
                .flatten();
            if opened.is_none() {
                let (now, random) = (ctx.context.now(), ctx.context.random());
                let actions = self.order.connection_failed(Kind::ProbeHandover, now, random);
                self.perform(ctx, actions);
            }
            return;
        }
        self.probe_offer_arrived(ctx);
    }

    /// The probe handover connection's only remote candidate is the pair the prober found.
    pub(super) fn apply_probe_remote(&mut self, number: u8) {
        let Some(hit) = self.probe_hit else { return };
        let line = line_for(hit.remote, CandidateType::Host, false, 65535);
        if let Some(connection) = self.slots.get_mut(&number).and_then(|s| s.connection.as_mut()) {
            let _ = connection.add_remote_candidate(&line, Technique::ProbeHandover);
        }
        self.held.remove(&number);
    }

    /// Answerer: the offerer's probe handover offer, answered once this side's prober has its pair too.
    pub(super) fn probe_offer_arrived(&mut self, ctx: &mut Ctx<'_>) {
        let Some(hit) = self.probe_hit.filter(|_| self.role == Role::Answerer) else { return };
        let Some((offer, number)) = self.offers.remove(&Kind::ProbeHandover) else { return };
        if self.open_slot(ctx, Kind::ProbeHandover, number, Some(&offer), None, hit.local_port).is_none() {
            let (now, random) = (ctx.context.now(), ctx.context.random());
            let actions = self.order.connection_failed(Kind::ProbeHandover, now, random);
            self.perform(ctx, actions);
            return;
        }
        self.apply_probe_remote(number);
    }

    pub(super) fn stop_probing(&mut self) {
        self.prober = None;
        self.probe_waits_for_remote = false;
        self.prediction_pending = false;
        let probe_streams = self.probe.and_then(|n| self.slots.get(&n)).map_or(0, |s| s.open_streams);
        if self.probe.is_some() && probe_streams == 0 {
            self.close_slot(self.probe);
        }
    }

    pub(super) fn apply_nat(&mut self, ctx: &mut Ctx<'_>, item: &Item) {
        let Some(class) = item.unsigned(tag::NAT_CLASS).filter(|c| *c <= u64::from(nat_class::PER_DESTINATION)) else {
            return;
        };
        self.remote_nat = NatClass::from_byte(class as u8);
        self.remote_step = if self.remote_nat == NatClass::PerDestination { item.nat_step() } else { 0 };
        if self.order.phase() == Phase::PlainChecks {
            let (local, now) = (ctx.context.nat_class(), ctx.context.now());
            self.order.descriptions_applied(local, self.remote_nat, now);
        }
        self.predict_if_possible(ctx);
    }

    /// Start(probe handover) from the offerer: its hard-NAT step began. Start(direct) from the answerer: its network
    /// changed, so the offerer tries direct again.
    pub(super) fn apply_start(&mut self, ctx: &mut Ctx<'_>, kind: Kind) {
        let now = ctx.context.now();
        let actions = match (self.role, kind) {
            (Role::Answerer, Kind::ProbeHandover) => self.order.peer_started_hard_nat(),
            (Role::Offerer, Kind::Direct) => self.order.peer_network_changed(now),
            _ => 0,
        };
        self.perform(ctx, actions);
    }
}

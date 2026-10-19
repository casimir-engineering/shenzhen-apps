//! What the host connection reported, routed: the driver's sids, the download links', Add by ID's and joining's
//! (`online.rs`'s thread runs it).

use super::{Host, IdExchanges, JoinPipes, OnlineEvent, World};
use crate::host::{HostOutcome, Via};

impl World {
    pub(super) fn outcome(&mut self, outcome: HostOutcome) {
        match outcome {
            HostOutcome::Available(available) => {
                if available {
                    self.resolve_stun();
                    self.links.register_all(&mut self.host);
                }
                let _ = self.events.send(OnlineEvent::Available(available));
            }
            HostOutcome::Reserved(id, attestation) => {
                let _ = self.events.send(OnlineEvent::Reserved(id, attestation));
            }
            HostOutcome::PreJoinReleased(released) => {
                let _ = self.events.send(OnlineEvent::PreJoinReleased(released));
            }
            HostOutcome::ListChanged(list) => {
                let _ = self.events.send(OnlineEvent::HostList(list));
            }
            HostOutcome::PublishDue => self.publish(),
            HostOutcome::Removed => {
                let _ = self.events.send(OnlineEvent::Removed);
            }
            HostOutcome::Incoming { sid, via: Via::Rendezvous, payload, .. } => {
                self.driver.incoming(sid, &payload, &mut Host { client: &mut self.host });
            }
            HostOutcome::Incoming { sid, via: Via::Link, link_id: Some(link_id), payload } => {
                let stun = self.driver.context.stun_uri();
                self.links.incoming(&mut self.host, sid, link_id, &payload, stun);
            }
            HostOutcome::Incoming { sid, via: Via::FriendsId, payload, .. } => {
                let (identity, now) = (self.driver.context.identity.clone(), self.now());
                self.by_id.incoming(&mut self.host, &identity, sid, &payload, now);
            }
            HostOutcome::Incoming { sid, via: Via::Join, payload, .. } => {
                let (identity, now) = (self.driver.context.identity.clone(), self.now());
                self.join.incoming(&mut self.host, &identity, sid, &payload, now);
            }
            HostOutcome::Incoming { sid, .. } => self.host.close_sid(&sid),
            HostOutcome::Opened { token, sid, .. } if IdExchanges::owns_token(token) => {
                self.by_id.opened(&mut self.host, token, sid);
            }
            HostOutcome::Opened { token, sid, .. } if JoinPipes::owns_token(token) => {
                self.join.opened(&mut self.host, token, sid);
            }
            HostOutcome::Opened { token, sid, .. } => {
                self.driver.sid_opened(token, sid, &mut Host { client: &mut self.host });
            }
            HostOutcome::Payload { sid, payload } if self.by_id.owns_sid(&sid) => {
                let now = self.now();
                self.by_id.payload(&mut self.host, &sid, &payload, now);
            }
            HostOutcome::Payload { sid, payload } if self.join.owns_sid(&sid) => {
                let now = self.now();
                self.join.payload(&mut self.host, &sid, &payload, now);
            }
            HostOutcome::Payload { sid, payload } => {
                self.driver.sid_payload(&sid, &payload, &mut Host { client: &mut self.host });
                self.links.payload(&mut self.host, &sid, &payload);
            }
            HostOutcome::SidEnded { sid } if self.by_id.owns_sid(&sid) => self.by_id.sid_ended(&mut self.host, &sid),
            HostOutcome::SidEnded { sid } if self.join.owns_sid(&sid) => self.join.sid_ended(&mut self.host, &sid),
            HostOutcome::SidEnded { sid } => {
                self.driver.sid_ended(&sid, &mut Host { client: &mut self.host });
                self.links.sid_ended(&sid);
            }
            HostOutcome::Relay { token, credentials } => {
                if !self.links.relay_credentials(&mut self.host, token, credentials.clone()) {
                    self.driver.relay_credentials(token, credentials, &mut Host { client: &mut self.host });
                }
            }
            HostOutcome::Records { token, blobs } => self.records(token, blobs),
            HostOutcome::LinkRegistered { link_id, ok } => self.links.registered(link_id, ok),
        }
    }
}

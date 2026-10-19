//! One attempt of a link opening's setup (1 direct, 2 through the relay): its connection, the candidates it holds
//! back until the sender's answer, and the batches its own candidates go in, as the page batches its own.

use std::net::ToSocketAddrs;

use serde_json::{json, Value};
use szfriends_online::transport::description::stun_uri_valid;
use szfriends_online::transport::{Connection, Technique};

/// Candidates per setup payload are batched under this many bytes of JSON.
const CANDIDATE_JSON_MAX: usize = 3000;

pub(super) struct Attempt {
    pub(super) number: u8,
    pub(super) relay: bool,
    pub(super) connection: Connection,
    pub(super) mid: String,
    pub(super) described: bool,
    pub(super) answered: bool,
    pub(super) outgoing: Vec<(String, String)>,
    pub(super) held: Vec<String>,
    pub(super) local_ended: bool,
    pub(super) end_sent: bool,
}

/// The first STUN URI that names a numeric address (resolved here), loopback only in tests.
pub(super) fn numeric_stun(uris: &[String], loopback: bool) -> Option<String> {
    uris.iter().find_map(|uri| {
        let rest = uri.strip_prefix("stun:")?;
        let with_port =
            if rest.contains(']') || rest.matches(':').count() == 1 { rest.to_owned() } else { format!("{rest}:3478") };
        let address = with_port.to_socket_addrs().ok()?.find(|a| !loopback || a.ip().is_loopback())?;
        let uri = format!("stun:{address}");
        stun_uri_valid(&uri).then_some(uri)
    })
}

pub(super) fn remote_technique(line: &str) -> Technique {
    if line.contains(" typ relay") {
        Technique::Relay
    } else if line.contains(" typ srflx") {
        Technique::ServerReflexive
    } else if line.contains(" typ prflx") {
        Technique::PeerReflexive
    } else if line.split(' ').nth(4).is_some_and(|a| a.contains(':')) {
        Technique::HostIpv6
    } else {
        Technique::HostPrivate
    }
}

/// The candidates each described attempt gathered since the last call, in batches, then its end once.
pub(super) fn candidate_messages<'a>(attempts: impl Iterator<Item = &'a mut Attempt>) -> Vec<Value> {
    let mut messages = Vec::new();
    for attempt in attempts.filter(|a| a.described) {
        let mut batch: Vec<Value> = Vec::new();
        let mut size = 0;
        for (line, mid) in attempt.outgoing.drain(..) {
            let cost = line.len() + mid.len() + 8;
            if !batch.is_empty() && size + cost > CANDIDATE_JSON_MAX {
                messages.push(json!({ "t": "cand", "a": attempt.number, "c": std::mem::take(&mut batch) }));
                size = 0;
            }
            batch.push(json!([line, mid]));
            size += cost;
        }
        if !batch.is_empty() {
            messages.push(json!({ "t": "cand", "a": attempt.number, "c": batch }));
        }
        if attempt.local_ended && !attempt.end_sent {
            attempt.end_sent = true;
            messages.push(json!({ "t": "cand", "a": attempt.number, "end": true }));
        }
    }
    messages
}

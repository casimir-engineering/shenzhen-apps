//! One attempt of a link's setup (attempt 1 direct, attempt 2 through the relay), and the candidate batches it sends.

use serde_json::{json, Value};

use crate::transport::{Connection, Technique};

/// Candidates per setup payload are batched under this many bytes of JSON, as the page batches its own.
const CANDIDATE_JSON_MAX: usize = 3000;

#[derive(Debug)]
pub(super) struct Attempt {
    pub(super) number: u8,
    pub(super) connection: Option<Connection>,
    pub(super) id: u64,
    pub(super) mid: String,
    pub(super) described: bool,
    pub(super) outgoing: Vec<(String, String)>,
    pub(super) local_ended: bool,
    pub(super) end_sent: bool,
    pub(super) held: Vec<Option<String>>,
    pub(super) offer: Option<String>,
}

impl Attempt {
    pub(super) fn new(number: u8, id: u64, offer: Option<String>) -> Self {
        Self {
            number,
            connection: None,
            id,
            mid: "0".into(),
            described: false,
            outgoing: Vec::new(),
            local_ended: false,
            end_sent: false,
            held: Vec::new(),
            offer,
        }
    }
}

pub(super) fn attempt_number(value: Option<&Value>) -> Option<u8> {
    value?.as_u64().filter(|n| (1..=2).contains(n)).map(|n| n as u8)
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

/// The candidates each described attempt has gathered since the last call, in batches, then its end once.
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

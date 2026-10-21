//! The Friends ID a computer reserved for itself before it joined a profile (`SZFriendsHostCheckIn.m`,
//! `releasePreJoinIDThenStart`; `SZFriendsCheckInClient+Release.m`; HOST-PROTOCOL.md § Release). Until released it
//! stays this computer's own on the host, an ID nobody would ever use, so the first connection after joining releases
//! it with this computer's key before the check-in for the person. Tried once per start and per join: a host that
//! does not answer is asked again at the next start, and the check-in goes ahead either way.
//!
//! Reset Friends releases this identity too (ADR 0005 step 6; `SZFriendsCheckInClient+Release.m`): over the open
//! connection when it has checked in, else over one opened for it, each host of the list tried once, the whole
//! bounded by a timeout. Whatever the answer, or none (offline, every host down), the client stops for good and the
//! reset goes ahead.

use std::sync::mpsc::Sender;
use std::sync::Arc;

use serde_json::{json, Value};

use super::client::{HostClient, HostOutcome, Phase};
use super::codec::{length_prefixed, Field};
use crate::b64;

pub const RELEASE_DOMAIN: &str = "SZFriends release v1";

/// Whether this computer still owes the host a release of its ID from before joining (the store says, across
/// launches, until a host confirms one).
pub type ReleaseOwed = Arc<dyn Fn() -> bool + Send + Sync>;

/// What a release signs after its domain.
pub fn release_message(host_id: &str, challenge: &[u8], identity_key: &[u8; 32], friends_id: &str) -> Vec<u8> {
    length_prefixed(&[
        Field::Text(host_id),
        Field::Bytes(challenge),
        Field::Bytes(identity_key),
        Field::Text(friends_id),
    ])
}

impl HostClient {
    /// At the start of a round: whether this connection releases first.
    pub(super) fn release_due(&self) -> bool {
        !self.release_tried && self.release_owed.as_ref().is_some_and(|owed| owed())
    }

    /// The challenge arrived on a connection that releases first: the release, signed over it with this computer's
    /// own key. The ID it names is not looked at by the host, which releases whatever this key holds; like the Mac
    /// helper's, it names none.
    pub(super) fn send_release(&mut self, host_id: &str, challenge: &[u8]) {
        self.release_tried = true;
        let key = self.identity.public_key();
        // Reset Friends names the ID it gives up, as the Mac helper does; the host goes by the key either way.
        let friends_id = if self.reset.is_some() { (self.id_provider)(0) } else { String::new() };
        let signature = self.identity.sign(&release_message(host_id, challenge, &key, &friends_id), RELEASE_DOMAIN);
        let fields = json!({
            "identity_key": b64::encode_url(&key),
            "friends_id": friends_id,
            "sig": b64::encode_url(&signature),
        });
        if let Value::Object(fields) = fields {
            self.send("release", fields);
        }
    }

    /// The host's answer (`released`, signed over this connection's challenge), or none in time: the owner hears
    /// whether it was confirmed, and the check-in for the person starts.
    pub(super) fn finish_release(&mut self, answer: Option<&Value>) {
        let released = answer.is_some_and(|message| {
            let flag = message.get("released") == Some(&Value::Bool(true));
            let body = ["released".to_owned(), if flag { "1" } else { "0" }.to_owned()];
            flag && self.verifies(message, &body)
        });
        self.releasing = false;
        if let Some((_, reply)) = self.reset.take() {
            self.close_socket();
            let _ = reply.send(released);
            return;
        }
        self.outcomes.push(HostOutcome::PreJoinReleased(released));
        self.close_socket();
        if self.is_running() {
            self.attempt = 0;
            self.begin_round();
        }
    }
}

impl HostClient {
    /// Reset Friends: the host forgets this identity and frees its Friends ID, within `timeout` seconds; `reply`
    /// hears whether a host confirmed it. The client stops for good either way. A second request while one runs is
    /// answered `false` at once: the first decides.
    pub fn release_for_reset(&mut self, timeout: f64, reply: Sender<bool>) {
        if self.reset.is_some() {
            let _ = reply.send(false);
            return;
        }
        self.running = false;
        self.retry_at = f64::INFINITY;
        self.reset = Some((self.now() + timeout, reply));
        self.releasing = true;
        match (self.phase, self.challenge.clone(), self.connected_entry().map(|e| e.id.clone())) {
            (Phase::CheckedIn, Some(challenge), Some(host_id)) => {
                self.phase = Phase::Releasing;
                self.send_release(&host_id, &challenge);
            }
            _ => {
                self.close_socket();
                self.begin_round();
            }
        }
    }
}

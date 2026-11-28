//! The helper's log lines for one connection (connection.rs): which it is, how long since it started, and the pair
//! of candidates ICE chose.

use super::{Candidate, Connection, Kind, PeerConnection};

impl Connection {
    /// A line for the helper's log (super::set_log): which connection, how long since it started, what.
    pub(super) fn log(&self, what: &str) {
        let kind = if self.kind == Kind::Relay { "relay" } else { "direct" };
        super::super::log_line(&format!("online {kind} +{:.2} s: {what}", self.started.elapsed().as_secs_f64()));
    }

    pub(super) fn log_selected_pair(&self, what: &str) {
        let pair = self.pc.as_ref().and_then(PeerConnection::selected_pair);
        let Some((local, remote)) = pair.and_then(|(l, r)| Candidate::parse(&l).zip(Candidate::parse(&r))) else {
            self.log(&format!("{what} (no selected pair to read)"));
            return;
        };
        // The signalled candidate where one matches: the stack reports a pair learnt from checks as peer-reflexive.
        let local = self.local.get(&local.endpoint()).map_or(local, |(c, _)| c.clone());
        let remote = self.remote.get(&remote.endpoint()).map_or(remote, |(c, _)| c.clone());
        self.log(&format!(
            "{what} on our {} with their {} (technique {})",
            local.summary(),
            remote.summary(),
            self.selected_route().technique as u8
        ));
    }
}

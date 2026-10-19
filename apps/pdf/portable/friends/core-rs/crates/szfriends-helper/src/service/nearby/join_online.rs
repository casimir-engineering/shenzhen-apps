//! Joining a profile through the Friends host (`SZFriendsNearbyService+JoinOnline.m`): the new computer's request to
//! every device of the profile (first, then every 20 minutes while it waits), its code on a pipe only the device
//! holding an approval answers, and every device's side. The messages, approvals and attempts are joining's own
//! (`join.rs`); a pipe is one more kind of leg.

use szfriends_core::identity::join::RequestState;
use szfriends_core::presentation::JoiningState;
use szfriends_core::store::{devices, unix_now};
use szfriends_online::join::JoinEvent;

use crate::service::devices::JoinPipe;
use crate::service::State;

/// How often the new computer's request goes to the host again while it waits.
const REQUEST_REPEAT_SECONDS: f64 = 1200.0;

impl State {
    /// Called with nearby's offer: the request to the host, or the code on a pipe, when online is there.
    pub(crate) fn offer_join_online(&mut self) {
        let chain = devices::own_chain(self.store.connection()).ok().flatten();
        let now = unix_now();
        let holds =
            self.devices.approver.open_requests(chain.as_ref(), now).iter().any(|r| r.state == RequestState::Approved);
        let Some(online) = self.online.as_ref().filter(|o| o.is_available()) else { return };
        online.set_holds_approval(holds);
        let Some(joiner) = &self.devices.joiner else { return };
        let friends_id = joiner.friends_id().to_owned();
        match self.devices.phase {
            JoiningState::Waiting | JoiningState::WrongCode | JoiningState::NotReached => {
                if self.devices.request_sent_online_at.is_some_and(|at| now - at < REQUEST_REPEAT_SECONDS) {
                    return;
                }
                let Some(message) = joiner.request_message(now) else { return };
                self.devices.request_sent_online_at = Some(now);
                online.join_request(&friends_id, message);
            }
            JoiningState::Checking if self.devices.code_sent_online != Some(self.devices.generation) => {
                self.devices.code_sent_online = Some(self.devices.generation);
                let pipe = self.reserve_session_id();
                self.devices.pipes.insert(pipe, JoinPipe { initiator: true, hash: Vec::new() });
                if let Some(online) = &self.online {
                    online.join_code(pipe, &friends_id);
                }
            }
            _ => {}
        }
    }

    /// What joining's pipes reported.
    pub(crate) fn join_event(&mut self, event: JoinEvent) {
        match event {
            JoinEvent::Request(message) => {
                // Nobody answers a request through the host, not even with its end.
                let _ = self.join_request_heard(&message);
            }
            JoinEvent::Ready { pipe, initiator: true, handshake_hash } => {
                let Some(leg) = self.devices.pipes.get_mut(&pipe) else { return };
                leg.hash = handshake_hash.clone();
                let area = &self.devices;
                let attempt = match (&area.joiner, &area.code) {
                    (Some(joiner), Some(code)) if area.phase == JoiningState::Checking => {
                        joiner.attempt(code, &handshake_hash, None)
                    }
                    _ => None,
                };
                let Some(attempt) = attempt else { return self.join_close(pipe) };
                let message = attempt.code_message().to_vec();
                self.devices.attempts.insert(pipe, attempt);
                self.join_send(pipe, message);
            }
            JoinEvent::Ready { pipe, initiator: false, handshake_hash } => {
                self.devices.pipes.insert(pipe, JoinPipe { initiator: false, hash: handshake_hash });
            }
            JoinEvent::Messages { pipe, messages } => {
                let Some(initiator) = self.devices.pipes.get(&pipe).map(|p| p.initiator) else { return };
                for message in messages {
                    if !self.devices.pipes.contains_key(&pipe) {
                        return;
                    }
                    self.join_message_on_leg(pipe, &message, initiator);
                }
            }
            JoinEvent::Ended(pipe) => {
                if self.devices.pipes.remove(&pipe).is_some() {
                    self.join_session_closed(pipe);
                }
            }
        }
    }
}

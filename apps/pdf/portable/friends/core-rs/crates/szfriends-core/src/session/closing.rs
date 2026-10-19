//! Closing (`SZFriendsSecureChannel.m` § Closing): graceful CLOSE after the queued control frames, quiet refusals
//! before a responder's first reply, and the one place a channel ends.

use std::time::Duration;

use szfriends_wire::{tag, CloseReason, Frame, FrameType};

use super::channel::{Role, SecureChannel, State, Transmit};
use super::{Event, SessionError};

impl SecureChannel {
    /// The link ended (EOF or an error) without this side closing it.
    pub fn link_closed_by_peer(&mut self) {
        match self.state {
            State::Closed => {}
            // The peer gave up first, so nobody is left to time our close: report the refusal now.
            State::Refusing => {
                let error = self.refusal_error;
                self.terminate(error, None);
            }
            _ => self.terminate(Some(SessionError::StreamClosed), None),
        }
    }

    pub fn close(&mut self, now: Duration) {
        self.close_with_reason(CloseReason::Normal, now);
    }

    /// CLOSE after the queued control frames (in-flight ACKs still go out); queued chunks are dropped.
    pub fn close_with_reason(&mut self, reason: CloseReason, now: Duration) {
        self.begin_closing(reason as u8, None, now);
    }

    pub(super) fn begin_closing(&mut self, reason: u8, error: Option<SessionError>, now: Duration) {
        if matches!(self.state, State::Closed | State::Closing) {
            return;
        }
        if self.state != State::Established {
            // No live session to say goodbye in: before HELLO nothing has been revealed beyond the handshake.
            self.terminate(error, None);
            return;
        }
        self.state = State::Closing;
        self.closing_error = error;
        self.bulk_queue.clear();
        let close = Frame::new(FrameType::Close).with(tag::REASON, [reason]);
        self.enqueue_channel_frame(&close);
        self.pump_writes(now);
    }

    /// Before a responder's first reply this refuses quietly (closing at the refusal deadline); otherwise it ends the
    /// channel at once.
    pub(super) fn fail(&mut self, error: SessionError, _now: Duration) {
        let before_reply = matches!(self.state, State::AwaitingPreamble | State::Handshaking);
        if !self.is_initiator() && !self.responder_replied && before_reply {
            self.refuse_quietly(error);
            return;
        }
        self.terminate(Some(error), None);
    }

    /// No byte written, nothing more read, and the link closed the refusal delay after the deciding bytes arrived.
    fn refuse_quietly(&mut self, error: SessionError) {
        self.state = State::Refusing;
        self.refusal_error = Some(error);
        self.handshake = None;
        self.inbound.clear();
        self.refusal_deadline = Some(self.input_arrived_at + self.config.refusal_delay);
    }

    /// Protocol violations after keys exist: CLOSE(ProtocolError), then the end.
    pub(super) fn protocol_failure(&mut self, error: SessionError) {
        self.terminate(Some(error), Some(CloseReason::ProtocolError as u8));
    }

    /// One CLOSE straight to the link, bypassing the queues being abandoned.
    fn write_close_now(&mut self, reason: u8) {
        let plaintext = [FrameType::Close as u8, tag::REASON, 0, 1, reason];
        if let Some(Ok(message)) = self.transport.as_mut().map(|t| t.encrypt(&plaintext)) {
            let mut bytes = (message.len() as u16).to_be_bytes().to_vec();
            bytes.extend_from_slice(&message);
            self.transmit.push_back(Transmit { bytes, counted: false });
        }
    }

    pub(super) fn terminate(&mut self, error: Option<SessionError>, close_reason: Option<u8>) {
        if self.state == State::Closed {
            return;
        }
        if let Some(reason) = close_reason {
            if self.transport.is_some() && !self.close_written {
                self.write_close_now(reason);
            }
        }
        self.state = State::Closed;
        self.control_queue.clear();
        self.bulk_queue.clear();
        self.inbound.clear();
        self.handshake = None;
        self.transport = None;
        self.link_closed = true;
        self.role_drop_callbacks();
        if self.code.pending() {
            self.finish_code(Err(error.unwrap_or(SessionError::Protocol)));
        }
        self.events.push_back(Event::Closed(error));
    }

    /// Callbacks often capture whatever owns the channel; dropping them breaks the cycle.
    fn role_drop_callbacks(&mut self) {
        match &mut self.role {
            Role::Initiator { on_profile, .. } => *on_profile = None,
            Role::Responder { policy, .. } => *policy = None,
        }
        self.hooks = None;
    }
}

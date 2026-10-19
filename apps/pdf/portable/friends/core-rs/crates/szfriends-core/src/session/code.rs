//! The comparison-code exchange (`SZFriendsSecureChannel+Code`, ADR 0001 § Comparison codes): the responder commits
//! to its nonce, the initiator reveals its own, the responder reveals and the initiator checks the commitment, so
//! neither side, nor anyone between them, can steer the six digits.

use std::time::Duration;

use szfriends_crypto::code::{commitment, commitment_matches, comparison_code, NONCE_LEN};
use szfriends_wire::{tag, CloseReason, Frame, FrameType, Pattern};
use zeroize::Zeroizing;

use super::channel::{SecureChannel, State};
use super::{Event, SessionError};

#[derive(Default)]
pub(super) struct CodeExchange {
    requested: bool,
    waiting: bool,
    local_nonce: Option<Zeroizing<[u8; NONCE_LEN]>>,
    peer_commitment: Option<Vec<u8>>,
    sent_commit: bool,
    received_commit: bool,
    sent_nonce: bool,
    received_nonce: bool,
    received_reveal: bool,
}

impl CodeExchange {
    /// A caller waits for its code.
    pub(super) fn pending(&self) -> bool {
        self.waiting
    }
}

impl SecureChannel {
    /// Runs CODE_COMMIT / CODE_NONCE / CODE_REVEAL once, in the session that creates the friendship; both sides call
    /// it, in either order, before or after the session is live. [`Event::Code`] reports six ASCII digits, or an error
    /// when the commitment does not verify (which closes the channel), the channel closes first, for NN, or on a
    /// second call. The initiator sees its code only after the responder's nonce verified against the commitment.
    pub fn run_code_exchange(&mut self, now: Duration) {
        let refused = self.code.requested
            || matches!(self.state, State::Closed | State::Closing | State::Refusing)
            || (self.pattern == Pattern::NN && (self.is_initiator() || self.state >= State::Handshaking));
        if refused {
            self.events.push_back(Event::Code(Err(SessionError::Protocol)));
            return;
        }
        self.code.requested = true;
        self.code.waiting = true;
        let mut nonce = Zeroizing::new([0u8; NONCE_LEN]);
        self.rng.fill(nonce.as_mut());
        self.code.local_nonce = Some(nonce);
        self.advance_code_exchange(now);
    }

    fn send_code_frame(&mut self, frame_type: FrameType, field: u8, value: &[u8], now: Duration) {
        self.enqueue_channel_frame(&Frame::new(frame_type).with(field, value));
        self.pump_writes(now);
    }

    pub(super) fn advance_code_exchange(&mut self, now: Duration) {
        if !self.code.waiting || self.state != State::Established {
            return;
        }
        if self.pattern == Pattern::NN {
            // A responder may ask before its preamble says the session is NN.
            self.finish_code(Err(SessionError::Protocol));
            return;
        }
        let (Some(hash), Some(nonce)) = (self.handshake_hash, self.code.local_nonce.clone()) else { return };
        if !self.is_initiator() && !self.code.sent_commit {
            self.code.sent_commit = true;
            self.send_code_frame(FrameType::CodeCommit, tag::COMMITMENT, &commitment(&hash, nonce.as_ref()), now);
        } else if self.is_initiator() && self.code.received_commit && !self.code.sent_nonce {
            self.code.sent_nonce = true;
            self.send_code_frame(FrameType::CodeNonce, tag::NONCE, nonce.as_ref(), now);
        }
    }

    pub(super) fn handle_code_frame(&mut self, frame: &Frame, now: Duration) {
        let initiator = self.is_initiator();
        if self.pattern == Pattern::NN {
            self.protocol_failure(SessionError::Protocol);
            return;
        }
        let hash = self.handshake_hash.unwrap_or([0u8; 64]);
        match frame.frame_type {
            FrameType::CodeCommit if initiator && !self.code.received_commit => {
                self.code.received_commit = true;
                self.code.peer_commitment = frame.get(tag::COMMITMENT).map(<[u8]>::to_vec);
                self.advance_code_exchange(now);
                return;
            }
            FrameType::CodeNonce if !initiator && self.code.sent_commit && !self.code.received_nonce => {
                self.code.received_nonce = true;
                let initiator_nonce = frame.get(tag::NONCE).unwrap_or_default().to_vec();
                let responder_nonce = self.code.local_nonce.clone().unwrap_or_default();
                self.send_code_frame(FrameType::CodeReveal, tag::NONCE, responder_nonce.as_ref(), now);
                self.finish_code(Ok(comparison_code(&hash, &initiator_nonce, responder_nonce.as_ref())));
                return;
            }
            FrameType::CodeReveal if initiator && self.code.sent_nonce && !self.code.received_reveal => {
                self.code.received_reveal = true;
                let responder_nonce = frame.get(tag::NONCE).unwrap_or_default().to_vec();
                let committed = self.code.peer_commitment.clone().unwrap_or_default();
                if !commitment_matches(&committed, &hash, &responder_nonce) {
                    self.finish_code(Err(SessionError::CodeMismatch));
                    self.begin_closing(CloseReason::CodeMismatch as u8, Some(SessionError::CodeMismatch), now);
                    return;
                }
                let local = self.code.local_nonce.clone().unwrap_or_default();
                self.finish_code(Ok(comparison_code(&hash, local.as_ref(), &responder_nonce)));
                return;
            }
            _ => {}
        }
        self.protocol_failure(SessionError::Protocol);
    }

    pub(super) fn finish_code(&mut self, result: Result<String, SessionError>) {
        let waiting = std::mem::take(&mut self.code.waiting);
        self.code.local_nonce = None;
        self.code.peer_commitment = None;
        if waiting {
            self.events.push_back(Event::Code(result));
        }
    }
}

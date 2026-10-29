//! Send queues, transport encryption, rekey, session age and frame dispatch (`SZFriendsSecureChannel+Transport`).

use std::time::Duration;

use szfriends_crypto::noise::NoiseError;
use szfriends_wire::consts::NOISE_TAG_LEN;
use szfriends_wire::{tag, CloseReason, Frame, FrameType, Pattern};

use super::channel::{SecureChannel, State, Transmit};
use super::{Event, SessionError};

/// Types only the channel sends and handles; callers never send them and [`Event::Frame`] never carries them.
fn is_channel_frame(frame_type: FrameType) -> bool {
    use FrameType::*;
    matches!(frame_type, Hello | CodeCommit | CodeNonce | CodeReveal | Rekey | Ping | Close)
}

/// Minor 4's frames (ADR 0018 § 3): only on a session that negotiated fast transfers, either way.
fn is_fast_transfer_frame(frame_type: FrameType) -> bool {
    matches!(frame_type, FrameType::Hashes | FrameType::Want | FrameType::Part | FrameType::Have)
}

/// NN exists only for Add by ID and joining: REQUEST_BY_ID one way, RECEIVED the other, JOIN either way, nothing else;
/// they never travel in XX or IK, where the peer's identity is already known.
fn type_allowed(frame_type: FrameType, pattern: Pattern, from_initiator: bool) -> bool {
    let nn = pattern == Pattern::NN;
    match frame_type {
        FrameType::Join => nn,
        FrameType::RequestById => nn && from_initiator,
        FrameType::Received => nn && !from_initiator,
        _ => !nn,
    }
}

impl SecureChannel {
    /// Queues a frame for encryption; frames queued before the session is live wait for it. Control and message
    /// frames jump queued CHUNKs; DONE and THUMBNAIL travel in the CHUNK queue, so DONE never overtakes its last
    /// chunk and a preview never delays a message. `false`, sending nothing, for a frame the codec refuses, a type the
    /// channel owns, a type the pattern does not allow, or a channel that is closing.
    pub fn send_frame(&mut self, frame: &Frame, now: Duration) -> bool {
        if matches!(self.state, State::Closing | State::Closed | State::Refusing) {
            return false;
        }
        // A responder learns the pattern from the preamble; before that nobody is there to send to.
        if !self.is_initiator() && self.state < State::Handshaking {
            return false;
        }
        let frame_type = frame.frame_type;
        if is_channel_frame(frame_type) || !type_allowed(frame_type, self.pattern, self.is_initiator()) {
            return false;
        }
        // ADR 0018 § 1: a peer that did not negotiate fast transfers never receives a frame or field of them.
        let fast = self.fast_transfers();
        if !fast && is_fast_transfer_frame(frame_type) {
            return false;
        }
        // ADR 0019: BOOST only to a peer that set the boost's bit.
        if frame_type == FrameType::Boost && !self.direct_wifi_boost() {
            return false;
        }
        let encoded = if !fast && frame.fields.keys().any(|t| tag::is_fast_transfers(*t)) {
            let mut plain = frame.clone();
            plain.fields.retain(|t, _| !tag::is_fast_transfers(*t));
            plain.encode()
        } else {
            frame.encode()
        };
        let Ok(plaintext) = encoded else { return false };
        if matches!(
            frame_type,
            FrameType::Chunk | FrameType::Done | FrameType::Thumbnail | FrameType::Hashes | FrameType::Part
        ) {
            self.bulk_queue.push_back(plaintext);
        } else {
            self.control_queue.push_back(plaintext);
        }
        self.pump_writes(now);
        true
    }

    /// Plaintexts queued but not yet encrypted, control and bulk: a sender keeps its chunk pipeline shallow with it.
    pub fn queued_frames(&self) -> (usize, usize) {
        (self.control_queue.len(), self.bulk_queue.len())
    }

    /// The plaintext bytes waiting in the bulk queue: a sender of many small parts keeps the queue shallow in bytes,
    /// not in frames, so a burst of small files fills a read at the other end.
    pub fn queued_bulk_bytes(&self) -> usize {
        self.bulk_queue.iter().map(Vec::len).sum()
    }

    pub(super) fn enqueue_channel_frame(&mut self, frame: &Frame) {
        if let Ok(plaintext) = frame.encode() {
            self.control_queue.push_back(plaintext);
        }
    }

    /// Everything already handed to the link is beyond reordering, so keeping it small is what lets a message queued
    /// now overtake the chunks still waiting. At least one message is always in flight, whatever its size.
    fn in_flight_budget(&self) -> usize {
        self.config.preferred_write_size.max(1024) * 4
    }

    pub(super) fn pump_writes(&mut self, now: Duration) {
        if !matches!(self.state, State::Established | State::Closing) {
            return;
        }
        while self.state != State::Closed && !self.close_written {
            let from_control = !self.control_queue.is_empty();
            let queue = if from_control { &self.control_queue } else { &self.bulk_queue };
            let Some(next) = queue.front() else { break };
            if self.in_flight > 0 && self.in_flight + next.len() > self.in_flight_budget() {
                return;
            }
            if !from_control && self.bulk_queue.len() > 1 && self.config.crypto_batches {
                // While writes are on the link, bulk frames wait until two fit, so they are sealed together.
                let two: usize = self.bulk_queue.iter().take(2).map(|f| f.len() + NOISE_TAG_LEN + 2).sum();
                if self.in_flight > 0 && self.in_flight + two > self.in_flight_budget() {
                    return;
                }
                match self.write_bulk_batch(now) {
                    Some(true) => continue,
                    Some(false) => return,
                    None => {} // a rekey is due: one at a time below
                }
            }
            let plaintext = if from_control { self.control_queue.pop_front() } else { self.bulk_queue.pop_front() };
            let plaintext = plaintext.expect("checked above");
            let is_close = plaintext[0] == FrameType::Close as u8;
            if !self.write_transport_plaintext(&plaintext, now) {
                return;
            }
            if is_close {
                self.close_written = true;
            }
        }
        self.finish_closing_if_drained();
    }

    /// Several bulk frames sealed in one batch, on several cores when large (ADR 0018 § 9.2), and handed to the link
    /// as one write: as many as fit the in-flight budget, the first always. `None` when a rekey is due before the batch
    /// would end (the caller goes one frame at a time), `Some(false)` after failing the channel.
    fn write_bulk_batch(&mut self, now: Duration) -> Option<bool> {
        let budget = self.in_flight_budget();
        let mut count = 0;
        let mut bytes = 0usize;
        for frame in &self.bulk_queue {
            let framed = frame.len() + NOISE_TAG_LEN + 2;
            if count > 0 && self.in_flight + bytes + framed > budget {
                break;
            }
            count += 1;
            bytes += framed;
        }
        let plaintext: usize = self.bulk_queue.iter().take(count).map(Vec::len).sum();
        if count < 2
            || self.rekey_due(now)
            || self.bytes_since_send_rekey + plaintext as u64 >= self.config.rekey_after_bytes
        {
            return None;
        }
        if !self.check_session_age(now) {
            return Some(false);
        }
        let frames: Vec<Vec<u8>> = self.bulk_queue.drain(..count).collect();
        let refs: Vec<&[u8]> = frames.iter().map(Vec::as_slice).collect();
        let Some(Ok(messages)) = self.transport.as_mut().map(|t| t.encrypt_many(&refs)) else {
            self.fail(SessionError::Expired, now);
            return Some(false);
        };
        let mut out = Vec::with_capacity(bytes);
        for message in &messages {
            out.extend_from_slice(&(message.len() as u16).to_be_bytes());
            out.extend_from_slice(message);
        }
        self.in_flight += out.len();
        self.transmit.push_back(Transmit { bytes: out, counted: true });
        self.bytes_since_send_rekey += plaintext as u64;
        self.note_sent(now);
        Some(true)
    }

    fn finish_closing_if_drained(&mut self) {
        if self.state == State::Closing && self.close_written && self.in_flight == 0 {
            let error = self.closing_error;
            self.terminate(error, None);
        }
    }

    fn rekey_due(&self, now: Duration) -> bool {
        self.bytes_since_send_rekey >= self.config.rekey_after_bytes
            || now.saturating_sub(self.last_send_rekey_at) >= self.config.rekey_after
    }

    fn write_transport_plaintext(&mut self, plaintext: &[u8], now: Duration) -> bool {
        if !self.check_session_age(now) {
            return false;
        }
        if self.rekey_due(now) {
            // REKEY under the old key, then Rekey() on this direction: the peer switches at exactly this message.
            if !self.encrypt_and_write(&[FrameType::Rekey as u8], now) {
                return false;
            }
            if let Some(transport) = self.transport.as_mut() {
                transport.rekey_outgoing();
            }
            self.rekeys_sent += 1;
            self.bytes_since_send_rekey = 0;
            self.last_send_rekey_at = now;
        }
        if !self.encrypt_and_write(plaintext, now) {
            return false;
        }
        self.bytes_since_send_rekey += plaintext.len() as u64;
        true
    }

    fn encrypt_and_write(&mut self, plaintext: &[u8], now: Duration) -> bool {
        let encrypted = self.transport.as_mut().map(|transport| transport.encrypt(plaintext));
        let Some(Ok(message)) = encrypted else {
            // Only the reserved last nonce can fail here; a fresh Diffie-Hellman is the only way on.
            self.fail(SessionError::Expired, now);
            return false;
        };
        let mut bytes = Vec::with_capacity(2 + message.len());
        bytes.extend_from_slice(&(message.len() as u16).to_be_bytes());
        bytes.extend_from_slice(&message);
        self.in_flight += bytes.len();
        self.transmit.push_back(Transmit { bytes, counted: true });
        self.note_sent(now);
        true
    }

    pub(super) fn become_established(&mut self, now: Duration) {
        self.state = State::Established;
        self.established_at = now;
        self.last_send_rekey_at = now;
        if self.is_initiator() {
            // HELLO is the first transport frame, ahead of anything queued while the handshake ran.
            if let Ok(hello) = Frame::new(FrameType::Hello).encode() {
                self.control_queue.push_front(hello);
            }
        } else {
            // HELLO arrived. IK and XX told the listener at the key policy already; NN, which names nobody, only now.
            self.report_authenticated();
        }
        self.pump_writes(now);
        if self.state != State::Established {
            return;
        }
        self.events.push_back(Event::Established);
        self.advance_code_exchange(now);
    }

    /// `false` after closing the channel: past the maximum age both sides redial for a fresh Diffie-Hellman.
    pub(super) fn check_session_age(&mut self, now: Duration) -> bool {
        if !matches!(self.state, State::Established | State::Closing) {
            return self.state != State::Closed;
        }
        if now.saturating_sub(self.established_at) < self.config.max_age {
            return true;
        }
        if self.state == State::Established {
            self.terminate(Some(SessionError::Expired), Some(CloseReason::Expired as u8));
        } else {
            let error = self.closing_error.or(Some(SessionError::Expired));
            self.terminate(error, None);
        }
        false
    }

    pub(super) fn handle_transport_message(&mut self, message: &[u8], now: Duration) {
        if message.len() < NOISE_TAG_LEN {
            self.fail(SessionError::DecryptFailed, now);
            return;
        }
        let decrypted = self.transport.as_mut().map(|transport| transport.decrypt(message));
        self.handle_decrypted(decrypted, now);
    }

    /// Several complete transport messages at once (ADR 0018 § 9.2): opened together, on several cores when large,
    /// then handled one by one exactly as [`Self::handle_transport_message`] would. Returns how many were handled; the
    /// rest (after a REKEY, whose successors need the new key) go round again.
    pub(super) fn handle_transport_messages(&mut self, messages: &[&[u8]], now: Duration) -> usize {
        if messages.iter().any(|m| m.len() < NOISE_TAG_LEN) {
            self.handle_transport_message(messages[0], now);
            return 1;
        }
        let rekey = FrameType::Rekey as u8;
        let Some(transport) = self.transport.as_mut() else { return 0 };
        let opened = transport.decrypt_many(messages, |plaintext| plaintext.first() == Some(&rekey));
        let count = opened.len();
        for result in opened {
            if matches!(self.state, State::Closed | State::Refusing | State::Closing) {
                break;
            }
            self.handle_decrypted(Some(result), now);
        }
        count
    }

    fn handle_decrypted(&mut self, decrypted: Option<Result<Vec<u8>, NoiseError>>, now: Duration) {
        let plaintext = match decrypted {
            Some(Ok(plaintext)) => plaintext,
            // Tampered, replayed, reordered or truncated: there is no resynchronisation, and nothing said back would
            // help an attacker or a broken peer.
            Some(Err(NoiseError::Nonce)) => return self.fail(SessionError::Expired, now),
            _ => return self.fail(SessionError::DecryptFailed, now),
        };
        if self.state == State::Established && !self.check_session_age(now) {
            return;
        }
        match Frame::decode(&plaintext) {
            Ok(frame) => self.dispatch_frame(frame, now),
            Err(_) => self.protocol_failure(SessionError::FrameInvalid),
        }
    }

    fn dispatch_frame(&mut self, frame: Frame, now: Duration) {
        let frame_type = frame.frame_type;
        if self.state == State::AwaitingHello {
            if frame_type != FrameType::Hello {
                self.protocol_failure(SessionError::Protocol);
                return;
            }
            self.become_established(now);
            return;
        }
        match frame_type {
            FrameType::Hello => return self.protocol_failure(SessionError::Protocol),
            FrameType::Rekey => {
                if let Some(transport) = self.transport.as_mut() {
                    transport.rekey_incoming();
                }
                self.rekeys_received += 1;
                return;
            }
            FrameType::Ping => return,
            FrameType::Close => {
                let reason = frame.integer(tag::REASON).unwrap_or(CloseReason::Normal as u64) as u8;
                self.terminate(Some(SessionError::PeerClosed(reason)), None);
                return;
            }
            FrameType::CodeCommit | FrameType::CodeNonce | FrameType::CodeReveal => {
                self.handle_code_frame(&frame, now);
                return;
            }
            _ => {}
        }
        if !type_allowed(frame_type, self.pattern, !self.is_initiator())
            || (is_fast_transfer_frame(frame_type) && !self.fast_transfers())
            || (frame_type == FrameType::Boost && !self.direct_wifi_boost())
        {
            self.protocol_failure(SessionError::Protocol);
            return;
        }
        // One Add by ID exchange per NN session; a second would let one session multiply lookups or replies.
        let seen = match frame_type {
            FrameType::RequestById => Some(&mut self.received_request_by_id),
            FrameType::Received => Some(&mut self.received_received),
            _ => None,
        };
        if let Some(seen) = seen {
            if *seen {
                self.protocol_failure(SessionError::Protocol);
                return;
            }
            *seen = true;
        }
        self.events.push_back(Event::Frame(frame));
    }
}

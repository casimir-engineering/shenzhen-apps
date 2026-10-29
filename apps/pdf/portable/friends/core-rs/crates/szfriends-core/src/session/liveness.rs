//! Liveness while a transfer runs (ADR 0018 § 7). A route that goes out of range stays open to TCP and L2CAP for
//! minutes, so the session notices instead: its driver says when a transfer needs it ([`SecureChannel::set_liveness`]),
//! the channel sends PING after a second without sending anything, so the peer always hears something, and closes
//! after the silence limit without hearing a byte. Every minor knows PING and ignores it, so released peers simply
//! receive it; against them the driver watches only while their own traffic is due (PROGRESS for bytes sent, CHUNKs
//! for an incomplete file), which they send anyway.

use std::time::Duration;

use szfriends_wire::{Frame, FrameType, RouteMethod};

use super::channel::{SecureChannel, State};
use super::SessionError;

#[derive(Debug, Default)]
pub(super) struct Liveness {
    /// Send PING after `keepalive` without sending.
    keepalive: bool,
    /// Close after the silence limit without hearing anything.
    watch: bool,
    sent_at: Duration,
    heard_at: Duration,
    /// When the timers last ran: a longer gap is this side's own stall (a busy loop, sleep), not the peer's silence.
    checked_at: Option<Duration>,
}

impl SecureChannel {
    /// `keepalive`: a transfer runs on this session, so PING whenever this side sent nothing for a second. `watch`:
    /// something from the peer is due (PROGRESS for bytes in flight, the rest of a file being received), so hearing
    /// nothing for the silence limit closes the session ([`SessionError::Silent`]) and the driver redials. The limit
    /// counts from when watching starts. Call it whenever either changes; repeating the same values changes nothing.
    pub fn set_liveness(&mut self, keepalive: bool, watch: bool, now: Duration) {
        let live = &mut self.liveness;
        if keepalive && !live.keepalive {
            live.sent_at = live.sent_at.max(now.saturating_sub(self.config.keepalive));
        }
        if watch && !live.watch {
            live.heard_at = now;
            live.checked_at = Some(now);
        }
        live.keepalive = keepalive;
        live.watch = watch;
    }

    /// Whether the session is watching for silence (tests and logs).
    pub fn watching_liveness(&self) -> bool {
        self.liveness.watch
    }

    fn silence_limit(&self) -> Duration {
        if self.initiator_route == RouteMethod::Bluetooth {
            self.config.silence_bluetooth
        } else {
            self.config.silence
        }
    }

    pub(super) fn note_sent(&mut self, now: Duration) {
        self.liveness.sent_at = now;
    }

    pub(super) fn note_heard(&mut self, now: Duration) {
        self.liveness.heard_at = now;
    }

    /// The earlier of the next PING and the silence limit, while either is on.
    pub(super) fn liveness_deadline(&self) -> Option<Duration> {
        if self.state != State::Established {
            return None;
        }
        let live = &self.liveness;
        let ping = live.keepalive.then(|| live.sent_at + self.config.keepalive);
        // While watching, wake at least every keepalive, so a long gap between runs means this side stalled.
        let silence = live.watch.then(|| (live.heard_at + self.silence_limit()).min(self.timer_floor()));
        ping.into_iter().chain(silence).min()
    }

    fn timer_floor(&self) -> Duration {
        self.liveness.checked_at.unwrap_or_default() + self.config.keepalive
    }

    /// From `handle_timeout`, on an established session.
    pub(super) fn check_liveness(&mut self, now: Duration) {
        if self.state != State::Established {
            return;
        }
        let keepalive = self.config.keepalive;
        let limit = self.silence_limit();
        let live = &mut self.liveness;
        if live.watch {
            // This side did not run for a while (its loop was busy, or the device slept): whatever the peer sent
            // may still be waiting to be read, so its silence counts from now.
            if live.checked_at.is_some_and(|at| now.saturating_sub(at) > keepalive * 2) {
                live.heard_at = live.heard_at.max(now);
            }
            live.checked_at = Some(now);
            if now.saturating_sub(live.heard_at) >= limit {
                self.terminate(Some(SessionError::Silent), None);
                return;
            }
        }
        let live = &mut self.liveness;
        // One PING at a time: when the link takes nothing (a silent route), the next waits for another second.
        if live.keepalive && now.saturating_sub(live.sent_at) >= keepalive && self.control_queue.is_empty() {
            live.sent_at = now;
            self.enqueue_channel_frame(&Frame::new(FrameType::Ping));
            self.pump_writes(now);
        }
    }
}

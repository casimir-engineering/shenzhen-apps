//! The link's watchdog (ADR 0015 § 4): beside the connection loop, which may be blocked in a connect or a read, it
//! drops a connection whose helper stopped answering, keeps a ready link's heartbeat, and says Friends is unavailable
//! when no helper has worked for too long, so the panel never shows "Starting Friends…" or "Loading…" without end.

use std::time::{Duration, Instant};

use serde_json::Map;

use super::{log, Link, LinkState, STUCK_AFTER};

/// How long the link waits for the helper's answer: to its hello, and to the intents a view needs (subscribe,
/// ping…), which the service answers within milliseconds. Past it the helper has stopped answering (wedged, or a
/// lingering one from an earlier launch that never recovered): the link drops the connection, ends that helper
/// where it can ([`Connector::end_unresponsive`]) and connects again, which starts a new one.
#[derive(Clone, Copy, Debug)]
pub struct Patience {
    pub stuck_after: Duration,
    pub hello: Duration,
    pub intent: Duration,
    /// While ready, a `ping` this often, so a helper that stops answering is noticed with no view open.
    pub heartbeat: Duration,
}

impl Patience {
    pub const DEFAULT: Self = Self {
        stuck_after: STUCK_AFTER,
        hello: Duration::from_secs(10),
        intent: Duration::from_secs(15),
        heartbeat: Duration::from_secs(10),
    };
}

/// The intents the link expects answered within [`Patience::intent`]; others (a download link, a received link)
/// wait on the network by design.
pub(super) const WATCHED: &[&str] =
    &["subscribe", "unsubscribe", "open_conversation", "set_filter", "set_focus", "ping", "activate"];

impl Link {
    /// Watches the link from beside the connection loop, which may be blocked in a connect or a read: a hello or a
    /// watched intent left unanswered past its patience drops the connection (the loop then ends that helper and
    /// connects again), a ready link sends its heartbeat, and a link without a working helper for
    /// `stuck_after` says so (Unavailable) even while the loop is still waiting.
    pub(super) fn watch(&self, patience: Patience) {
        let tick = (patience.stuck_after / 8).clamp(Duration::from_millis(20), Duration::from_millis(500));
        while !self.stopped() {
            self.pause(tick);
            if self.stopped() {
                return;
            }
            let (stall, ping, stuck) = {
                let mut shared = self.0.shared.lock().unwrap_or_else(|e| e.into_inner());
                let state = shared.state.unwrap_or(LinkState::Idle);
                let hello_late =
                    state == LinkState::Handshaking && shared.hello_at.is_some_and(|at| at.elapsed() >= patience.hello);
                let intent_late =
                    state == LinkState::Ready && shared.outstanding.values().any(|at| at.elapsed() >= patience.intent);
                let stall = (hello_late || intent_late) && !shared.stalled;
                let mut stream = None;
                if stall {
                    shared.stalled = true;
                    stream = shared.stream.clone();
                }
                let ping = state == LinkState::Ready
                    && !shared.stalled
                    && shared.pinged_at.is_none_or(|at| at.elapsed() >= patience.heartbeat);
                if ping {
                    shared.pinged_at = Some(Instant::now());
                }
                let stuck = matches!(state, LinkState::Connecting | LinkState::Handshaking | LinkState::Waiting)
                    && shared.since.elapsed() >= patience.stuck_after;
                (stall.then_some((hello_late, stream)), ping, stuck)
            };
            if let Some((hello_late, stream)) = stall {
                log(if hello_late {
                    "the helper accepted the connection but never answered its hello"
                } else {
                    "the helper stopped answering"
                });
                if let Some(stream) = stream {
                    stream.close();
                }
            }
            if ping {
                let _ = self.send("ping", &Map::new());
            }
            if stuck {
                let trouble = self.trouble();
                self.set_unavailable(trouble, "no helper answered");
            }
        }
    }
}

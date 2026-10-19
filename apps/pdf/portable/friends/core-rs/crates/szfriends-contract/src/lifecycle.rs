//! PROTOCOL.md § Lifecycle and § Handshake: the decisions a desktop helper and its clients take about versions,
//! handover and exit, as pure functions of plain facts. They mirror the Objective-C helper's
//! `SZFriendsHelperPolicy.m` and the client library's backoff, so a Rust helper and an Objective-C one hand over to
//! each other by the same rules.

use std::time::Duration;

/// A client-protocol version, `major.minor`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct ProtocolVersion {
    pub major: i64,
    pub minor: i64,
}

/// The version this implementation speaks, and the lowest major it still accepts.
pub const PROTOCOL: ProtocolVersion = ProtocolVersion { major: 1, minor: 0 };
pub const PROTOCOL_MIN_MAJOR: i64 = 1;

/// The highest major both sides accept, then the lower minor for it; `None` when they share no major.
pub fn negotiate(
    helper: ProtocolVersion,
    helper_min_major: i64,
    client: ProtocolVersion,
    client_min_major: i64,
) -> Option<ProtocolVersion> {
    let sane = |v: ProtocolVersion, min: i64| v.major >= 1 && v.minor >= 0 && min >= 1 && min <= v.major;
    if !sane(helper, helper_min_major) || !sane(client, client_min_major) {
        return None;
    }
    let major = helper.major.min(client.major);
    if major < helper_min_major.max(client_min_major) {
        return None;
    }
    // A side whose own major is newer speaks the older major as it was frozen, which includes every minor the
    // older side can know: the older side's minor applies.
    let minor = match (helper.major == major, client.major == major) {
        (true, true) => helper.minor.min(client.minor),
        (true, false) => helper.minor,
        _ => client.minor,
    };
    Some(ProtocolVersion { major, minor })
}

/// Whether a client's embedded helper should replace the running one: by protocol major, then minor, then build.
/// Equal builds never hand over, so two apps embedding the same helper cannot ping-pong.
pub fn embedded_helper_is_newer(
    running: ProtocolVersion,
    running_build: u64,
    embedded: ProtocolVersion,
    embedded_build: u64,
) -> bool {
    (embedded.major, embedded.minor, embedded_build) > (running.major, running.minor, running_build)
}

/// A claimed successor build is plausible when its day (`YYMMDD` of a `YYMMDDNN` build number) is at most a year
/// after ours, so no client can name a build far in the future and keep every later helper stepping aside.
pub fn handover_build_is_plausible(running_build: u64, claimed_build: u64) -> bool {
    const DAY: u64 = 100;
    const YEAR: u64 = 10_000;
    claimed_build / DAY <= running_build / DAY + YEAR
}

/// Why the helper leaves, if it does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExitReason {
    /// Keep running.
    Stay,
    /// A newer helper takes over: `goodbye` with reason `handover` to every client.
    Handover,
    /// The last app with Friends on sent `disable`: persist and leave at once.
    Disabled,
    /// No client for the grace period.
    Idle,
    /// Nobody came after the start (the app that spawned the helper died first).
    NoClient,
}

/// What the lifecycle knows at one moment; durations are measured back from now.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LifecycleFacts {
    /// Connections that keep the helper alive: every accepted one except those that sent `disable`.
    pub clients: usize,
    pub since_start: Duration,
    pub ever_had_client: bool,
    /// Since the client count last fell to zero, while it stays there.
    pub since_last_client_left: Option<Duration>,
    /// The connection whose departure emptied the helper had sent `disable`.
    pub disabled_by_last_app: bool,
    pub since_handover_requested: Option<Duration>,
    /// A chunk in flight or a store transaction open.
    pub work_in_flight: bool,
}

/// The helper's timings (PROTOCOL.md § Lifecycle).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LifecyclePolicy {
    /// After the last client leaves.
    pub grace: Duration,
    /// After the start, when no client ever connected.
    pub first_client: Duration,
    /// The longest a handover waits for work in flight.
    pub handover_deadline: Duration,
}

impl Default for LifecyclePolicy {
    fn default() -> Self {
        Self {
            grace: Duration::from_secs(10),
            first_client: Duration::from_secs(30),
            handover_deadline: Duration::from_secs(5),
        }
    }
}

/// While a handover waits for work in flight, how often to look again.
pub const HANDOVER_POLL: Duration = Duration::from_millis(100);

impl LifecyclePolicy {
    pub fn exit_reason(&self, facts: &LifecycleFacts) -> ExitReason {
        // A handover goes ahead with clients connected: they reconnect to the successor. It waits only for work in
        // flight, and never past the deadline, since a stuck transfer resumes in the successor anyway.
        if let Some(waited) = facts.since_handover_requested {
            if !facts.work_in_flight || waited >= self.handover_deadline {
                return ExitReason::Handover;
            }
        }
        if facts.clients > 0 {
            return ExitReason::Stay;
        }
        if facts.ever_had_client {
            if facts.disabled_by_last_app {
                return ExitReason::Disabled;
            }
            return match facts.since_last_client_left {
                Some(left) if left >= self.grace => ExitReason::Idle,
                _ => ExitReason::Stay,
            };
        }
        if facts.since_start >= self.first_client {
            ExitReason::NoClient
        } else {
            ExitReason::Stay
        }
    }

    /// How long until the decision can next change by the clock alone; `None` when only an event can change it.
    pub fn next_evaluation(&self, facts: &LifecycleFacts) -> Option<Duration> {
        let mut next: Option<Duration> = None;
        let mut take = |d: Duration| next = Some(next.map_or(d, |n: Duration| n.min(d)));
        if let Some(waited) = facts.since_handover_requested {
            let left = self.handover_deadline.saturating_sub(waited);
            take(if facts.work_in_flight { left.min(HANDOVER_POLL) } else { left });
        }
        if facts.clients == 0 {
            if let Some(left) = facts.since_last_client_left {
                take(self.grace.saturating_sub(left));
            }
            if !facts.ever_had_client {
                take(self.first_client.saturating_sub(facts.since_start));
            }
        }
        next
    }
}

/// The client library's reconnect backoff: 50 ms first, doubling, capped at 2 s.
pub const RETRY_FIRST: Duration = Duration::from_millis(50);
pub const RETRY_CAP: Duration = Duration::from_millis(2000);
/// How long a client whose own helper is older than the successor waits for the successor before spawning its own.
pub const HANDOVER_WAIT: Duration = Duration::from_secs(10);

/// One retry's delay from the current base: the base plus up to a quarter of it (`random` picks how much), never
/// above the cap; and the base for the next retry, doubled up to the cap.
pub fn backoff(base: Duration, random: u32) -> (Duration, Duration) {
    let base_ms = base.as_millis().min(u128::from(u32::MAX)) as u64;
    let jitter = if base_ms >= 4 { u64::from(random) % (base_ms / 4 + 1) } else { 0 };
    let cap = RETRY_CAP.as_millis() as u64;
    let delay = (base_ms + jitter).min(cap);
    (Duration::from_millis(delay), Duration::from_millis((base_ms * 2).min(cap)))
}

/// What a client does after a `goodbye` with reason `handover`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AfterHandover {
    /// Its own embedded helper is at least the successor's build: spawn it now.
    SpawnNow,
    /// Wait this long for the successor to appear, then spawn its own (the newer app may have quit meanwhile).
    WaitForSuccessor(Duration),
}

pub fn after_handover(own_embedded_build: Option<u64>, successor_build: Option<u64>) -> AfterHandover {
    match (own_embedded_build, successor_build) {
        (Some(own), Some(successor)) if own >= successor => AfterHandover::SpawnNow,
        _ => AfterHandover::WaitForSuccessor(HANDOVER_WAIT),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const fn v(major: i64, minor: i64) -> ProtocolVersion {
        ProtocolVersion { major, minor }
    }

    #[test]
    fn negotiation_takes_the_highest_common_major_then_the_lower_minor() {
        assert_eq!(negotiate(v(1, 0), 1, v(1, 0), 1), Some(v(1, 0)));
        assert_eq!(negotiate(v(1, 3), 1, v(1, 1), 1), Some(v(1, 1)));
        assert_eq!(negotiate(v(2, 4), 1, v(1, 7), 1), Some(v(1, 7)), "the older side's minor");
        assert_eq!(negotiate(v(1, 7), 1, v(2, 0), 1), Some(v(1, 7)));
        assert_eq!(negotiate(v(1, 0), 1, v(3, 0), 2), None, "no common major");
        assert_eq!(negotiate(v(0, 0), 1, v(1, 0), 1), None);
        assert_eq!(negotiate(v(1, -1), 1, v(1, 0), 1), None);
        assert_eq!(negotiate(v(1, 0), 2, v(1, 0), 1), None, "min_major above major");
    }

    #[test]
    fn handover_goes_to_newer_builds_only() {
        assert!(embedded_helper_is_newer(v(1, 0), 26101201, v(1, 0), 26102001));
        assert!(!embedded_helper_is_newer(v(1, 0), 26101201, v(1, 0), 26101201), "same build");
        assert!(!embedded_helper_is_newer(v(1, 1), 26101201, v(1, 0), 26102001), "older minor wins nothing");
        assert!(embedded_helper_is_newer(v(1, 0), 26102001, v(2, 0), 1), "newer major");
        assert!(handover_build_is_plausible(26101201, 27101299));
        assert!(!handover_build_is_plausible(26101201, 27101300));
        assert!(handover_build_is_plausible(0, 1_000_099) && !handover_build_is_plausible(0, 1_000_100));
        assert!(handover_build_is_plausible(u64::MAX, u64::MAX), "no overflow");
    }

    #[test]
    fn the_helper_stays_while_anyone_needs_it() {
        let policy = LifecyclePolicy::default();
        let s = Duration::from_secs;
        let fresh = LifecycleFacts::default();
        assert_eq!(policy.exit_reason(&fresh), ExitReason::Stay);
        assert_eq!(policy.next_evaluation(&fresh), Some(s(30)));
        let unclaimed = LifecycleFacts { since_start: s(30), ..fresh };
        assert_eq!(policy.exit_reason(&unclaimed), ExitReason::NoClient);
        let serving = LifecycleFacts { clients: 2, ever_had_client: true, since_start: s(500), ..fresh };
        assert_eq!(policy.exit_reason(&serving), ExitReason::Stay);
        assert_eq!(policy.next_evaluation(&serving), None, "only an event changes it");
        let left = LifecycleFacts { clients: 0, since_last_client_left: Some(s(9)), ..serving };
        assert_eq!(policy.exit_reason(&left), ExitReason::Stay);
        assert_eq!(policy.next_evaluation(&left), Some(s(1)));
        assert_eq!(
            policy.exit_reason(&LifecycleFacts { since_last_client_left: Some(s(10)), ..left }),
            ExitReason::Idle
        );
        let disabled = LifecycleFacts { disabled_by_last_app: true, since_last_client_left: Some(s(0)), ..left };
        assert_eq!(policy.exit_reason(&disabled), ExitReason::Disabled);
    }

    #[test]
    fn a_handover_waits_for_work_in_flight_at_most_five_seconds() {
        let policy = LifecyclePolicy::default();
        let ms = Duration::from_millis;
        let busy = LifecycleFacts {
            clients: 3,
            ever_had_client: true,
            since_handover_requested: Some(ms(1000)),
            work_in_flight: true,
            ..Default::default()
        };
        assert_eq!(policy.exit_reason(&busy), ExitReason::Stay);
        assert_eq!(policy.next_evaluation(&busy), Some(HANDOVER_POLL));
        assert_eq!(policy.exit_reason(&LifecycleFacts { work_in_flight: false, ..busy }), ExitReason::Handover);
        let late = LifecycleFacts { since_handover_requested: Some(ms(5000)), ..busy };
        assert_eq!(policy.exit_reason(&late), ExitReason::Handover);
        let nearly = LifecycleFacts { since_handover_requested: Some(ms(4950)), ..busy };
        assert_eq!(policy.next_evaluation(&nearly), Some(ms(50)));
    }

    #[test]
    fn clients_back_off_and_follow_the_successor() {
        let ms = Duration::from_millis;
        assert_eq!(backoff(RETRY_FIRST, 0), (ms(50), ms(100)));
        assert_eq!(backoff(RETRY_FIRST, 12), (ms(62), ms(100)), "up to a quarter more");
        assert_eq!(backoff(RETRY_FIRST, 13), (ms(50), ms(100)), "wraps within the quarter");
        assert_eq!(backoff(ms(1600), 400), (ms(2000), ms(2000)), "never above the cap");
        assert_eq!(backoff(ms(2000), 0), (ms(2000), ms(2000)));
        assert_eq!(after_handover(Some(26102001), Some(26102001)), AfterHandover::SpawnNow);
        assert_eq!(after_handover(Some(26101201), Some(26102001)), AfterHandover::WaitForSuccessor(HANDOVER_WAIT));
        assert_eq!(after_handover(None, Some(1)), AfterHandover::WaitForSuccessor(HANDOVER_WAIT));
        assert_eq!(after_handover(Some(5), None), AfterHandover::WaitForSuccessor(HANDOVER_WAIT));
    }
}

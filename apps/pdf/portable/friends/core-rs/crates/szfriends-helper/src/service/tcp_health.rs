//! How much a lane's TCP connection retransmits (ADR 0018 § 7.2), read from its socket and handed to the scheduler,
//! which opens a second connection on a lossy LAN that moves under 70 % of its peak; and the scheduler's verdicts on
//! the lanes it tried, for helper.log. macOS and iOS read `TCP_CONNECTION_INFO`, Linux and Android `TCP_INFO`; other
//! platforms say nothing and the scheduler only sees rates. No traffic of ours: the kernel's own counters.

use szfriends_core::session::monotonic_now;
use szfriends_core::wire::RouteMethod;

use super::State;
use crate::log;

/// Bytes (or segments) sent and retransmitted so far on one connection.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Counters {
    pub sent: u64,
    pub retransmitted: u64,
}

/// A reading is worth a share only over at least this much sent (bytes on Apple platforms, segments elsewhere).
const MIN_SENT_APPLE: u64 = 256 << 10;
const MIN_SENT_SEGMENTS: u64 = 200;

/// The kernel's counters for the socket `fd`.
pub fn read(fd: i32) -> Option<Counters> {
    szfriends_helper_sys::tcp_info::counters(fd).map(|(sent, retransmitted)| Counters { sent, retransmitted })
}

/// The share retransmitted between two readings, once enough went out.
pub fn share(before: Counters, now: Counters) -> Option<f64> {
    let sent = now.sent.checked_sub(before.sent)?;
    let retransmitted = now.retransmitted.saturating_sub(before.retransmitted);
    let enough = if cfg!(any(target_os = "macos", target_os = "ios")) { MIN_SENT_APPLE } else { MIN_SENT_SEGMENTS };
    (sent >= enough).then(|| retransmitted as f64 / sent as f64)
}

impl State {
    /// Each sending group's LAN lanes: their retransmissions to the scheduler; its verdicts to helper.log.
    pub(crate) fn lane_health_tick(&mut self) {
        let now = monotonic_now();
        let heads: Vec<u64> = self.sessions.groups.schedules.keys().copied().collect();
        for head in heads {
            let lanes: Vec<u64> = self
                .sessions
                .groups
                .live_lanes(head, RouteMethod::Lan)
                .into_iter()
                .filter(|(_, route)| *route == RouteMethod::Lan)
                .map(|(id, _)| id)
                .collect();
            for id in lanes {
                let Some(session) = self.sessions.map.get_mut(&id) else { continue };
                let Some(counters) = session.meta.tcp_fd.and_then(read) else { continue };
                let before = session.meta.tcp_counters.unwrap_or(counters);
                let Some(share) = share(before, counters) else {
                    session.meta.tcp_counters.get_or_insert(counters);
                    continue;
                };
                session.meta.tcp_counters = Some(counters);
                if let Some(schedule) = self.sessions.groups.schedules.get_mut(&head) {
                    schedule.scheduler.retransmits(id, share, now);
                }
            }
            let Some(schedule) = self.sessions.groups.schedules.get_mut(&head) else { continue };
            for v in schedule.scheduler.take_verdicts() {
                log!(
                    "lane {} on {:?} {}: the group moved {:.1} MB/s before it, {:.1} MB/s with it",
                    v.lane,
                    v.route,
                    if v.kept { "helps, kept" } else { "did not help, closed" },
                    v.before / 1e6,
                    v.with / 1e6
                );
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_share_needs_enough_sent() {
        let a = Counters { sent: 0, retransmitted: 0 };
        assert_eq!(share(a, Counters { sent: 10, retransmitted: 1 }), None);
        let lots = Counters { sent: 10 << 20, retransmitted: 1 << 20 };
        assert!((share(a, lots).unwrap() - 0.1).abs() < 1e-9);
        assert_eq!(share(lots, a), None, "counters that went back (another socket): nothing");
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn a_connected_socket_reads() {
        use std::io::Write;
        use std::os::fd::AsRawFd;
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let mut client = std::net::TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let _server = listener.accept().unwrap();
        client.write_all(&[0u8; 4096]).unwrap();
        let counters = read(client.as_raw_fd()).expect("the kernel answers");
        assert!(counters.sent > 0 && counters.retransmitted == 0, "{counters:?}");
    }
}

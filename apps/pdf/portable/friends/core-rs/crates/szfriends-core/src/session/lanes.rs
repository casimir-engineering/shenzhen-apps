//! Lanes (ADR 0018 § 6): more Noise IK sessions with the same device of the same friend, bound to the first by a
//! token from its handshake hash, so one transfer runs on several connections and several routes at once. A
//! [`LaneGroup`] is the first session and its lanes; it decides, without any IO, which index a new outbound lane takes
//! and whether an inbound one is admitted, keeps the per-route limits, and says which lane carries control frames. Its
//! driver (the helper's session table) owns the sessions; the scheduler (WP2) sees lanes through [`LaneEvent`] and asks
//! for them through [`LaneRequest`].
//!
//! The rules, from the ADR:
//! - lane index 0 is the first session; lanes take 1 to 15, each index once per group;
//! - this side opens at most 4 lanes per route and 8 per group, and admits any of the 15 indexes; at most one session
//!   of the group, the first included, on the relay and on Bluetooth;
//! - a lane never races and never supersedes anything; when one closes the group goes on with the rest, and when the
//!   first session closes, the group ends (resume takes over on whatever session comes next);
//! - control frames and messages go on the best-ranked live lane: the route order, then the lowest index.

use std::collections::BTreeMap;

use szfriends_wire::RouteMethod;

/// Lane indexes a group can give: 1 to 15 (0 is the first session).
pub const LANE_INDEX_MAX: u8 = 15;
/// Lanes this side opens at most, per route and per group.
pub const LANES_PER_ROUTE: usize = 4;
pub const LANES_OPENED_PER_GROUP: usize = 8;

/// A lane as its driver knows it: the session id the driver gave it.
pub type LaneId = u64;

/// Routes that carry one session of a group at most, the first included: the relay (its cost, its 5 Mbit/s cap and
/// what it sees stay as they are) and Bluetooth (more would share one radio).
pub fn one_lane_only(route: RouteMethod) -> bool {
    matches!(route, RouteMethod::Relay | RouteMethod::Bluetooth | RouteMethod::None)
}

/// Why an inbound lane was refused (CLOSE reason 6, `lane refused`, a log value).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LaneRefusal {
    /// The token matches no index of this group.
    Token,
    /// That index is live already.
    InUse,
    /// The route carries one session at most (relay, Bluetooth) and has it.
    Full,
}

/// What the scheduler hears about lanes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LaneEvent {
    /// A lane went live (index 0 is the first session): parts may go on it.
    Up { lane: LaneId, index: u8, route: RouteMethod },
    /// A lane closed (or went silent and was closed): its unacknowledged blocks go back to the others.
    Down { lane: LaneId },
}

/// What the scheduler asks of lanes; the driver dials or closes, within the group's limits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LaneRequest {
    /// One more lane on this route (refused quietly past the limits).
    Open { route: RouteMethod },
    /// Close this lane (the first session closes only with the group).
    Close { lane: LaneId },
}

/// 0xff when `a` and `b` are equal, 0 otherwise, in time that depends only on their lengths.
fn same_bytes(a: &[u8], b: &[u8]) -> u8 {
    if a.len() != b.len() {
        return 0;
    }
    let difference = a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y));
    let difference = std::hint::black_box(difference);
    // 0 → 0xff, anything else → 0.
    (((u16::from(difference)).wrapping_sub(1) >> 8) & 0xff) as u8
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Lane {
    id: LaneId,
    route: RouteMethod,
    live: bool,
    outbound: bool,
}

/// The first session with one device of a friend, and its lanes.
pub struct LaneGroup {
    identity: [u8; 32],
    tokens: [[u8; 16]; LANE_INDEX_MAX as usize],
    lanes: BTreeMap<u8, Lane>,
    events: Vec<LaneEvent>,
}

impl std::fmt::Debug for LaneGroup {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LaneGroup").field("lanes", &self.lanes).finish_non_exhaustive()
    }
}

impl LaneGroup {
    /// The group of a live first session (one that negotiated fast transfers) with the device whose identity key is
    /// `identity`. `token` derives lane `index`'s token from that session's handshake hash
    /// (`transfer::lane_token(h, index)`); all fifteen are derived now, so admission compares in constant time.
    pub fn new(first: LaneId, identity: [u8; 32], route: RouteMethod, token: impl Fn(u8) -> [u8; 16]) -> Self {
        let mut tokens = [[0u8; 16]; LANE_INDEX_MAX as usize];
        for (slot, index) in tokens.iter_mut().zip(1..=LANE_INDEX_MAX) {
            *slot = token(index);
        }
        let mut lanes = BTreeMap::new();
        lanes.insert(0, Lane { id: first, route, live: true, outbound: false });
        let events = vec![LaneEvent::Up { lane: first, index: 0, route }];
        Self { identity, tokens, lanes, events }
    }

    pub fn identity(&self) -> &[u8; 32] {
        &self.identity
    }

    /// The first session's id.
    pub fn first(&self) -> LaneId {
        self.lanes[&0].id
    }

    pub fn contains(&self, lane: LaneId) -> bool {
        self.lanes.values().any(|l| l.id == lane)
    }

    fn route_taken(&self, route: RouteMethod) -> bool {
        one_lane_only(route) && self.lanes.values().any(|l| l.route == route)
    }

    /// Outbound: the index and token for one more lane on `route`, reserved until [`LaneGroup::lane_up`] or
    /// [`LaneGroup::lane_down`]; `None` past the limits.
    pub fn reserve(&mut self, lane: LaneId, route: RouteMethod) -> Option<(u8, [u8; 16])> {
        let opened = self.lanes.values().filter(|l| l.outbound).count();
        let on_route = self.lanes.values().filter(|l| l.route == route && l.outbound).count();
        if opened >= LANES_OPENED_PER_GROUP || on_route >= LANES_PER_ROUTE || self.route_taken(route) {
            return None;
        }
        let index = (1..=LANE_INDEX_MAX).find(|i| !self.lanes.contains_key(i))?;
        self.lanes.insert(index, Lane { id: lane, route, live: false, outbound: true });
        Some((index, self.tokens[usize::from(index) - 1]))
    }

    /// Inbound, at the responder's key policy (the initiator's static key already passed it): the lane index the
    /// presented token names, now reserved for this session; a refusal otherwise.
    pub fn admit(&mut self, lane: LaneId, token: &[u8], route: RouteMethod) -> Result<u8, LaneRefusal> {
        let mut found = 0u8;
        for (index, expected) in (1..=LANE_INDEX_MAX).zip(self.tokens.iter()) {
            found |= index & same_bytes(expected, token);
        }
        if found == 0 {
            return Err(LaneRefusal::Token);
        }
        if self.lanes.contains_key(&found) {
            return Err(LaneRefusal::InUse);
        }
        if self.route_taken(route) {
            return Err(LaneRefusal::Full);
        }
        self.lanes.insert(found, Lane { id: lane, route, live: false, outbound: false });
        Ok(found)
    }

    /// A reserved or admitted lane went live (its session established).
    pub fn lane_up(&mut self, lane: LaneId) {
        if let Some((index, entry)) = self.lanes.iter_mut().find(|(_, l)| l.id == lane && !l.live) {
            entry.live = true;
            self.events.push(LaneEvent::Up { lane, index: *index, route: entry.route });
        }
    }

    /// A lane closed or its dial failed; `true` when that ends the group (it was the first session).
    pub fn lane_down(&mut self, lane: LaneId) -> bool {
        let Some(index) = self.lanes.iter().find(|(_, l)| l.id == lane).map(|(i, _)| *i) else { return false };
        let entry = self.lanes.remove(&index).expect("found");
        if entry.live {
            self.events.push(LaneEvent::Down { lane });
        }
        index == 0
    }

    /// Live lanes: (id, index, route), in index order.
    pub fn live(&self) -> impl Iterator<Item = (LaneId, u8, RouteMethod)> + '_ {
        self.lanes.iter().filter(|(_, l)| l.live).map(|(i, l)| (l.id, *i, l.route))
    }

    /// Where control frames and messages go: the live lane whose route ranks best (`rank`, lower first, the owner's
    /// route order), then the lowest index.
    pub fn control_lane(&self, rank: impl Fn(RouteMethod) -> usize) -> LaneId {
        self.live().min_by_key(|(_, index, route)| (rank(*route), *index)).map_or(self.first(), |(id, _, _)| id)
    }

    /// What happened to lanes since the last call, for the scheduler.
    pub fn take_events(&mut self) -> Vec<LaneEvent> {
        std::mem::take(&mut self.events)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn token(index: u8) -> [u8; 16] {
        [index; 16]
    }

    fn group() -> LaneGroup {
        LaneGroup::new(100, [7; 32], RouteMethod::Lan, token)
    }

    #[test]
    fn outbound_lanes_take_free_indexes_within_the_limits() {
        let mut group = group();
        assert_eq!(group.take_events(), vec![LaneEvent::Up { lane: 100, index: 0, route: RouteMethod::Lan }]);
        let lan: Vec<_> = (0..5).map(|i| group.reserve(200 + i, RouteMethod::Lan)).collect();
        assert_eq!(lan[..4].iter().map(|r| r.unwrap().0).collect::<Vec<_>>(), vec![1, 2, 3, 4]);
        assert_eq!(lan[0].unwrap().1, token(1));
        assert_eq!(lan[4], None, "four per route");
        assert_eq!(group.reserve(300, RouteMethod::Relay).map(|r| r.0), Some(5));
        assert_eq!(group.reserve(301, RouteMethod::Relay), None, "one on the relay");
        assert_eq!(group.reserve(302, RouteMethod::Bluetooth).map(|r| r.0), Some(6));
        assert_eq!(group.reserve(303, RouteMethod::Bluetooth), None, "one on Bluetooth");
        assert!(group.reserve(304, RouteMethod::PeerToPeerWifi).is_some());
        assert!(group.reserve(305, RouteMethod::PeerToPeerWifi).is_some());
        assert_eq!(group.reserve(306, RouteMethod::Internet), None, "eight per group");
        // A failed dial frees its index for the next.
        assert!(!group.lane_down(201));
        assert_eq!(group.reserve(307, RouteMethod::Internet).map(|r| r.0), Some(2));
        assert!(group.take_events().is_empty(), "nothing went live");
    }

    #[test]
    fn inbound_lanes_need_a_token_of_this_group_for_a_free_index() {
        let mut group = group();
        assert_eq!(group.admit(1, &[0; 16], RouteMethod::Lan), Err(LaneRefusal::Token));
        assert_eq!(group.admit(1, &token(3)[..15], RouteMethod::Lan), Err(LaneRefusal::Token));
        assert_eq!(group.admit(1, &token(3), RouteMethod::Lan), Ok(3));
        assert_eq!(group.admit(2, &token(3), RouteMethod::Lan), Err(LaneRefusal::InUse));
        assert_eq!(group.admit(2, &token(15), RouteMethod::Bluetooth), Ok(15));
        assert_eq!(group.admit(3, &token(14), RouteMethod::Bluetooth), Err(LaneRefusal::Full));
        // Fifteen admitted at most: every index once.
        for index in [1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14] {
            assert_eq!(group.admit(u64::from(index) + 10, &token(index), RouteMethod::Lan), Ok(index));
        }
    }

    #[test]
    fn lanes_come_and_go_and_the_first_session_ends_the_group() {
        let mut group = group();
        group.take_events();
        let (index, _) = group.reserve(200, RouteMethod::PeerToPeerWifi).unwrap();
        group.admit(300, &token(9), RouteMethod::Bluetooth).unwrap();
        group.lane_up(200);
        group.lane_up(300);
        group.lane_up(300);
        assert_eq!(
            group.take_events(),
            vec![
                LaneEvent::Up { lane: 200, index, route: RouteMethod::PeerToPeerWifi },
                LaneEvent::Up { lane: 300, index: 9, route: RouteMethod::Bluetooth },
            ]
        );
        // The owner's order: direct Wi-Fi before the LAN, Bluetooth last.
        let rank = |route: RouteMethod| match route {
            RouteMethod::PeerToPeerWifi => 0,
            RouteMethod::Lan => 1,
            _ => 9,
        };
        assert_eq!(group.control_lane(rank), 200);
        assert!(!group.lane_down(200));
        assert_eq!(group.control_lane(rank), 100);
        assert_eq!(group.live().map(|l| l.1).collect::<Vec<_>>(), vec![0, 9]);
        assert!(group.lane_down(100), "the first session ends the group");
        assert_eq!(group.take_events(), vec![LaneEvent::Down { lane: 200 }, LaneEvent::Down { lane: 100 }]);
    }
}

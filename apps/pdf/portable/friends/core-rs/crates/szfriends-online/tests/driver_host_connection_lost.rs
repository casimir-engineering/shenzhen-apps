//! A host connection that ends while an attempt has no stream yet: a device checking in again for its person (after a
//! rename, say) or a host restarting. The attempt's sid ends with it. An answered offer used to carry on without a
//! sid, so it could never ask for the relay, and it kept the next offer either side made from being answered: the
//! session formed only after its direct phase failed and a backoff passed, over a minute later.

mod support;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use support::{stun_responder, Pair};

fn sid_of(pair: &Pair, side: usize) -> Option<String> {
    let peer = pair.sides[1 - side].key;
    pair.sides[side].driver.attempts().find(|a| a.peer() == peer).and_then(|a| a.sid().map(str::to_owned))
}

#[test]
fn an_answered_offer_whose_sid_ends_gives_way_to_the_next_offer() {
    let stun = (stun_responder(), stun_responder());
    let mut pair = Pair::new(Some(stun));
    // The side whose key sorts first offers: it is the one whose leftover offer would turn the other's new one away.
    let first = if pair.sides[0].key < pair.sides[1].key { 0 } else { 1 };
    let other = 1 - first;
    let blocked = Arc::new(AtomicBool::new(true));
    pair.block_direct(&blocked);
    pair.reach(first);
    let other_key = pair.sides[other].key;
    let answered = pair.run_until(Duration::from_secs(3), |p| {
        p.sides[first].driver.attempts().any(|a| a.peer() == other_key && a.answered())
    });
    assert!(answered, "the offer is answered");
    let sid = sid_of(&pair, first).expect("the answered offer's sid");
    // The other side's host connection ends: its sid ends there, and the host tells the offerer that end is gone.
    pair.end_sid(other, &sid);
    pair.end_sid(first, &sid);
    // Back on a new connection, on a network where direct connections work, the other side asks at once.
    blocked.store(false, Ordering::SeqCst);
    pair.reach(other);
    let opened = pair.run_until(Duration::from_secs(8), |p| p.sides.iter().all(|s| !s.streams.is_empty()));
    assert!(opened, "the new offer is answered and a stream opens within moments");
    drop(pair);
    assert!(szfriends_datachannel_sys::wait_released(Duration::from_secs(10)), "every handle is released");
}

#[test]
fn an_offer_cut_off_with_our_host_connection_is_made_again_once_checked_in() {
    let stun = (stun_responder(), stun_responder());
    let mut pair = Pair::new(Some(stun));
    let (us, them) = (0, 1);
    pair.away[them] = true;
    pair.reach(us);
    let waiting = pair.run_until(Duration::from_secs(3), |p| sid_of(p, us).is_some());
    assert!(waiting, "our offer has its sid");
    let sid = sid_of(&pair, us).expect("checked");
    // Our connection ends, and with it the sid: the offer ends as one nobody answered, with a wait.
    pair.end_sid(us, &sid);
    let them_key = pair.sides[them].key;
    assert!(!pair.sides[us].driver.has_attempt_for(&them_key), "the cut-off offer ended");
    // Checked in again on a new connection: the wait is over, as the Mac helper's driver does.
    pair.host_back(us);
    assert!(!pair.sides[us].driver.backed_off(&them_key), "a new host connection: no wait");
    pair.away[them] = false;
    pair.reach(us);
    let opened = pair.run_until(Duration::from_secs(8), |p| p.sides.iter().all(|s| !s.streams.is_empty()));
    assert!(opened, "asked again on the new connection, a stream opens within moments");
    drop(pair);
    assert!(szfriends_datachannel_sys::wait_released(Duration::from_secs(10)), "every handle is released");
}

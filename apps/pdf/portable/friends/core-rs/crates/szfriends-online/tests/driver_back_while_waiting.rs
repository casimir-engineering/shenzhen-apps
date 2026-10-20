//! The friend was away when we offered: our open reached nobody and waits for an answer that cannot come. They come
//! back and offer to us. When our key sorts first, the rule for both sides starting at once used to keep our dead
//! offer and drop theirs, so nothing connected until ours ran out (15 s) and the backoff after it (30 s, then
//! minutes). Their open shows they are here: we offer again at once, they answer, and a stream opens within moments.

mod support;

use std::time::{Duration, Instant};

use support::{stun_responder, Pair};

#[test]
fn an_offer_nobody_heard_gives_way_to_a_new_one_when_the_friend_offers() {
    let stun = (stun_responder(), stun_responder());
    let mut pair = Pair::new(Some(stun));
    let first = if pair.sides[0].key < pair.sides[1].key { 0 } else { 1 };
    let other = 1 - first;
    pair.away[other] = true;
    pair.reach(first);
    let other_key = pair.sides[other].key;
    let waiting = pair.run_until(Duration::from_secs(3), |p| {
        p.sides[first].driver.attempts().any(|a| a.peer() == other_key && a.sid().is_some())
    });
    assert!(waiting, "our offer has its sid and waits");
    pair.away[other] = false;
    pair.reach(other);
    let started = Instant::now();
    let opened = pair.run_until(Duration::from_secs(8), |p| p.sides.iter().all(|s| !s.streams.is_empty()));
    assert!(opened, "both sides open a stream within moments, not after the dead offer and a backoff");
    assert!(started.elapsed() < Duration::from_secs(8));
    assert!(pair.sides[first].streams[0].2, "the side whose key sorts first still offers");
    drop(pair);
    assert!(szfriends_datachannel_sys::wait_released(Duration::from_secs(10)), "every handle is released");
}

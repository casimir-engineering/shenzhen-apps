//! Two online drivers reach each other on 127.0.0.1: IK signalling through an in-memory host, the offer and answer
//! with their fingerprints, trickled candidates, and a data channel that carries bytes both ways; then every handle of
//! the stack is released once both drivers are gone, so the process ends with nothing of the stack running.

mod support;

use std::time::Duration;

use support::{stun_responder, Pair};
use szfriends_online::transport::{StreamInput, Technique};

#[test]
fn friends_reach_each_other_directly_and_exchange_bytes() {
    let stun = (stun_responder(), stun_responder());
    let mut pair = Pair::new(Some(stun));
    pair.reach(0);
    let opened = pair.run_until(Duration::from_secs(20), |p| p.sides.iter().all(|s| !s.streams.is_empty()));
    assert!(opened, "both sides open a stream");
    let (offerer, answerer) = (&pair.sides[0].streams[0], &pair.sides[1].streams[0]);
    assert!(offerer.2 && !answerer.2, "the offerer's side is the initiator");
    assert_ne!(offerer.1.technique, Technique::None);
    assert!(offerer.0.writer.write(b"hello from the offerer"));
    let got = answerer.0.incoming.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(got, StreamInput::Data(b"hello from the offerer".to_vec()));
    let big = vec![7u8; 200_000];
    assert!(answerer.0.writer.write(&big));
    let mut received = 0;
    while received < big.len() {
        match offerer.0.incoming.recv_timeout(Duration::from_secs(5)).unwrap() {
            StreamInput::Data(data) => received += data.len(),
            StreamInput::Closed => panic!("closed early"),
        }
    }
    assert_eq!(received, big.len());
    drop(pair);
    assert!(szfriends_datachannel_sys::wait_released(Duration::from_secs(10)), "every handle is released");
    assert!(szfriends_datachannel_sys::shutdown(Duration::from_secs(1)), "the stack ends cleanly");
}

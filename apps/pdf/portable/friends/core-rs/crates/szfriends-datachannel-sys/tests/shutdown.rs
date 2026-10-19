//! The end of the stack: a connection still open, a channel held on the release thread and the remote's channel are
//! all deleted before `shutdown` stops the stack, which then refuses new connections. Its own process, since the end
//! is process-wide (and the same `atexit` handler runs it at exit in every other suite).

mod support;

use std::time::Duration;

use support::{pump_pair, Peer};
use szfriends_datachannel_sys::{live_handles, release_in_background, shutdown, Config, Error, PeerConnection};

#[test]
fn the_stack_ends_after_its_last_handle() {
    let mut offerer = Peer::new("offerer", false);
    let mut answerer = Peer::new("answerer", true);
    offerer.open_channel();
    pump_pair(&mut offerer, &mut answerer, |a, b| a.open && b.open).expect("both sides open the channel");
    assert!(live_handles() >= 4, "two connections and a channel on each side");
    // One side goes to the release thread, the other is still held when the end begins.
    release_in_background(offerer);
    let held = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(300));
        drop(answerer);
    });
    assert!(shutdown(Duration::from_secs(10)), "every handle was deleted before the stack stopped");
    held.join().unwrap();
    assert_eq!(live_handles(), 0);
    assert!(matches!(PeerConnection::new(&Config::default()), Err(Error::NotAvailable)), "nothing starts again");
    assert!(shutdown(Duration::from_millis(10)), "a second end is harmless");
}

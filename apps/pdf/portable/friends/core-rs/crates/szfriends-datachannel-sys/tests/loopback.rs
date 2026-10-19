//! Two Rust peers in this process open a data channel over 127.0.0.1 and echo messages: libjuice's ICE checks,
//! Mbed TLS's DTLS handshake with certificate fingerprints, and usrsctp's association, all built by build.rs for the
//! target the test runs on. The same test runs on macOS, in the iOS simulator, on Android, and in the Windows and
//! Linux VMs (tools/run-device-tests.sh).

mod support;

use support::{pattern, pump_pair, Peer};
use szfriends_datachannel_sys::{check_layouts, mbedtls_version, sdp_fingerprint, sdp_mid, MESSAGE_MAX};

#[test]
fn structures_and_versions_match_the_pinned_sources() {
    check_layouts().expect("ffi.rs agrees with rtc.h");
    assert_eq!(mbedtls_version(), "3.6.7", "Mbed TLS's VENDORED.md pins 3.6.7");
}

#[test]
fn two_rust_peers_echo_over_loopback() {
    let mut offerer = Peer::new("offerer", false);
    let mut answerer = Peer::new("answerer", true);
    offerer.open_channel();
    pump_pair(&mut offerer, &mut answerer, |a, b| a.open && b.open).expect("both sides open the channel");

    for peer in [&offerer, &answerer] {
        let sdp = peer.local_sdp.as_deref().expect("a local description");
        assert!(sdp_fingerprint(sdp).is_some(), "{}: a SHA-256 fingerprint in the SDP", peer.name);
        assert!(sdp_mid(sdp).is_some(), "{}: one data-channel section", peer.name);
        assert!(!sdp.contains("a=candidate"), "{}: candidates trickle, never in the SDP", peer.name);
        let (local, remote) = peer.pc.selected_pair().expect("a selected pair");
        assert!(local.contains("127.0.0.1") && remote.contains("127.0.0.1"), "{local} / {remote}");
    }
    let channel = offerer.channel.as_ref().expect("the offerer's channel");
    assert_eq!(channel.max_message_size(), MESSAGE_MAX, "both sides offer the helper's 64 KiB");

    // Small and maximum-size messages, then 4 MiB in 64 KiB messages; the echo must match in order.
    let mut sent = Vec::new();
    let mut sizes = vec![1, 1000, MESSAGE_MAX];
    sizes.extend(std::iter::repeat_n(MESSAGE_MAX, 64));
    for (index, size) in sizes.iter().enumerate() {
        let message = pattern(*size, index as u32 + 1);
        channel.send(&message).expect("send");
        sent.extend_from_slice(&message);
    }
    let total = sent.len();
    pump_pair(&mut offerer, &mut answerer, |a, _| a.received.len() >= total).expect("every echo arrives");
    assert_eq!(offerer.received.len(), total);
    assert!(offerer.received == sent, "the echo matches byte for byte, in order");
    assert_eq!(answerer.messages, sizes.len(), "one message per send");

    // Larger than the peer accepts: refused by the stack, and the channel stays usable.
    let channel = offerer.channel.as_ref().expect("the offerer's channel");
    assert!(channel.send(&vec![0u8; MESSAGE_MAX + 1]).is_err(), "over a=max-message-size");
    channel.send(b"after").expect("still open");
    pump_pair(&mut offerer, &mut answerer, |a, _| a.received.len() >= total + 5).expect("the last echo");
    assert_eq!(&offerer.received[total..], b"after");
}

#[test]
fn a_wrong_answer_is_refused() {
    let mut offerer = Peer::new("offerer", false);
    offerer.open_channel();
    let deadline = std::time::Instant::now() + support::TIMEOUT;
    while offerer.local_sdp.is_none() && std::time::Instant::now() < deadline {
        offerer.pump(std::time::Duration::from_millis(10));
    }
    assert!(offerer.local_sdp.is_some(), "an offer");
    assert!(offerer.pc.set_remote_description("v=0\r\nnot an answer\r\n", "answer").is_err());
    assert!(offerer.pc.add_remote_candidate("candidate:nonsense", None).is_err());
}

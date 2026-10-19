//! A Rust peer against the Objective-C helper's own online transport (`tools/objc-dc-peer`, built by
//! `make friends-datachannel-rs-check`), each side offering once: the helper's description and candidate rules
//! accept what this crate's stack produces, and the two open a data channel over 127.0.0.1 and echo 4 MiB in order.
//! Without the peer program (`SZFRIENDS_DC_OBJC_PEER`, which only a Mac can build) the test says so and passes.

mod support;

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

use support::{pattern, Peer, Signal, TIMEOUT};
use szfriends_datachannel_sys::{sdp_fingerprint, sdp_mid, MESSAGE_MAX};

/// SZFriendsOnlineTechniqueHostPrivate: the helper reports loopback host pairs with it (testing configuration).
const TECHNIQUE_HOST_PRIVATE: &str = "2";

struct ObjcPeer {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
}

impl ObjcPeer {
    fn spawn(path: &std::ffi::OsStr, offer: bool) -> ObjcPeer {
        let mut child = Command::new(path)
            .args(if offer { &["offer"][..] } else { &[] })
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("the Objective-C peer starts");
        let stdin = child.stdin.take().expect("its stdin");
        let stdout = child.stdout.take().expect("its stdout");
        let (sender, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if sender.send(line).is_err() {
                    break;
                }
            }
        });
        ObjcPeer { child, stdin, lines }
    }

    fn say(&mut self, fields: &[&str]) {
        writeln!(self.stdin, "{}", fields.join(" ")).and_then(|_| self.stdin.flush()).expect("the peer reads");
    }
}

impl Drop for ObjcPeer {
    fn drop(&mut self) {
        // Only if the test failed before "close": the peer is this test's own child.
        if matches!(self.child.try_wait(), Ok(None)) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

fn text_from_hex(hex: &str) -> String {
    String::from_utf8(hex::decode(hex).expect("hex from the peer")).expect("UTF-8 from the peer")
}

/// Pumps the Rust peer and the Objective-C peer, forwarding signalling both ways, until `done` holds.
fn pump(rust: &mut Peer, objc: &mut ObjcPeer, objc_open: &mut bool, done: impl Fn(&Peer, bool) -> bool) {
    let deadline = Instant::now() + TIMEOUT;
    let mut remote_mid = None;
    while !done(rust, *objc_open) {
        for signal in rust.pump(Duration::from_millis(5)) {
            match signal {
                Signal::Description { sdp, kind } => {
                    // The fingerprint travels beside the SDP, as the authenticated exchange carries it.
                    let fingerprint = sdp_fingerprint(&sdp).expect("the description's fingerprint");
                    objc.say(&[&kind, &hex::encode(sdp), &hex::encode(fingerprint)]);
                }
                Signal::Candidate { candidate, .. } => objc.say(&["candidate", &hex::encode(candidate)]),
            }
        }
        while let Ok(line) = objc.lines.try_recv() {
            let fields: Vec<&str> = line.split(' ').collect();
            match fields.as_slice() {
                [kind @ ("offer" | "answer"), sdp, fingerprint] => {
                    let sdp = text_from_hex(sdp);
                    let fingerprint = hex::decode(fingerprint).expect("hex");
                    assert_eq!(Some(fingerprint.as_slice()), sdp_fingerprint(&sdp).as_ref().map(|f| &f[..]));
                    assert!(!sdp.contains("a=candidate"), "the helper's candidates trickle");
                    remote_mid = sdp_mid(&sdp);
                    rust.apply(Signal::Description { sdp, kind: (*kind).into() });
                }
                ["candidate", candidate, technique] => {
                    let candidate = text_from_hex(candidate);
                    assert!(candidate.contains(" 127.0.0.1 "), "loopback only: {candidate}");
                    assert_eq!(*technique, TECHNIQUE_HOST_PRIVATE);
                    rust.apply(Signal::Candidate { candidate, mid: remote_mid.clone() });
                }
                ["open", technique] => {
                    assert_eq!(*technique, TECHNIQUE_HOST_PRIVATE, "a direct loopback route");
                    *objc_open = true;
                }
                _ => panic!("the Objective-C peer: {line}"),
            }
        }
        if let Some(failure) = &rust.failure {
            panic!("the Rust peer: {failure}");
        }
        assert!(Instant::now() < deadline, "timed out (Rust open {}, Objective-C open {objc_open})", rust.open);
    }
}

fn echo_with_the_helper(objc_offers: bool) {
    let Some(path) = std::env::var_os("SZFRIENDS_DC_OBJC_PEER") else {
        eprintln!("skipped: SZFRIENDS_DC_OBJC_PEER is unset (make friends-datachannel-rs-check sets it on a Mac)");
        return;
    };
    let mut objc = ObjcPeer::spawn(&path, objc_offers);
    let mut rust = Peer::new("rust", false);
    let mut objc_open = false;
    if !objc_offers {
        rust.open_channel();
    }
    pump(&mut rust, &mut objc, &mut objc_open, |rust, objc_open| rust.open && objc_open);

    let channel = rust.channel.as_ref().expect("the Rust side's channel");
    assert_eq!(channel.max_message_size(), MESSAGE_MAX, "the helper offers 64 KiB too");
    let mut sent = Vec::new();
    let mut sizes = vec![1, 1000, MESSAGE_MAX];
    sizes.extend(std::iter::repeat_n(MESSAGE_MAX, 64));
    for (index, size) in sizes.iter().enumerate() {
        let message = pattern(*size, index as u32 + 7);
        channel.send(&message).expect("send");
        sent.extend_from_slice(&message);
    }
    let total = sent.len();
    pump(&mut rust, &mut objc, &mut objc_open, |rust, _| rust.received.len() >= total);
    assert!(rust.received == sent, "the helper's echo matches byte for byte, in order");

    objc.say(&["close"]);
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(status) = objc.child.try_wait().expect("the peer's status") {
            assert!(status.success(), "the Objective-C peer exits cleanly: {status}");
            break;
        }
        assert!(Instant::now() < deadline, "the Objective-C peer exits after close");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn a_rust_offerer_and_the_helpers_answer() {
    echo_with_the_helper(false);
}

#[test]
fn the_helpers_offer_and_a_rust_answerer() {
    echo_with_the_helper(true);
}

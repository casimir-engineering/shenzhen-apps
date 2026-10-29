//! The scenarios, each between any two peers (`crate::Peer`): a friend request over XX with comparison codes, Add by
//! ID over NN answered by the holder's IK callback, a file moved whole with its digest checked, a file resumed after
//! the route is cut and across rekeys, and a byte flipped anywhere in a session. Each panics with what went wrong.

use std::time::Duration;

use serde_json::{json, Value};
use szfriends_core::wire::{tag, Frame, FrameType};

use crate::{dial_ik, is_event, keys, listen, wait_for, write_content, Peer, Proxy, Tamper, TempHome};

const STEP: Duration = Duration::from_secs(20);

fn frame_hex(frame: &Frame) -> String {
    hex::encode(frame.encode().expect("a valid frame"))
}

/// Sends `frame` and returns the peer's reply: `{"sent": true}`, or `{"sent": false}` when the session is not open
/// (both peers answer the same for a session that has closed or never existed).
fn send(peer: &mut dyn Peer, session: u64, frame: &Frame) -> Value {
    peer.command(json!({ "cmd": "send", "session": session, "frame": frame_hex(frame) }))
}

/// Sends on a session that must be open.
#[track_caller]
fn deliver(peer: &mut dyn Peer, session: u64, frame: &Frame) {
    assert_eq!(send(peer, session, frame)["sent"], true, "send {frame:?}");
}

/// Sends on a session the other side may already have refused. A refused send counts only when the session's close
/// follows; the close stays in `seen` for the checks after it. True when the frame went out.
fn send_unless_closed(peer: &mut dyn Peer, seen: &mut Vec<Value>, session: u64, frame: &Frame) -> bool {
    let reply = send(peer, session, frame);
    if reply["sent"] == true {
        return true;
    }
    assert_eq!(reply["sent"], false, "send {frame:?}: {reply}");
    let closed = wait_for(peer, seen, STEP, "the close behind a refused send", is_event("closed", session));
    seen.push(closed);
    false
}

fn message(text: &str, id: u8) -> Frame {
    Frame::new(FrameType::Message)
        .with(tag::ID, [id; 16])
        .with(tag::SENT_AT, 1_791_787_668_000u64.to_be_bytes())
        .with(tag::TEXT, text.as_bytes())
}

/// The frame a `frame` event carries.
fn received(event: &Value) -> Frame {
    Frame::decode(&hex::decode(event["frame"].as_str().unwrap()).unwrap()).unwrap()
}

/// Both sides' comparison codes for `sessions` (initiator's, responder's), each asked once.
fn codes(a: &mut dyn Peer, b: &mut dyn Peer, sessions: (u64, u64), seen: (&mut Vec<Value>, &mut Vec<Value>)) {
    b.command(json!({ "cmd": "code", "session": sessions.1 }));
    a.command(json!({ "cmd": "code", "session": sessions.0 }));
    let code_a = wait_for(a, seen.0, STEP, "the initiator's code", is_event("code", sessions.0));
    let code_b = wait_for(b, seen.1, STEP, "the responder's code", is_event("code", sessions.1));
    assert!(code_a["code"].as_str().is_some_and(|c| c.len() == 6), "{code_a}");
    assert_eq!(code_a["code"], code_b["code"], "the codes must match");
}

/// A friend request on `responder`'s public entry: PROFILE and REQUEST, the ACK, both codes, the acceptance and a
/// presence secret, then the initiator says goodbye.
pub fn xx_request(initiator: &mut dyn Peer, responder: &mut dyn Peer) {
    let (ki, kr) = (keys(initiator), keys(responder));
    responder.command(json!({ "cmd": "public_profile", "name": "Bob" }));
    let port = listen(responder);
    let (mut seen_i, mut seen_r) = (Vec::new(), Vec::new());
    let session =
        initiator.command(json!({ "cmd": "dial", "port": port, "pattern": "XX" }))["session"].as_u64().unwrap();
    let live = wait_for(initiator, &mut seen_i, STEP, "XX going live", is_event("established", session));
    assert_eq!(live["remote_identity"], kr.identity.as_str());
    let accepted = wait_for(responder, &mut seen_r, STEP, "the responder going live", is_event("established", 0));
    assert_eq!(accepted["remote_identity"], ki.identity.as_str());
    let theirs = accepted["session"].as_u64().unwrap();
    let request_id = [0x42u8; 16];
    deliver(initiator, session, &Frame::new(FrameType::Profile).with(tag::NAME, *b"Alice"));
    let request = Frame::new(FrameType::Request)
        .with(tag::ID, request_id)
        .with(tag::SENT_AT, 1_791_787_668_000u64.to_be_bytes())
        .with(tag::TEXT, "Hi, it's Alice from the café".as_bytes());
    deliver(initiator, session, &request);
    let got = wait_for(responder, &mut seen_r, STEP, "the REQUEST", |e| e["event"] == "frame" && e["type"] == 4);
    assert_eq!(received(&got), request);
    deliver(responder, theirs, &Frame::new(FrameType::Ack).with(tag::ID, request_id));
    codes(initiator, responder, (session, theirs), (&mut seen_i, &mut seen_r));
    deliver(responder, theirs, &Frame::new(FrameType::Accept).with(tag::ID, request_id));
    let secret = Frame::new(FrameType::PresenceSecret).with(tag::ID, [7; 16]).with(tag::SECRET, [9; 32]);
    deliver(responder, theirs, &secret);
    let accept = wait_for(initiator, &mut seen_i, STEP, "the ACCEPT", |e| e["event"] == "frame" && e["type"] == 5);
    assert_eq!(received(&accept).get(tag::ID), Some(&request_id[..]));
    let got = wait_for(initiator, &mut seen_i, STEP, "the secret", |e| e["event"] == "frame" && e["type"] == 3);
    assert_eq!(received(&got), secret);
    initiator.command(json!({ "cmd": "close", "session": session }));
    let closed = wait_for(responder, &mut seen_r, STEP, "the goodbye", is_event("closed", theirs));
    assert_eq!((closed["error"].as_u64(), closed["reason"].as_u64()), (Some(7), Some(0)), "{closed}");
    wait_for(initiator, &mut seen_i, STEP, "the initiator's close", is_event("closed", session));
}

/// Add by ID nearby: `requester` asks over NN, `holder` answers RECEIVED and calls back over IK with the token, which
/// admits the requester's listener to an unknown key; the callback session runs the codes and carries the ACCEPT.
pub fn add_by_id(requester: &mut dyn Peer, holder: &mut dyn Peer) {
    let (kq, kh) = (keys(requester), keys(holder));
    let token = "a1".repeat(16);
    requester.command(json!({ "cmd": "issue_token", "token": token }));
    let requester_port = listen(requester);
    let holder_port = listen(holder);
    let (mut seen_q, mut seen_h) = (Vec::new(), Vec::new());
    let nn =
        requester.command(json!({ "cmd": "dial", "port": holder_port, "pattern": "NN" }))["session"].as_u64().unwrap();
    let live = wait_for(requester, &mut seen_q, STEP, "NN going live", is_event("established", nn));
    assert!(live["remote_identity"].is_null(), "NN names nobody");
    let sent = requester.command(json!({
        "cmd": "request_by_id", "session": nn, "friends_id": "maple-otter", "token": token, "callback": "c3".repeat(32),
    }));
    assert_eq!(sent["sent"], true);
    wait_for(requester, &mut seen_q, STEP, "RECEIVED", |e| e["event"] == "frame" && e["type"] == 8);
    let request = wait_for(holder, &mut seen_h, STEP, "the verified request", is_event("request_by_id", 0));
    assert_eq!(request["identity_key"], kq.identity.as_str());
    assert_eq!(
        (request["token"].as_str(), request["friends_id"].as_str()),
        (Some(token.as_str()), Some("maple-otter"))
    );
    requester.command(json!({ "cmd": "close", "session": nn }));
    let callback = holder.command(json!({
        "cmd": "dial", "port": requester_port, "pattern": "IK", "remote_static": request["static_key"],
        "expected_identity": request["identity_key"], "token": token,
    }))["session"]
        .as_u64()
        .unwrap();
    wait_for(holder, &mut seen_h, STEP, "the callback going live", is_event("established", callback));
    let admitted = wait_for(requester, &mut seen_q, STEP, "the callback admitted", |e| {
        e["event"] == "established" && e["pattern"] == "IK"
    });
    assert_eq!(
        (admitted["token"].as_str(), admitted["remote_identity"].as_str()),
        (Some(token.as_str()), Some(kh.identity.as_str()))
    );
    let theirs = admitted["session"].as_u64().unwrap();
    codes(holder, requester, (callback, theirs), (&mut seen_h, &mut seen_q));
    deliver(holder, callback, &Frame::new(FrameType::Accept).with(tag::ID, [0x51; 16]));
    wait_for(requester, &mut seen_q, STEP, "the ACCEPT", |e| e["event"] == "frame" && e["type"] == 5);
    holder.command(json!({ "cmd": "close", "session": callback }));
    wait_for(requester, &mut seen_q, STEP, "the callback's goodbye", is_event("closed", theirs));
}

/// What one file transfer ended as.
#[derive(Debug)]
pub struct Moved {
    pub resumed_at: Option<u64>,
    pub seconds: f64,
}

/// `sender` sends a `size`-byte file to `receiver` over IK; with `cut_after`, the route drops once that many bytes went
/// towards the receiver and the sender dials again, so the transfer resumes from the receiver's durable count. Both
/// sides rekey every `rekey_bytes`. The received file must hash to the sent one's digest.
pub fn transfer(
    sender: &mut dyn Peer,
    receiver: &mut dyn Peer,
    size: u64,
    rekey_bytes: u64,
    cut_after: Option<u64>,
) -> Moved {
    let started = std::time::Instant::now();
    let home = TempHome::new("content");
    let path = home.path().join("Site photos.bin");
    let digest = write_content(&path, "interop content", size);
    let (ks, kr) = (keys(sender), keys(receiver));
    crate::befriend(sender, receiver, ("Sender", "Receiver"));
    sender.command(json!({ "cmd": "set_rekey", "bytes": rekey_bytes }));
    receiver.command(json!({ "cmd": "set_rekey", "bytes": rekey_bytes }));
    let port = listen(receiver);
    let proxy = Proxy::start(port);
    proxy.set(Tamper { cut_to_listener_after: cut_after, ..Tamper::default() });
    let (mut seen_s, mut seen_r) = (Vec::new(), Vec::new());
    let session = dial_ik(sender, proxy.port(), &kr);
    wait_for(sender, &mut seen_s, STEP, "IK going live", is_event("established", session));
    let accepted = wait_for(receiver, &mut seen_r, STEP, "the receiver going live", is_event("established", 0));
    assert_eq!(accepted["remote_identity"], ks.identity.as_str());
    let offer = sender.command(json!({ "cmd": "send_file", "session": session, "path": path.to_string_lossy() }));
    let transfer_id = offer["transfer"].as_str().expect("a transfer").to_owned();
    assert_eq!(offer["digest"], hex::encode(digest));
    let (mut resumed_at, mut active) = (None, session);
    if cut_after.is_some() {
        wait_for(sender, &mut seen_s, Duration::from_secs(120), "the cut", is_event("closed", session));
        wait_for(receiver, &mut seen_r, STEP, "the cut at the receiver", is_event("closed", 0));
        let partial = receiver.command(json!({ "cmd": "transfer", "id": transfer_id }));
        let verified = partial["verified"].as_u64().unwrap();
        assert!(verified > 0 && verified < size, "the receiver kept a durable part: {partial}");
        proxy.set(Tamper::default());
        let again = dial_ik(sender, proxy.port(), &kr);
        active = again;
        let resumed = wait_for(sender, &mut seen_s, STEP, "the resume", is_event("sending", again));
        let offset = resumed["offset"].as_u64().unwrap();
        if resumed["blocks"] == true {
            // By blocks (ADR 0018 § 3): from the first byte still missing, which the durable count may trail by
            // blocks complete but not yet durable, and pieces of a block that arrived.
            assert!(offset >= verified, "the sender continues past the receiver's durable count: {offset} {verified}");
        } else {
            assert_eq!(offset, verified, "the sender continues from the receiver's durable count");
        }
        resumed_at = Some(offset);
    }
    let long = Duration::from_secs(600);
    let done = wait_for(receiver, &mut seen_r, long, "the received file", is_event("received_file", 0));
    assert_eq!(done["transfer"], transfer_id.as_str());
    let received_path = std::path::PathBuf::from(done["path"].as_str().unwrap());
    let got = szfriends_core::store::file_digest(&received_path, u64::MAX).expect("the received file reads");
    assert_eq!(got, digest, "the received file hashes to the offered digest");
    assert_eq!(std::fs::metadata(&received_path).unwrap().len(), size);
    wait_for(sender, &mut seen_s, STEP, "the delivery", is_event("delivered", 0));
    // The session that carried the file (the second, after a cut) rekeyed all along, both ways' sending keys moving
    // in step: the receiver took the sender's REKEY at least once per `rekey_bytes` of what this session carried.
    let carried = size - resumed_at.unwrap_or(0);
    sender.command(json!({ "cmd": "close", "session": active }));
    let ended = wait_for(sender, &mut seen_s, STEP, "the sender's goodbye", is_event("closed", active));
    let received_end =
        wait_for(receiver, &mut seen_r, STEP, "the receiver's goodbye", |e| e["event"] == "closed" && e["error"] == 7);
    let sent_rekeys = ended["rekeys"][0].as_u64().unwrap();
    assert_eq!(received_end["rekeys"][1].as_u64(), Some(sent_rekeys), "both sides switched keys at the same frames");
    assert!(sent_rekeys + 1 >= carried / rekey_bytes, "{sent_rekeys} rekeys for {carried} bytes");
    assert_eq!(sender.command(json!({ "cmd": "transfer", "id": transfer_id }))["state"], 5, "Delivered");
    assert_eq!(receiver.command(json!({ "cmd": "transfer", "id": transfer_id }))["state"], 6, "Received");
    Moved { resumed_at, seconds: started.elapsed().as_secs_f64() }
}

/// One IK session through the proxy with one byte flipped at `flip`: the peer the flipped byte reaches must never
/// deliver the message it was part of, and must end the session with an error. Returns the bytes that passed each
/// way before the goodbyes (dialer to listener, listener to dialer).
pub fn tampered_session(
    dialer: &mut dyn Peer,
    listener: &mut dyn Peer,
    proxy: &Proxy,
    flip: Tamper,
) -> ((u64, u64), Ending) {
    let kl = keys(listener);
    while dialer.next_event(Duration::from_millis(200)).is_some() {}
    while listener.next_event(Duration::from_millis(200)).is_some() {}
    proxy.set(flip);
    let (mut seen_d, mut seen_l) = (Vec::new(), Vec::new());
    let session = dial_ik(dialer, proxy.port(), &kl);
    let accepted = wait_for(listener, &mut seen_l, STEP, "the connection", is_event("accepted", 0));
    let theirs = accepted["session"].as_u64().unwrap();
    let quick = Duration::from_secs(5);
    let (to_listener, to_dialer) = (message("to the listener", 1), message("to the dialer", 2));
    // Each side either goes live or ends; whatever ends it stays in `seen` for the checks below.
    let live_or_closed = |session: u64| {
        move |e: &Value| (e["event"] == "established" || e["event"] == "closed") && e["session"] == session
    };
    let dialer_live = peek(dialer, &mut seen_d, quick, live_or_closed(session));
    let dialer_live = match dialer_live {
        Some(event) if event["event"] == "established" => true,
        other => {
            seen_d.extend(other);
            false
        }
    };
    if dialer_live {
        send_unless_closed(dialer, &mut seen_d, session, &to_listener);
    }
    let listener_live = match peek(listener, &mut seen_l, quick, live_or_closed(theirs)) {
        Some(event) if event["event"] == "established" => true,
        other => {
            seen_l.extend(other);
            false
        }
    };
    if listener_live {
        send_unless_closed(listener, &mut seen_l, theirs, &to_dialer);
    }
    // Kept, not consumed: the checks below read every message each side delivered.
    let message_or_closed = |session: u64| {
        move |e: &Value| {
            (e["event"] == "frame" && e["type"] == 12) || (e["event"] == "closed" && e["session"] == session)
        }
    };
    if listener_live {
        let got = peek(listener, &mut seen_l, quick, message_or_closed(theirs));
        seen_l.extend(got);
    }
    if dialer_live {
        let got = peek(dialer, &mut seen_d, quick, message_or_closed(session));
        seen_d.extend(got);
    }
    let counts = proxy.counts();
    dialer.command(json!({ "cmd": "close", "session": session }));
    listener.command(json!({ "cmd": "close", "session": theirs }));
    let long = Duration::from_secs(15);
    let dialer_end = wait_for(dialer, &mut seen_d, long, "the dialer's end", is_event("closed", session));
    let listener_end = wait_for(listener, &mut seen_l, long, "the listener's end", is_event("closed", theirs));
    let messages = |seen: &[Value]| -> Vec<Frame> {
        seen.iter().filter(|e| e["event"] == "frame" && e["type"] == 12).map(received).collect()
    };
    let (at_dialer, at_listener) = (messages(&seen_d), messages(&seen_l));
    assert!(at_listener.iter().all(|f| *f == to_listener), "the listener took a changed message: {flip:?}");
    assert!(at_dialer.iter().all(|f| *f == to_dialer), "the dialer took a changed message: {flip:?}");
    // The recipient of the flipped byte refuses: it never takes the message the byte was part of. It ends with an
    // error, or, when the flip made a length prefix promise more bytes than come, waits until the session is closed.
    let refused = |end: &Value| if end["error"] == 0 { Ending::Stalled } else { Ending::Error };
    let mut ending = Ending::Honest;
    if flip.flip_to_listener.is_some() {
        assert!(at_listener.is_empty(), "the listener took a tampered session's message: {flip:?}");
        ending = refused(&listener_end);
    }
    if flip.flip_to_dialer.is_some() {
        assert!(at_dialer.is_empty(), "the dialer took a tampered session's message: {flip:?}");
        ending = refused(&dialer_end);
    }
    if flip == Tamper::default() {
        assert_eq!((at_dialer.len(), at_listener.len()), (1, 1), "the honest session carries both messages");
    }
    (counts, ending)
}

/// A send on a session that has closed, or never existed, is answered `{"sent": false}` by either peer, at either end.
pub fn send_after_close(dialer: &mut dyn Peer, listener: &mut dyn Peer) {
    crate::befriend(dialer, listener, ("Dialer", "Listener"));
    let port = listen(listener);
    let (mut seen_d, mut seen_l) = (Vec::new(), Vec::new());
    let session = dial_ik(dialer, port, &keys(listener));
    wait_for(dialer, &mut seen_d, STEP, "the dialer going live", is_event("established", session));
    let theirs = wait_for(listener, &mut seen_l, STEP, "the listener going live", is_event("established", 0));
    let theirs = theirs["session"].as_u64().unwrap();
    dialer.command(json!({ "cmd": "close", "session": session }));
    wait_for(listener, &mut seen_l, STEP, "the listener's close", is_event("closed", theirs));
    wait_for(dialer, &mut seen_d, STEP, "the dialer's close", is_event("closed", session));
    let refused = json!({ "sent": false });
    assert_eq!(send(dialer, session, &message("after the close", 3)), refused, "the dialer");
    assert_eq!(send(listener, theirs, &message("after the close", 4)), refused, "the listener");
    assert_eq!(send(dialer, u64::from(u32::MAX), &message("nobody", 5)), refused, "a session that never existed");
}

/// How a session with one byte flipped ended at the side the byte reached.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ending {
    Honest,
    Error,
    Stalled,
}

/// Like `wait_for`, but `None` instead of panicking.
fn peek(
    peer: &mut dyn Peer,
    seen: &mut Vec<Value>,
    timeout: Duration,
    matches: impl Fn(&Value) -> bool,
) -> Option<Value> {
    if let Some(index) = seen.iter().position(&matches) {
        return Some(seen.remove(index));
    }
    let deadline = std::time::Instant::now() + timeout;
    while let Some(left) = deadline.checked_duration_since(std::time::Instant::now()) {
        match peer.next_event(left) {
            Some(event) if matches(&event) => return Some(event),
            Some(event) => seen.push(event),
            None => break,
        }
    }
    None
}

/// Flips `samples` bytes spread over each direction of an honest session, and each preamble byte; returns how the
/// tampered sessions ended (errors, stalls). Most must end in an error: only a flipped length prefix can stall.
pub fn tamper_everywhere(dialer: &mut dyn Peer, listener: &mut dyn Peer, samples: u64) -> (usize, usize) {
    crate::befriend(dialer, listener, ("Dialer", "Listener"));
    let port = listen(listener);
    let proxy = Proxy::start(port);
    let ((to_listener, to_dialer), _) = tampered_session(dialer, listener, &proxy, Tamper::default());
    let mut positions: Vec<Tamper> =
        (0..4).map(|i| Tamper { flip_to_listener: Some(i), ..Tamper::default() }).collect();
    for i in 0..samples {
        positions.push(Tamper { flip_to_listener: Some(4 + i * (to_listener - 4) / samples), ..Tamper::default() });
        positions.push(Tamper { flip_to_dialer: Some(i * to_dialer / samples), ..Tamper::default() });
    }
    let (mut errors, mut stalls) = (0, 0);
    for flip in positions {
        match tampered_session(dialer, listener, &proxy, flip).1 {
            Ending::Error => errors += 1,
            Ending::Stalled => stalls += 1,
            Ending::Honest => unreachable!("every run flips a byte"),
        }
    }
    assert!(errors > 3 * stalls, "too many stalls: {errors} errors, {stalls} stalls");
    (errors, stalls)
}

/// Route migration (ADR 0001 § Resume and route migration): a file starts on a slow route; when a faster one is up,
/// the old session closes as superseded and the new one resumes the file from the receiver's durable count.
pub fn migrate_route(sender: &mut dyn Peer, receiver: &mut dyn Peer, size: u64) -> u64 {
    let home = TempHome::new("content");
    let path = home.path().join("Plan.bin");
    let digest = write_content(&path, "migration content", size);
    let kr = keys(receiver);
    crate::befriend(sender, receiver, ("Sender", "Receiver"));
    let port = listen(receiver);
    let slow = Proxy::start(port);
    slow.set(Tamper { bytes_per_second: Some(4 << 20), ..Tamper::default() });
    let (mut seen_s, mut seen_r) = (Vec::new(), Vec::new());
    let first = dial_ik(sender, slow.port(), &kr);
    wait_for(sender, &mut seen_s, STEP, "the slow route going live", is_event("established", first));
    let offer = sender.command(json!({ "cmd": "send_file", "session": first, "path": path.to_string_lossy() }));
    let transfer_id = offer["transfer"].as_str().expect("a transfer").to_owned();
    let deadline = std::time::Instant::now() + STEP;
    while receiver.command(json!({ "cmd": "transfer", "id": transfer_id }))["verified"].as_u64().unwrap_or(0) == 0 {
        assert!(std::time::Instant::now() < deadline, "nothing became durable on the slow route");
        std::thread::sleep(Duration::from_millis(100));
    }
    // The faster route won the race: the loser says so and goes; the winner carries the rest.
    sender.command(json!({ "cmd": "close", "session": first, "reason": 2 }));
    let superseded = wait_for(receiver, &mut seen_r, STEP, "the superseded session", is_event("closed", 0));
    assert_eq!((superseded["error"].as_u64(), superseded["reason"].as_u64()), (Some(7), Some(2)), "{superseded}");
    let fast = dial_ik(sender, port, &kr);
    let resumed = wait_for(sender, &mut seen_s, STEP, "the resume on the fast route", is_event("sending", fast));
    let offset = resumed["offset"].as_u64().unwrap();
    assert!(offset > 0 && offset < size, "resumed at {offset}");
    let done = wait_for(receiver, &mut seen_r, Duration::from_secs(300), "the file", is_event("received_file", 0));
    let received = std::path::PathBuf::from(done["path"].as_str().unwrap());
    assert_eq!(szfriends_core::store::file_digest(&received, u64::MAX).unwrap(), digest);
    wait_for(sender, &mut seen_s, STEP, "the delivery", is_event("delivered", 0));
    offset
}

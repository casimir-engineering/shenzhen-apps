//! The online scenarios between any two peers (`crate::Peer`) through the local Node host (`crate::host`): both check
//! in, one reaches the other by rendezvous key, the driver opens a data channel (direct, or with direct paths blocked
//! on both sides, through coturn), and an ADR 0001 session over it carries a message each way and a file whose digest
//! is checked. Each panics with what went wrong.

use std::time::{Duration, Instant};

use serde_json::{json, Value};
use szfriends_core::wire::{tag, Frame, FrameType};

use crate::host::LocalHost;
use std::path::Path;

use crate::{is_event, keys, wait_for, write_content, Keys, Peer, TempHome};

const STEP: Duration = Duration::from_secs(30);

/// What one run showed.
#[derive(Debug)]
pub struct OnlineRun {
    pub route: String,
    pub seconds_to_session: f64,
    pub file_seconds: f64,
    pub bits_per_second: f64,
}

fn secret() -> String {
    let mut bytes = [0u8; 32];
    szfriends_core::crypto::random_bytes(&mut bytes);
    hex::encode(bytes)
}

fn message(text: &str, id: u8) -> Frame {
    Frame::new(FrameType::Message)
        .with(tag::ID, [id; 16])
        .with(tag::SENT_AT, 1_791_787_668_000u64.to_be_bytes())
        .with(tag::TEXT, text.as_bytes())
}

fn send(peer: &mut dyn Peer, session: u64, frame: &Frame) {
    let encoded = hex::encode(frame.encode().expect("a valid frame"));
    let reply = peer.command(json!({ "cmd": "send", "session": session, "frame": encoded }));
    assert_eq!(reply["sent"], true, "send {frame:?}: {reply}");
}

fn go_online(peer: &mut dyn Peer, host: &LocalHost, own: &str, them: &Keys, their: &str, relayed: bool, home: &Path) {
    let friend = json!({ "identity_key": them.identity, "static_key": them.static_key, "presence_secret": their });
    let reply = peer.command(json!({
        "cmd": "online", "list": host.list_path, "keys": host.keys_path, "friends": [friend],
        "presence_secret": own, "block_direct": relayed, "home": home,
    }));
    assert!(reply.get("error").is_none(), "online: {reply}");
}

/// Both peers online through `host`, friends of each other; `offerer` reaches `answerer`. With `relayed`, neither
/// side sends or applies a direct candidate, so only the relay can connect. `file_size` bytes then move whole.
pub fn online_session(
    offerer: &mut dyn Peer,
    answerer: &mut dyn Peer,
    host: &LocalHost,
    relayed: bool,
    file_size: u64,
) -> OnlineRun {
    let (ko, ka) = (keys(offerer), keys(answerer));
    crate::befriend(offerer, answerer, ("Offerer", "Answerer"));
    let (so, sa) = (secret(), secret());
    let homes = (TempHome::new("online-o"), TempHome::new("online-a"));
    go_online(offerer, host, &so, &ka, &sa, relayed, homes.0.path());
    go_online(answerer, host, &sa, &ko, &so, relayed, homes.1.path());
    let (mut seen_o, mut seen_a) = (Vec::new(), Vec::new());
    let online = |e: &Value| e["event"] == "online" && e["available"] == true;
    wait_for(offerer, &mut seen_o, STEP, "the offerer online", online);
    wait_for(answerer, &mut seen_a, STEP, "the answerer online", online);
    // A friend is reached through the rendezvous record it published on coming online: give the answerer's first
    // record a moment to reach the host (a reach before it finds nobody, and the driver then backs off, as it should).
    std::thread::sleep(Duration::from_millis(1500));
    let started = Instant::now();
    offerer.command(json!({ "cmd": "reach", "identity_key": ka.identity }));
    let budget = if relayed { Duration::from_secs(60) } else { STEP };
    let stream_o = wait_for(offerer, &mut seen_o, budget, "the offerer's stream", |e| e["event"] == "online_stream");
    let stream_a = wait_for(answerer, &mut seen_a, budget, "the answerer's stream", |e| e["event"] == "online_stream");
    let route = if relayed { "relay" } else { "internet" };
    assert_eq!((stream_o["route"].as_str(), stream_o["initiator"].as_bool()), (Some(route), Some(true)), "{stream_o}");
    assert_eq!((stream_a["route"].as_str(), stream_a["initiator"].as_bool()), (Some(route), Some(false)), "{stream_a}");
    let (session_o, session_a) = (stream_o["session"].as_u64().unwrap(), stream_a["session"].as_u64().unwrap());
    let live_o = wait_for(offerer, &mut seen_o, STEP, "the offerer's session", is_event("established", session_o));
    let live_a = wait_for(answerer, &mut seen_a, STEP, "the answerer's session", is_event("established", session_a));
    assert_eq!(live_a["remote_identity"], ko.identity.as_str());
    assert_eq!(live_o["remote_identity"], ka.identity.as_str());
    let expected_route = if relayed { 5 } else { 4 };
    assert_eq!(live_a["route"], expected_route, "the session carries the online route class");
    let seconds_to_session = started.elapsed().as_secs_f64();
    send(offerer, session_o, &message("Hello over the Internet", 1));
    let got = wait_for(answerer, &mut seen_a, STEP, "the message", |e| {
        e["event"] == "frame" && e["type"] == FrameType::Message as u8
    });
    assert_eq!(got["session"], session_a);
    send(answerer, session_a, &message("And back", 2));
    wait_for(offerer, &mut seen_o, STEP, "the reply", |e| {
        e["event"] == "frame" && e["type"] == FrameType::Message as u8
    });
    let content = TempHome::new("online-content");
    let path = content.path().join("Site photos.bin");
    let digest = write_content(&path, "online content", file_size);
    let file_started = Instant::now();
    let offer = offerer.command(json!({ "cmd": "send_file", "session": session_o, "path": path.to_string_lossy() }));
    assert_eq!(offer["digest"], hex::encode(digest), "{offer}");
    let long = Duration::from_secs(300);
    let done = wait_for(answerer, &mut seen_a, long, "the received file", |e| e["event"] == "received_file");
    let file_seconds = file_started.elapsed().as_secs_f64();
    let received = std::path::PathBuf::from(done["path"].as_str().unwrap());
    let got = szfriends_core::store::file_digest(&received, u64::MAX).expect("the received file reads");
    assert_eq!(got, digest, "the received file hashes to the offered digest");
    wait_for(offerer, &mut seen_o, STEP, "the delivery", |e| e["event"] == "delivered");
    offerer.command(json!({ "cmd": "close", "session": session_o }));
    OnlineRun {
        route: route.into(),
        seconds_to_session,
        file_seconds,
        bits_per_second: file_size as f64 * 8.0 / file_seconds.max(1e-6),
    }
}

fn link_online(peer: &mut dyn Peer, host: &LocalHost, relayed: bool, home: &Path) {
    let reply = peer.command(json!({
        "cmd": "online", "list": host.list_path, "keys": host.keys_path, "friends": [],
        "presence_secret": secret(), "block_direct": relayed, "home": home,
    }));
    assert!(reply.get("error").is_none(), "online: {reply}");
}

/// A download link served by `sender` (the Rust core), opened by `opener` (the helper's own opener, which runs the
/// link page's exchange): the hello, the challenge and the proof before any connection, the offer and answer, then
/// the file in records under the opener's credit, checked against its SHA-256. With `relayed`, only the relay.
pub fn download_link(sender: &mut dyn Peer, opener: &mut dyn Peer, host: &LocalHost, relayed: bool, size: u64) -> f64 {
    let homes = (TempHome::new("link-s"), TempHome::new("link-o"));
    link_online(sender, host, relayed, homes.0.path());
    link_online(opener, host, relayed, homes.1.path());
    let (mut seen_s, mut seen_o) = (Vec::new(), Vec::new());
    let online = |e: &Value| e["event"] == "online" && e["available"] == true;
    wait_for(sender, &mut seen_s, STEP, "the sender online", online);
    wait_for(opener, &mut seen_o, STEP, "the opener online", online);
    let content = TempHome::new("link-content");
    let path = content.path().join("Site photos.pdf");
    write_content(&path, "link content", size);
    let link = sender.command(json!({ "cmd": "serve_link", "path": path.to_string_lossy() }));
    assert!(link.get("error").is_none(), "serve_link: {link}");
    // The registration travels on the sender's connection; the host must hold it before the opener asks.
    std::thread::sleep(Duration::from_millis(500));
    let started = Instant::now();
    let opened = opener.command(json!({ "cmd": "open_link", "link_id": link["link_id"], "secret": link["secret"] }));
    assert!(opened.get("error").is_none(), "open_link: {opened}");
    let budget = Duration::from_secs(if relayed { 120 } else { 60 });
    let done = wait_for(opener, &mut seen_o, budget, "the downloaded link", |e| e["event"] == "link_downloaded");
    assert_eq!(done["outcome"], 0, "the whole file arrived and its SHA-256 matched: {done}");
    assert_eq!(done["sha256"], link["sha256"]);
    assert_eq!(done["size"], size);
    assert_eq!(done["attempt"], if relayed { 2 } else { 1 }, "{done}");
    wait_for(sender, &mut seen_s, STEP, "the sender's count", |e| e["event"] == "link_served");
    let elapsed = started.elapsed().as_secs_f64();
    // The finished upload takes its setup and connection with it (the online thread looks every quarter second).
    let deadline = Instant::now() + STEP;
    loop {
        let held = sender.command(json!({ "cmd": "link_held" }));
        if held.get("error").is_some() || (held["setups"] == 0 && held["connections"] == 0) {
            break;
        }
        assert!(Instant::now() < deadline, "the sender still holds the finished download: {held}");
        std::thread::sleep(Duration::from_millis(100));
    }
    elapsed
}

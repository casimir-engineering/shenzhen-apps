//! The helper's own sessions, replayed (`fixtures/vectors/objc-session.json`, written by `tools/objc-vectors` from two
//! real `SZFriendsSecureChannel` objects). A Rust channel stands in for either side: fed what that side received, at
//! the same points, with the same random draws, clock and policy answers, it must write exactly the bytes the helper
//! wrote, report the same events in the same order, and end with the same facts (keys, hash, minor, route, rekeys).
//! Then every received byte is flipped in turn: the Rust side must close with an error and never deliver a frame the
//! helper did not send, in order.

mod support;

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::Value;
use support::{identity, keys};
use szfriends_core::session::{ChannelConfig, Event, HandshakeOptions, ReplayCache, SecureChannel, SessionRandom};
use szfriends_core::wire::{Fields, Frame, Pattern, RouteMethod};
use szfriends_vectors::{bytes, cases, load, number, text};

/// The draws the helper made on this side, in order. Past the end it gives zeros: the helper draws a responder's
/// ephemeral key only when replying, so a refusal leaves Rust's earlier draw unmatched.
struct Draws(VecDeque<Vec<u8>>);

impl SessionRandom for Draws {
    fn fill(&mut self, out: &mut [u8]) {
        match self.0.pop_front() {
            Some(draw) => {
                assert_eq!(draw.len(), out.len(), "a draw of another size");
                out.copy_from_slice(&draw);
            }
            None => out.fill(0),
        }
    }
}

fn hex(data: &[u8]) -> String {
    data.iter().map(|b| format!("{b:02x}")).collect()
}

fn fields(value: &Value) -> Fields {
    let mut out = Fields::new();
    for (tag, value) in value.as_object().expect("fields") {
        out.insert(tag.parse().expect("tag"), bytes(value));
    }
    out
}

fn fields_text(fields: &Fields) -> String {
    fields.iter().map(|(tag, value)| format!("{tag}={}", hex(value))).collect::<Vec<_>>().join(",")
}

fn key(value: &Value, name: &str) -> Option<[u8; 32]> {
    value.get(name).map(|v| bytes(v).try_into().expect("32 bytes"))
}

/// The helper's event as the replay writes it.
fn expected_event(step: &Value) -> String {
    match text(step, "event") {
        "frame" => format!("frame:{}", text(step, "frame")),
        "code" => match step.get("code").and_then(Value::as_str) {
            Some(code) => format!("code:{code}"),
            None => format!("code-error:{}", number(step, "error")),
        },
        "closed" => match step.get("reason") {
            Some(reason) => format!("closed:{}:{reason}", number(step, "error")),
            None => format!("closed:{}", number(step, "error")),
        },
        "profile" => format!("profile:{}", fields_text(&fields(&step["fields"]))),
        other => other.to_owned(),
    }
}

fn actual_event(event: Event) -> String {
    match event {
        Event::Established => "established".into(),
        Event::Frame(frame) => format!("frame:{}", hex(&frame.encode().expect("decoded frames encode"))),
        Event::Code(Ok(code)) => format!("code:{code}"),
        Event::Code(Err(error)) => format!("code-error:{}", error.code()),
        Event::Closed(None) => "closed:0".into(),
        Event::Closed(Some(szfriends_core::session::SessionError::PeerClosed(reason))) => format!("closed:7:{reason}"),
        Event::Closed(Some(error)) => format!("closed:{}", error.code()),
    }
}

struct Replay {
    channel: SecureChannel,
    log: Arc<Mutex<Vec<String>>>,
    output: Vec<u8>,
    now: Duration,
}

fn build(scenario: &Value, side: &str, strict: bool) -> Replay {
    let setup = &scenario[side];
    let me = identity(text(setup, "identity"));
    let log = Arc::new(Mutex::new(Vec::new()));
    let mut channel = if side == "initiator" {
        let pattern = Pattern::from_byte(number(setup, "pattern") as u8).expect("pattern");
        let mut options = HandshakeOptions::new(pattern, RouteMethod::from_byte(number(setup, "route") as u8));
        options.remote_static = key(setup, "remote_static");
        options.expected_identity = key(setup, "expected_identity");
        options.request_token = setup.get("request_token").map(bytes);
        options.browse_only = setup["browse_only"].as_bool() == Some(true) || setup["browse_only"] == 1;
        let mut channel = SecureChannel::initiator(keys(&me), options);
        let asked_for_profile = scenario["steps"]
            .as_array()
            .unwrap()
            .iter()
            .any(|s| s["side"] == "initiator" && s.get("event").and_then(Value::as_str) == Some("profile"));
        if asked_for_profile {
            let log = log.clone();
            channel.set_profile_decision(Box::new(move |profile: &Fields| {
                log.lock().unwrap().push(format!("profile:{}", fields_text(profile)));
                true
            }));
        }
        channel
    } else {
        let mut answers: VecDeque<Value> = setup["policy"].as_array().cloned().unwrap_or_default().into();
        let policy = Box::new(move |key: Option<&[u8; 32]>, pattern: Pattern, token: Option<&[u8]>| {
            let Some(answer) = answers.pop_front() else {
                assert!(!strict, "the policy was asked more often than the helper asked it");
                return false;
            };
            if strict {
                assert_eq!(key.map(|k| hex(k)), answer["identity"].as_str().map(str::to_owned));
                assert_eq!(pattern as u64, number(&answer, "pattern"));
                assert_eq!(token.map(hex), answer["token"].as_str().map(str::to_owned));
            }
            answer["allowed"] == true || answer["allowed"] == 1
        });
        let profile = setup.get("public_profile").map(fields);
        let mut channel = SecureChannel::responder(keys(&me), profile, policy);
        channel.set_replay_cache(Arc::new(ReplayCache::new(64, None)));
        channel
    };
    let draws = setup["random"].as_array().map(|draws| draws.iter().map(bytes).collect()).unwrap_or_default();
    channel.set_random(Box::new(Draws(draws)));
    // The helper recorded these sessions at its own minor, which is this build's, with fast transfers on.
    assert_eq!(
        number(&szfriends_vectors::load("objc-frames.json"), "session_minor"),
        u64::from(szfriends_core::wire::consts::SESSION_MINOR)
    );
    channel
        .set_config(ChannelConfig { rekey_after_bytes: number(scenario, "rekey_after_bytes"), ..Default::default() });
    channel.set_local_attestation(setup.get("attestation").map(bytes));
    Replay { channel, log, output: Vec::new(), now: Duration::from_secs(number(scenario, "start_seconds")) }
}

impl Replay {
    fn settle(&mut self) {
        while let Some(write) = self.channel.poll_transmit() {
            self.output.extend_from_slice(&write.bytes);
        }
        while let Some(event) = self.channel.poll_event() {
            self.log.lock().unwrap().push(actual_event(event));
        }
    }

    /// Runs one step that concerns this side; `received` may replace the bytes a receive step delivers.
    fn step(&mut self, step: &Value, received: Option<Vec<u8>>) {
        let now = self.now;
        if let Some(action) = step.get("do").and_then(Value::as_str) {
            match action {
                "start" => self.channel.start(now),
                "send" => {
                    let frame = Frame::decode(&bytes(&step["frame"])).expect("the helper's frame decodes");
                    if !self.channel.send_frame(&frame, now) {
                        self.log.lock().unwrap().push("send_refused".into());
                    }
                }
                "code" => self.channel.run_code_exchange(now),
                "close" => {
                    let reason = number(step, "reason") as u8;
                    let reason = szfriends_core::wire::CloseReason::from_byte(reason).expect("reason");
                    self.channel.close_with_reason(reason, now);
                }
                other => panic!("unknown action {other}"),
            }
        } else if let Some(data) = step.get("receive") {
            let data = received.unwrap_or_else(|| bytes(data));
            self.channel.receive(&data, now);
        } else if step.get("written").is_some() {
            self.channel.write_completed(now);
        } else if step.get("eof").is_some() {
            self.channel.link_closed_by_peer();
        }
        self.settle();
    }

    fn advance(&mut self, seconds: f64) {
        self.now += Duration::from_secs_f64(seconds);
        self.channel.handle_timeout(self.now);
        self.settle();
    }
}

fn steps(scenario: &Value) -> &Vec<Value> {
    cases(scenario, "steps")
}

fn check_facts(scenario: &Value, side: &str, channel: &SecureChannel) {
    let facts = &scenario[side]["facts"];
    let name = text(scenario, "name");
    let expect = |field: &str, actual: Option<String>| {
        assert_eq!(actual, facts.get(field).and_then(Value::as_str).map(str::to_owned), "{name} {side} {field}");
    };
    expect("remote_identity", channel.remote_identity().map(|k| hex(k)));
    expect("remote_static", channel.remote_static().map(|k| hex(k)));
    expect("remote_attestation", channel.remote_attestation().map(hex));
    expect("presented_token", channel.presented_token().map(hex));
    expect("handshake_hash", channel.handshake_hash().map(|h| hex(h)));
    assert_eq!(u64::from(channel.negotiated_minor()), number(facts, "negotiated_minor"), "{name} {side}");
    assert_eq!(channel.initiator_route() as u64, number(facts, "initiator_route"), "{name} {side}");
    let rekeys = channel.rekeys();
    assert_eq!(
        vec![rekeys.0, rekeys.1],
        facts["rekeys"].as_array().unwrap().iter().map(|v| v.as_u64().unwrap()).collect::<Vec<_>>(),
        "{name} {side} rekeys"
    );
}

#[test]
fn each_side_of_every_helper_session_replays_byte_for_byte() {
    let file = load("objc-session.json");
    for scenario in cases(&file, "scenarios") {
        let name = text(scenario, "name");
        for side in ["initiator", "responder"] {
            let mut replay = build(scenario, side, true);
            let (mut written, mut events) = (Vec::new(), Vec::new());
            for step in steps(scenario) {
                if step["side"] == "both" {
                    replay.advance(step["advance"].as_f64().expect("seconds"));
                } else if step["side"] == side {
                    if let Some(write) = step.get("write") {
                        written.extend(bytes(write));
                    }
                    if step.get("event").is_some() {
                        events.push(expected_event(step));
                    }
                    replay.step(step, None);
                }
            }
            assert_eq!(hex(&replay.output), hex(&written), "{name}: the {side}'s bytes");
            assert_eq!(*replay.log.lock().unwrap(), events, "{name}: the {side}'s events");
            check_facts(scenario, side, &replay.channel);
        }
    }
}

/// Events that take the peer's word for something: going live, a frame, a profile, a code. Local outcomes (a refused
/// send, a code exchange that could not run) and the close are not.
fn accepts(event: &str) -> bool {
    event == "established" || ["frame:", "profile:", "code:"].iter().any(|p| event.starts_with(p))
}

#[test]
fn every_byte_the_helper_sent_refuses_when_flipped() {
    let file = load("objc-session.json");
    for scenario in cases(&file, "scenarios") {
        let name = text(scenario, "name");
        for side in ["initiator", "responder"] {
            let received: Vec<Vec<u8>> = steps(scenario)
                .iter()
                .filter(|s| s["side"] == side && s.get("receive").is_some())
                .map(|s| bytes(&s["receive"]))
                .collect();
            // What the honest run accepted from the peer: a flipped run may stop early, never accept anything else.
            let honest: Vec<String> = steps(scenario)
                .iter()
                .filter(|s| s["side"] == side && s.get("event").is_some())
                .map(expected_event)
                .filter(|e| accepts(e))
                .collect();
            let total: usize = received.iter().map(Vec::len).sum();
            for index in 0..total {
                let mut replay = build(scenario, side, false);
                let (mut seen, mut delivery) = (0usize, 0usize);
                for step in steps(scenario) {
                    if step["side"] == "both" {
                        replay.advance(step["advance"].as_f64().unwrap());
                    } else if step["side"] == side {
                        let mut data = None;
                        if step.get("receive").is_some() {
                            let mut bytes = received[delivery].clone();
                            if index >= seen && index < seen + bytes.len() {
                                bytes[index - seen] ^= 0x20;
                            }
                            seen += bytes.len();
                            delivery += 1;
                            data = Some(bytes);
                        }
                        replay.step(step, data);
                    }
                }
                // Whatever the flip left waiting ends when time runs out and the link goes.
                replay.advance(3600.0);
                replay.channel.link_closed_by_peer();
                replay.settle();
                let log = replay.log.lock().unwrap().clone();
                assert!(log.iter().any(|e| e.starts_with("closed:")), "{name} {side} byte {index}: {log:?}");
                let accepted: Vec<String> = log.into_iter().filter(|e| accepts(e)).collect();
                assert!(
                    honest.starts_with(&accepted),
                    "{name} {side} byte {index} accepted what the helper did not send"
                );
            }
        }
    }
}

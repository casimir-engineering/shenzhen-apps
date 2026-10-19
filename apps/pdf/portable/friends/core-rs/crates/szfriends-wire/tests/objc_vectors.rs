//! The wire codec against the Objective-C helper's own encodings and decisions (fixtures/vectors, exported by
//! core-rs/tools/objc-vectors): same bytes out, same bytes accepted, same bytes refused.

use serde_json::Value;
use szfriends_vectors::{bytes, cases, field, flag, load, number, text};
use szfriends_wire::payload::negotiate_minor;
use szfriends_wire::route::session_a_wins;
use szfriends_wire::stream::{prologue, MessageReader, Preamble};
use szfriends_wire::{Fields, Frame, FrameType, HandshakePayload, Pattern};

fn fields_of(value: &Value) -> Fields {
    value.as_object().expect("fields").iter().map(|(tag, v)| (tag.parse().expect("tag"), bytes(v))).collect()
}

#[test]
fn encodes_every_frame_type_as_the_helper_does() {
    let vectors = load("objc-frames.json");
    let mut covered = std::collections::BTreeSet::new();
    for case in cases(&vectors, "encode") {
        let frame_type = FrameType::from_byte(number(case, "type") as u8).expect("known type");
        covered.insert(frame_type);
        let frame = Frame { frame_type, fields: fields_of(&case["fields"]) };
        let encoded = frame.encode().unwrap_or_else(|e| panic!("{}: {e}", text(case, "name")));
        assert_eq!(hex(&encoded), text(case, "encoded"), "{}", text(case, "name"));
        assert_eq!(Frame::decode(&encoded).expect("round trip"), frame, "{}", text(case, "name"));
    }
    // REQUEST_BY_ID carries a real signature, so its vector sits with the identity ones.
    let request = field(&load("objc-identity.json")["request_by_id"], "frame");
    let frame = Frame::decode(&request).expect("REQUEST_BY_ID decodes");
    assert_eq!(frame.encode().expect("re-encodes"), request);
    covered.insert(frame.frame_type);
    assert_eq!(covered.len(), FrameType::ALL.len(), "a frame type has no encoding vector");
}

#[test]
fn accepts_and_refuses_exactly_what_the_helper_does() {
    let vectors = load("objc-frames.json");
    for case in cases(&vectors, "decode") {
        let name = text(case, "name");
        let decoded = Frame::decode(&bytes(&case["input"]));
        assert_eq!(decoded.is_ok(), flag(case, "ok"), "{name}: {decoded:?}");
        if let Ok(frame) = decoded {
            assert_eq!(frame.frame_type as u64, number(case, "type"), "{name}");
            assert_eq!(frame.fields, fields_of(&case["fields"]), "{name}");
        }
    }
}

#[test]
fn handshake_payloads_match() {
    let vectors = load("objc-frames.json");
    let all = cases(&vectors, "handshake_payloads");
    let local = all.iter().find(|c| c["name"] == "local").expect("local");
    assert_eq!(hex(&HandshakePayload::local().encode().expect("local")), text(local, "encoded"));
    let empty = all.iter().find(|c| c["name"] == "empty").expect("empty");
    assert_eq!(hex(&HandshakePayload::default().encode().expect("empty")), text(empty, "encoded"));
    for case in all {
        let decoded = HandshakePayload::decode(&field(case, "encoded")).expect("decodes");
        assert_eq!(hex(&decoded.encode().expect("encodes")), text(case, "encoded"), "{}", text(case, "name"));
    }
    for case in cases(&vectors, "handshake_payload_decode") {
        let name = text(case, "name");
        let decoded = HandshakePayload::decode(&bytes(&case["input"]));
        assert_eq!(decoded.is_ok(), flag(case, "ok"), "{name}");
        let Ok(payload) = decoded else { continue };
        let range =
            flag(case, "has_minor_range").then(|| (number(case, "minor_min") as u16, number(case, "minor_max") as u16));
        assert_eq!(payload.minor_range, range, "{name}");
        assert_eq!(u64::from(payload.capabilities), number(case, "capabilities"), "{name}");
        assert_eq!(payload.route_class.map(u64::from), case["route_class"].as_u64(), "{name}");
        assert_eq!(payload.certificate.map(|c| hex(&c)), case["certificate"].as_str().map(str::to_owned), "{name}");
        let profile = if case["profile"].is_null() { Fields::new() } else { fields_of(&case["profile"]) };
        assert_eq!(payload.profile, profile, "{name}");
    }
}

#[test]
fn minor_negotiation_matches() {
    let vectors = load("objc-frames.json");
    for case in cases(&vectors, "minor_negotiation") {
        let pair = |key: &str| (case[key][0].as_u64().unwrap() as u16, case[key][1].as_u64().unwrap() as u16);
        let expected = case["negotiated"].as_u64().map(|n| n as u16);
        assert_eq!(negotiate_minor(pair("local"), pair("remote")), expected, "{case}");
    }
    assert_eq!(number(&vectors, "session_minor"), u64::from(szfriends_wire::consts::SESSION_MINOR));
    assert_eq!(number(&vectors, "plaintext_max"), szfriends_wire::consts::FRAME_PLAINTEXT_MAX as u64);
}

#[test]
fn session_race_matches() {
    let vectors = load("objc-presence-race-code.json");
    let race = &vectors["session_race"];
    let keys: Vec<Vec<u8>> = cases(race, "keys").iter().map(bytes).collect();
    for case in cases(race, "cases") {
        let (ka, kb) = (number(case, "key_a") as usize, number(case, "key_b") as usize);
        let wins = session_a_wins(number(case, "route_a") as u8, &keys[ka], number(case, "route_b") as u8, &keys[kb]);
        assert_eq!(wins, flag(case, "a_wins"), "{case}");
    }
}

#[test]
fn streams_split_into_the_helpers_messages() {
    let vectors = load("objc-noise.json");
    for handshake in cases(&vectors, "handshakes") {
        let pattern = Pattern::from_byte(number(handshake, "pattern_byte") as u8).expect("pattern");
        let preamble = Preamble { pattern };
        assert_eq!(hex(&preamble.bytes()), text(handshake, "preamble"));
        assert_eq!(hex(&prologue(preamble)), text(handshake, "prologue"));
        let messages: Vec<Vec<u8>> = cases(handshake, "messages").iter().map(|m| field(m, "ciphertext")).collect();
        let transport = cases(handshake, "transport");
        for (direction, key, first) in [("i2r", "stream_to_responder", 0), ("r2i", "stream_to_initiator", 1)] {
            let stream = field(handshake, key);
            let body = if first == 0 {
                assert_eq!(Preamble::parse(&stream[..4]).expect("preamble"), preamble);
                &stream[4..]
            } else {
                &stream[..]
            };
            let mut expected: Vec<Vec<u8>> = messages.iter().skip(first).step_by(2).cloned().collect();
            expected.extend(transport.iter().filter(|t| t["direction"] == direction).map(|t| field(t, "ciphertext")));
            // One byte at a time: the reader must not depend on how the route chunks the stream.
            let mut reader = MessageReader::new();
            let mut got = Vec::new();
            for byte in body {
                got.extend(reader.push(std::slice::from_ref(byte)).expect("valid stream"));
            }
            assert_eq!(got, expected, "{} {direction}", text(handshake, "pattern"));
            assert_eq!(reader.pending(), 0);
        }
    }
}

#[test]
fn bad_lengths_close_the_stream() {
    let mut reader = MessageReader::new();
    assert!(reader.push(&[0, 0]).is_err(), "length 0");
    assert!(reader.push(&[0, 1, 9]).is_err(), "dead after an error");
    let mut responder = MessageReader::new();
    responder.set_limit(szfriends_wire::consts::RESPONDER_HANDSHAKE_MAX);
    assert!(responder.push(&[0x04, 0x01]).is_err(), "1,025 bytes refused on the prefix alone");
    assert!(Preamble::parse(b"SZ\x02\x00").is_err(), "unknown major");
    assert!(Preamble::parse(b"SZ\x01\x03").is_err(), "unknown pattern");
}

fn hex(data: &[u8]) -> String {
    data.iter().map(|b| format!("{b:02x}")).collect()
}

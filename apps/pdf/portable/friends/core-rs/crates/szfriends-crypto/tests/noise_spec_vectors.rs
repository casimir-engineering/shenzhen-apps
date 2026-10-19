//! ADR 0001's mandatory Noise vectors, the same files the helper's session suite reads: cacophony (primary) and snow,
//! the entries for exactly NN, XX and IK with 25519_ChaChaPoly_BLAKE2b. Loading none fails.

mod support;

use szfriends_crypto::noise::HandshakeKeys;
use szfriends_vectors::{cases, field, text};
use szfriends_wire::Pattern;

fn vectors(file: &str) -> serde_json::Value {
    let path = szfriends_vectors::friends_dir().join("service/session/tests/vectors").join(file);
    serde_json::from_str(&std::fs::read_to_string(&path).expect("vector file")).expect("json")
}

fn check(file: &str) -> usize {
    let file_vectors = vectors(file);
    let mut checked = 0;
    for vector in cases(&file_vectors, "vectors") {
        let name = text(vector, "protocol_name");
        let pattern = match &name[6..8] {
            "NN" => Pattern::NN,
            "XX" => Pattern::XX,
            "IK" => Pattern::IK,
            other => panic!("unexpected pattern {other}"),
        };
        let initiator = HandshakeKeys {
            local_static: support::key(vector, "init_static"),
            remote_static: support::public(vector, "init_remote_static"),
            fixed_ephemeral: support::key(vector, "init_ephemeral"),
        };
        let responder = HandshakeKeys {
            local_static: support::key(vector, "resp_static"),
            remote_static: None,
            fixed_ephemeral: support::key(vector, "resp_ephemeral"),
        };
        assert_eq!(field(vector, "init_prologue"), field(vector, "resp_prologue"));
        let (i, r) = support::pair(pattern, &field(vector, "init_prologue"), initiator, responder);
        let (hash, _) = support::run(i, r, cases(vector, "messages"), name);
        if vector.get("handshake_hash").is_some() {
            assert_eq!(hash.to_vec(), field(vector, "handshake_hash"), "{name} h");
        }
        checked += 1;
    }
    checked
}

#[test]
fn cacophony() {
    assert_eq!(check("cacophony-25519-chachapoly-blake2b.json"), 3);
}

#[test]
fn snow() {
    assert_eq!(check("snow-25519-chachapoly-blake2b.json"), 3);
}

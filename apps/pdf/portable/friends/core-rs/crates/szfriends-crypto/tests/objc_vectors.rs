//! Friends' own handshakes, transport frames, rekeys, comparison codes, presence tags, CPace runs and invite proofs,
//! against what the Objective-C helper computes (fixtures/vectors).

mod support;

use szfriends_crypto::cpace::{self, join, CPace};
use szfriends_crypto::noise::{Handshake, HandshakeKeys, NoiseError};
use szfriends_crypto::{code, invite, presence};
use szfriends_vectors::{bytes, cases, field, load, number, text};
use szfriends_wire::{FrameType, Pattern};

#[test]
fn friends_handshakes_and_transport_match_the_helper() {
    let vectors = load("objc-noise.json");
    for vector in cases(&vectors, "handshakes") {
        let label = text(vector, "protocol_name");
        let pattern = Pattern::from_byte(number(vector, "pattern_byte") as u8).expect("pattern");
        let initiator = HandshakeKeys {
            local_static: support::key(vector, "initiator_static"),
            remote_static: (pattern == Pattern::IK)
                .then(|| support::public(vector, "responder_static_public").unwrap()),
            fixed_ephemeral: support::key(vector, "initiator_ephemeral"),
        };
        let responder = HandshakeKeys {
            local_static: support::key(vector, "responder_static"),
            remote_static: None,
            fixed_ephemeral: support::key(vector, "responder_ephemeral"),
        };
        let (i, r) = support::pair(pattern, &field(vector, "prologue"), initiator, responder);
        let (hash, transports) = support::run(i, r, cases(vector, "messages"), label);
        assert_eq!(hash.to_vec(), field(vector, "handshake_hash"), "{label} h");
        let (mut ti, mut tr) = transports.expect("transport");
        for message in cases(vector, "transport") {
            let i2r = message["direction"] == "i2r";
            let (sender, receiver) = if i2r { (&mut ti, &mut tr) } else { (&mut tr, &mut ti) };
            assert_eq!(sender.sending_nonce(), number(message, "nonce"), "{label} nonce");
            let plaintext = field(message, "plaintext");
            let ciphertext = sender.encrypt(&plaintext).expect("encrypt");
            assert_eq!(ciphertext, field(message, "ciphertext"), "{label} transport");
            assert_eq!(receiver.decrypt(&ciphertext).expect("decrypt"), plaintext);
            // ADR 0001 § Rekey: REKEY travels under the old key, then both ends of that direction switch.
            if plaintext[0] == FrameType::Rekey as u8 {
                sender.rekey_outgoing();
                receiver.rekey_incoming();
            }
        }
    }
}

#[test]
fn an_all_zero_diffie_hellman_kills_the_handshake() {
    let vectors = load("objc-noise.json");
    let low = &vectors["low_order"];
    assert_eq!(low["read_status"].as_i64(), Some(-5), "the helper refuses it too, as SZFRIENDS_NOISE_ERR_DH");
    let ik = &cases(&vectors, "handshakes")[1];
    let keys = HandshakeKeys { local_static: support::key(ik, "responder_static"), ..HandshakeKeys::default() };
    let mut responder = Handshake::new(Pattern::IK, false, &field(ik, "prologue"), &keys).expect("responder");
    assert_eq!(responder.read(&field(low, "message")), Err(NoiseError::Dh));
    assert_eq!(responder.write(b""), Err(NoiseError::State), "dead after an error");
}

#[test]
fn keys_must_fit_the_pattern() {
    let some = Some(zeroize::Zeroizing::new([7u8; 32]));
    let nn_with_static = HandshakeKeys { local_static: some.clone(), ..HandshakeKeys::default() };
    assert_eq!(Handshake::new(Pattern::NN, true, b"", &nn_with_static).unwrap_err(), NoiseError::Argument);
    assert_eq!(Handshake::new(Pattern::XX, true, b"", &HandshakeKeys::default()).unwrap_err(), NoiseError::Argument);
    let ik_without_remote = HandshakeKeys { local_static: some, ..HandshakeKeys::default() };
    assert_eq!(Handshake::new(Pattern::IK, true, b"", &ik_without_remote).unwrap_err(), NoiseError::Argument);
}

#[test]
fn comparison_codes_match() {
    let vectors = load("objc-presence-race-code.json");
    for case in cases(&vectors, "comparison_codes") {
        let (h, na, nr) =
            (field(case, "handshake_hash"), field(case, "initiator_nonce"), field(case, "responder_nonce"));
        assert_eq!(code::commitment(&h, &nr).to_vec(), field(case, "commitment"));
        assert!(code::commitment_matches(&field(case, "commitment"), &h, &nr));
        assert!(!code::commitment_matches(&field(case, "commitment"), &h, &na));
        assert_eq!(code::comparison_code(&h, &na, &nr), text(case, "code"));
    }
}

#[test]
fn presence_tags_and_windows_match() {
    let vectors = load("objc-presence-race-code.json");
    let presence_vectors = &vectors["presence"];
    let secret = field(presence_vectors, "secret");
    for case in cases(presence_vectors, "tags") {
        let window = case["window"].as_i64().expect("window");
        assert_eq!(presence::tag(&secret, window).to_vec(), field(case, "tag"), "window {window}");
    }
    for case in cases(presence_vectors, "windows") {
        let seconds = case["unix_seconds"].as_f64().expect("seconds");
        assert_eq!(presence::window_index(seconds), case["window"].as_i64().expect("window"), "{seconds}");
    }
}

#[test]
fn cpace_runs_match() {
    let vectors = load("objc-cpace.json");
    for run in cases(&vectors, "runs") {
        let name = text(run, "name");
        let (prs, ci, sid) = (field(run, "prs"), field(run, "ci"), field(run, "sid"));
        assert_eq!(cpace::generator_string(&prs, &ci, &sid), field(run, "generator_string"), "{name}");
        assert_eq!(cpace::generator(&prs, &ci, &sid).to_vec(), field(run, "generator"), "{name}");
        let scalar = |key| field(run, key).try_into().expect("32-byte scalar");
        let a = CPace::new(&prs, &ci, &sid, Some(scalar("ya"))).expect("A");
        let b = CPace::new(&prs, &ci, &sid, Some(scalar("yb"))).expect("B");
        assert_eq!(a.share().to_vec(), field(run, "share_a"), "{name}");
        assert_eq!(b.share().to_vec(), field(run, "share_b"), "{name}");
        assert_eq!(cpace::scalar_mult_vfy(&scalar("ya"), &b.share()).expect("K").to_vec(), field(run, "k"));
        let (ad_a, ad_b) = (field(run, "ada"), field(run, "adb"));
        let isk_a = a.isk_as_initiator(&ad_a, &b.share(), &ad_b).expect("ISK A");
        let isk_b = b.isk_as_responder(&ad_b, &a.share(), &ad_a).expect("ISK B");
        assert_eq!(isk_a.to_vec(), field(run, "isk"), "{name}");
        assert_eq!(isk_b.to_vec(), field(run, "isk"), "{name}");
        if name == "join" {
            check_join(run, isk_a.as_ref());
        }
    }
    for case in cases(&vectors, "scalar_mult_vfy") {
        let scalar = field(case, "scalar").try_into().expect("scalar");
        let product = cpace::scalar_mult_vfy(&scalar, &field(case, "point")).map(|p| p.to_vec());
        assert_eq!(product, case["product"].as_str().map(|_| field(case, "product")), "{case}");
    }
    for case in cases(&vectors, "lv_cat") {
        let parts: Vec<Vec<u8>> = cases(case, "parts").iter().map(bytes).collect();
        let refs: Vec<&[u8]> = parts.iter().map(Vec::as_slice).collect();
        assert_eq!(cpace::lv_cat(&refs), field(case, "lv_cat"));
    }
}

fn check_join(run: &serde_json::Value, isk: &[u8]) {
    let ci = join::channel_identifier(&field(run, "request_id"), &field(run, "device_key"), &field(run, "static_key"));
    assert_eq!(ci, field(run, "ci"));
    assert_eq!(join::approver_ad(&field(run, "approver_key"), &field(run, "root_key")), field(run, "adb"));
    assert_eq!(join::tag(isk, join::RESPONDER_TAG_DOMAIN, b"").to_vec(), field(run, "responder_tag"));
    assert_eq!(
        join::tag(isk, join::INITIATOR_TAG_DOMAIN, &field(run, "consent")).to_vec(),
        field(run, "initiator_tag")
    );
    assert_eq!(
        join::tag(isk, join::WELCOME_TAG_DOMAIN, &field(run, "welcome_body")).to_vec(),
        field(run, "welcome_tag")
    );
    // A wrong code gives a different ISK, which the responder's tag reveals.
    let wrong = CPace::new(b"48213908", &ci, &field(run, "sid"), None).expect("wrong code");
    let right = CPace::new(&field(run, "prs"), &ci, &field(run, "sid"), None).expect("right code");
    let isk_wrong = wrong.isk_as_initiator(b"a", &right.share(), b"b").expect("ISK");
    let isk_right = right.isk_as_responder(b"b", &wrong.share(), b"a").expect("ISK");
    assert!(!join::tags_equal(
        &join::tag(isk_wrong.as_ref(), join::RESPONDER_TAG_DOMAIN, b""),
        &join::tag(isk_right.as_ref(), join::RESPONDER_TAG_DOMAIN, b"")
    ));
}

#[test]
fn invite_proof_matches() {
    let vectors = load("objc-identity.json");
    let case = &vectors["invite_proof"];
    let proof = invite::invite_proof(&field(case, "invite_token"), &field(case, "handshake_hash")).expect("proof");
    assert_eq!(proof.to_vec(), field(case, "proof"));
    assert!(invite::invite_proof(&[0; 15], &[0; 64]).is_none());
}

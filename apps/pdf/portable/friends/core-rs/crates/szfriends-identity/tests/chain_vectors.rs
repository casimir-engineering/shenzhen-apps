//! Device chains and joining against the Objective-C helper (fixtures/vectors/objc-chain.json): every chain decoded
//! and rebuilt link for link, the devices under the rules, every mutation refused with the helper's error, and a
//! whole join run whose messages match byte for byte.

use std::sync::Arc;

use serde_json::Value;
use szfriends_identity::chain::{chain_label, device_consent, ChainError, DeviceChain, DeviceState, NAME_MAX};
use szfriends_identity::identity::Identity;
use szfriends_identity::join::{self, Approver, Joiner, Receipt, Step};
use szfriends_vectors::{cases, field, load, text};

fn identity(name: &str) -> Identity {
    let seed = szfriends_crypto::blake2b::<32>(None, &[format!("{name} seed").as_bytes()]);
    let mut static_key = szfriends_crypto::blake2b::<32>(None, &[format!("{name} static").as_bytes()]);
    static_key[0] &= 248;
    static_key[31] = (static_key[31] & 127) | 64;
    Identity::from_secrets(&seed, &static_key)
}

fn key(value: &Value, name: &str) -> [u8; 32] {
    field(value, name).try_into().expect("32 bytes")
}

fn chain_named<'a>(vectors: &'a Value, label: &str) -> &'a Value {
    cases(vectors, "chains").iter().find(|c| c["label"] == label).unwrap_or_else(|| panic!("{label}"))
}

fn check(entry: &Value, chain: &DeviceChain) {
    let label = text(entry, "label");
    assert_eq!(hex::encode(chain.encoded()), text(entry, "encoded"), "{label}: encoding");
    assert_eq!(chain.root_key().to_vec(), field(entry, "root"), "{label}");
    assert_eq!(chain.genesis_hash().to_vec(), field(entry, "genesis_hash"), "{label}");
    let heads: Vec<String> = chain.heads().iter().map(hex::encode).collect();
    let expected: Vec<&str> = cases(entry, "heads").iter().map(|h| h.as_str().unwrap()).collect();
    assert_eq!(heads, expected, "{label}: heads");
    for (link, want) in chain.links().iter().zip(cases(entry, "links")) {
        assert_eq!(hex::encode(link.hash), text(want, "hash"), "{label}: link hash");
        assert_eq!(link.kind as u64, want["kind"].as_u64().unwrap(), "{label}");
    }
    let devices = cases(entry, "devices");
    assert_eq!(chain.devices().len(), devices.len(), "{label}: devices");
    for (device, want) in chain.devices().iter().zip(devices) {
        assert_eq!(device.device_key.to_vec(), field(want, "device_key"), "{label}");
        assert_eq!(device.static_key.to_vec(), field(want, "static_key"), "{label}");
        assert_eq!(device.name, text(want, "name"), "{label}");
        assert_eq!(device.system, text(want, "system"), "{label}");
        assert_eq!(device.added_at, want["added_at"].as_f64().unwrap(), "{label}");
        assert_eq!(device.revoked_at, want["revoked_at"].as_f64(), "{label}");
        assert_eq!(device.state as u64, want["state"].as_u64().unwrap(), "{label}: state of {}", device.name);
        assert_eq!(device.is_root, want["is_root"].as_bool().unwrap(), "{label}");
    }
}

#[test]
fn chains_decode_to_the_helpers_devices() {
    let vectors = load("objc-chain.json");
    for entry in cases(&vectors["chain"], "chains") {
        let label = text(entry, "label");
        let chain = DeviceChain::decode(&field(entry, "encoded"), None).unwrap_or_else(|e| panic!("{label}: {e}"));
        check(entry, &chain);
        let pinned = DeviceChain::decode(&field(entry, "encoded"), Some(chain.root_key())).expect("same root");
        assert_eq!(pinned, chain);
    }
}

#[test]
fn chains_build_byte_for_byte() {
    let vectors = load("objc-chain.json");
    let v = &vectors["chain"];
    let t0 = v["t0"].as_f64().unwrap();
    let (alice, bob) = (identity("alice"), identity("bob"));
    let add = |chain: &DeviceChain, who: &str, name: &str, by: &Identity, at: f64| {
        let device = identity(who);
        let consent = device_consent(&device, chain.root_key());
        let (key, static_key) = (device.public_key(), device.static_public_key());
        chain.adding(&key, &static_key, &consent, name, "Windows 11", by, t0 + at).expect("adds")
    };
    let revoke = |chain: &DeviceChain, who: &str, by: &Identity, at: f64| {
        chain.revoking(&identity(who).public_key(), by, t0 + at).expect("revokes")
    };
    let genesis = DeviceChain::genesis(&alice, "Alice's Mac", "macOS 26.1", t0).unwrap();
    check(chain_named(v, "genesis"), &genesis);
    let two = add(&genesis, "bob", "Bob's PC", &alice, 10.0);
    check(chain_named(v, "add bob"), &two);
    let three = add(&two, "carol", "Carol \u{1F98A} laptop", &bob, 20.0);
    check(chain_named(v, "add carol by bob"), &three);
    let renamed = three.renaming("  Bob's\tnew PC\u{7} ", "Ubuntu 24.04", &bob, t0 + 30.0).unwrap();
    check(chain_named(v, "rename bob"), &renamed);
    check(chain_named(v, "revoke carol"), &revoke(&renamed, "carol", &alice, 40.0));
    let revoke_bob = revoke(&two, "bob", &alice, 50.0);
    let dave = add(&two, "dave", "Dave", &bob, 51.0);
    let merged = revoke_bob.merged(&dave).unwrap();
    check(chain_named(v, "revoke bob and dave added unseen"), &merged);
    assert_eq!(merged.device(&identity("dave").public_key()).unwrap().state, DeviceState::Void);
    assert_eq!(dave.merged(&revoke_bob).unwrap(), merged, "merging commutes");
    let mutual = revoke(&two, "alice", &bob, 52.0).merged(&revoke_bob).unwrap();
    check(chain_named(v, "mutual revocation"), &mutual);
    let rename_a = two.renaming("Alice A", "macOS 26.1", &alice, t0 + 60.0).unwrap();
    let rename_b = two.renaming("Alice B", "macOS 26.2", &alice, t0 + 61.0).unwrap();
    check(chain_named(v, "concurrent renames"), &rename_a.merged(&rename_b).unwrap());
    let long = format!("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} {}", "\u{e9}".repeat(72));
    check(chain_named(v, "long label"), &add(&genesis, "erin", &long, &alice, 70.0));
    let removed = revoke(&two, "bob", &alice, 80.0);
    let b = identity("bob");
    let readd = removed.adding(
        &b.public_key(),
        &b.static_public_key(),
        &device_consent(&b, alice.public_key().as_ref().try_into().unwrap()),
        "again",
        "x",
        &alice,
        t0 + 81.0,
    );
    assert_eq!(readd.unwrap_err() as u64, v["readd_revoked_error"].as_u64().unwrap());
    assert_eq!(hex::encode(device_consent(&b, &alice.public_key())), text(v, "consent"));
}

#[test]
fn mutations_are_refused_as_the_helper_refuses_them() {
    let vectors = load("objc-chain.json");
    let v = &vectors["chain"];
    let root = identity("alice").public_key();
    for case in cases(v, "mutations") {
        let result = DeviceChain::decode(&field(case, "data"), Some(&root));
        let code = result.as_ref().map_or_else(|e| *e as u64, |_| 0);
        assert_eq!(code, case["error"].as_u64().unwrap(), "{}", text(case, "what"));
    }
    let wrong = &v["wrong_root"];
    assert_eq!(DeviceChain::decode(&field(wrong, "data"), Some(&key(wrong, "root"))), Err(ChainError::WrongRoot));
    for case in cases(v, "labels") {
        assert_eq!(chain_label(text(case, "input"), NAME_MAX), text(case, "name"));
    }
}

#[test]
fn a_join_run_matches_the_helper() {
    let vectors = load("objc-chain.json");
    let v = &vectors["join"];
    let dave = Arc::new(identity("dave"));
    let bob = Arc::new(identity("bob"));
    let request_id: [u8; 16] = field(v, "request_id").try_into().unwrap();
    let now = v["time"].as_f64().unwrap();
    let joiner = Joiner::new(dave.clone(), text(v, "friends_id"), text(v, "name"), text(v, "system"), Some(request_id));
    let request = joiner.request_message(now).unwrap();
    assert_eq!(hex::encode(&request), text(v, "request"));
    let chain = DeviceChain::decode(&field(v, "chain"), None).unwrap();
    let mut approver = Approver::new(bob.clone());
    assert_eq!(approver.receive_request(&request, Some("maple-otter"), Some(&chain), now), Receipt::Added);
    assert_eq!(approver.receive_request(&request, Some("maple-otter"), Some(&chain), now), Receipt::Refreshed);
    assert_eq!(approver.receive_request(&request, Some("other-id"), Some(&chain), now), Receipt::Ignored);
    assert!(approver.approve_with_code(&request_id, text(v, "code"), now));
    let hash = field(v, "handshake_hash");
    let scalar = |name: &str| -> [u8; 32] { field(v, name).try_into().unwrap() };
    let mut attempt = joiner.attempt(text(v, "code"), &hash, Some(scalar("scalar_a"))).unwrap();
    assert_eq!(hex::encode(attempt.code_message()), text(v, "code_message"));
    let root = *chain.root_key();
    let mut approval =
        approver.approval(attempt.code_message(), &hash, &root, now, Some(scalar("scalar_b"))).expect("approved");
    assert_eq!(hex::encode(&approval.reply_message), text(v, "reply"));
    let Step::Send(confirm) = attempt.receive(&approval.reply_message) else { panic!("a confirm") };
    assert_eq!(hex::encode(&confirm), text(v, "confirm"));
    let at = v["welcome_time"].as_f64().unwrap();
    let welcome = approver.welcome(&confirm, &mut approval, &chain, &field(v, "profile"), 2, at).expect("welcome");
    assert_eq!(hex::encode(welcome.chain.encoded()), text(v, "added_chain"));
    let parts: Vec<String> = welcome.parts.iter().map(hex::encode).collect();
    let expected: Vec<&str> = cases(v, "parts").iter().map(|p| p.as_str().unwrap()).collect();
    assert_eq!(parts, expected);
    let mut last = Step::Failed;
    for part in &welcome.parts {
        last = attempt.receive(part);
    }
    let Step::Joined { chain: joined, profile, friends_id_state } = last else { panic!("joined: {last:?}") };
    assert!(joined.authorizes(&dave.public_key()));
    assert_eq!(profile, field(v, "profile"));
    assert_eq!(friends_id_state, 2);
    for (reason, message) in cases(v, "ended").iter().enumerate() {
        let bytes = szfriends_vectors::bytes(message);
        assert_eq!(join::end_reason(&bytes).map(|r| r as usize), Some(reason + 1));
    }
    for case in cases(v, "codes") {
        assert_eq!(join::normalized_code(text(case, "typed")).as_deref(), case["code"].as_str(), "{case}");
    }
    for case in cases(v, "names") {
        let message = join::request_message(&dave, &request_id, "maple-otter", text(case, "name"), "Ubuntu", now);
        assert_eq!(message.map(hex::encode).as_deref(), case["message"].as_str(), "{case}");
    }
}

#[test]
fn a_wrong_code_spends_an_attempt_and_three_end_the_approval() {
    let vectors = load("objc-chain.json");
    let v = &vectors["join"];
    let dave = Arc::new(identity("dave"));
    let request_id: [u8; 16] = field(v, "request_id").try_into().unwrap();
    let now = v["time"].as_f64().unwrap();
    let joiner = Joiner::new(dave, "maple-otter", "Dave", "Ubuntu", Some(request_id));
    let chain = DeviceChain::decode(&field(v, "chain"), None).unwrap();
    let mut approver = Approver::new(Arc::new(identity("bob")));
    let request = joiner.request_message(now).unwrap();
    assert_eq!(approver.receive_request(&request, Some("maple-otter"), Some(&chain), now), Receipt::Added);
    let code = approver.approve(&request_id, now).unwrap();
    assert_eq!(approver.approve(&request_id, now).as_deref(), Some(code.as_str()), "approve twice keeps the code");
    let wrong = if code == "00000000" { "11111111" } else { "00000000" };
    let hash = [7u8; 64];
    for _ in 0..3 {
        let mut attempt = joiner.attempt(wrong, &hash, None).unwrap();
        let mut approval = approver.approval(attempt.code_message(), &hash, chain.root_key(), now, None).unwrap();
        assert!(matches!(attempt.receive(&approval.reply_message), Step::WrongCode));
        approver.abandon(&mut approval, now);
    }
    let attempt = joiner.attempt(&code, &hash, None).unwrap();
    let ended = approver.approval(attempt.code_message(), &hash, chain.root_key(), now, None);
    assert_eq!(ended.unwrap_err(), Some(join::EndReason::TooManyAttempts));
}

//! ID attestations against the host's own vectors (`server/friends/test/vectors/host-list-v1.json`, "attestations"),
//! which the host service and the Objective-C helper are held to as well: the same signed bytes, the same verdicts;
//! and the release a computer sends for the ID it had before joining a profile.

use std::path::PathBuf;

use serde_json::Value;
use szfriends_online::b64;
use szfriends_online::host::attestation::{self, judge_answer, Answer, Attestation, Verdict};
use szfriends_online::host::HostList;

/// `portable/server/...`: beside `portable/friends` on a Mac, or inside the copied tree in a VM or on a device.
fn vectors() -> Value {
    let friends = std::env::var_os("SZFRIENDS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../.."));
    let relative = "server/friends/test/vectors/host-list-v1.json";
    let path = [friends.join("..").join(relative), friends.join(relative)]
        .into_iter()
        .find(|p| p.exists())
        .unwrap_or_else(|| panic!("{relative} is missing beside {}", friends.display()));
    serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap()
}

fn list_and_now(v: &Value) -> (HostList, f64) {
    let pinned: Vec<[u8; 32]> =
        v["pinned"].as_array().unwrap().iter().map(|k| b64::decode_array::<32>(Some(k)).unwrap()).collect();
    let attestations = &v["attestations"];
    let list = HostList::from_signed(attestations["list"].to_string().as_bytes(), &pinned).expect("the list verifies");
    // "2026-10-13T03:00:00Z"
    let now = attestations["now"].as_str().unwrap();
    let day = attestation::day_number(&now[..10]).unwrap() as f64;
    let seconds: f64 = now[11..13].parse::<f64>().unwrap() * 3600.0 + now[14..16].parse::<f64>().unwrap() * 60.0;
    (list, day * 86_400.0 + seconds)
}

fn verdict(name: &str) -> Verdict {
    match name {
        "valid" => Verdict::Valid,
        "malformed" => Verdict::Malformed,
        "unknown_host" => Verdict::UnknownHost,
        "bad_signature" => Verdict::BadSignature,
        "wrong_holder" => Verdict::WrongHolder,
        "expired" => Verdict::Expired,
        other => panic!("unknown verdict {other}"),
    }
}

#[test]
fn every_vector_gets_the_hosts_verdict() {
    let v = vectors();
    let (list, now) = list_and_now(&v);
    let cases = v["attestations"]["cases"].as_array().unwrap();
    assert!(cases.len() >= 10, "the vectors have their cases");
    for case in cases {
        let claim = &case["claim"];
        let key = b64::decode_array::<32>(claim.get("identity_key")).unwrap();
        let id = claim["friends_id"].as_str().unwrap();
        let got = attestation::check_value(Some(&case["attestation"]), &list, id, &key, now);
        assert_eq!(got, verdict(case["verdict"].as_str().unwrap()), "{}", case["name"]);
        if let Some(hex) = case.get("signed_bytes_hex").and_then(Value::as_str) {
            let a = Attestation::from_value(&case["attestation"]).unwrap();
            let signed = [
                attestation::DOMAIN.as_bytes(),
                &attestation::signed_message(&a.host_id, &a.friends_id, &a.identity_key, &a.day),
            ]
            .concat();
            assert_eq!(hex::encode(signed), hex, "{}", case["name"]);
        }
    }
}

#[test]
fn an_answer_is_attested_unattested_or_refused() {
    let v = vectors();
    let (list, now) = list_and_now(&v);
    let cases = v["attestations"]["cases"].as_array().unwrap();
    let valid = cases.iter().find(|c| c["verdict"] == "valid").unwrap();
    let a = Attestation::from_value(&valid["attestation"]).unwrap();
    let encoded = a.encoded();
    assert_eq!(Attestation::from_bytes(&encoded), Some(a.clone()), "what a holder shows reads back");
    let key = a.identity_key;
    assert_eq!(judge_answer(Some(&encoded), &list, &a.friends_id, &key, now), Answer::Attested(a.clone()));
    assert_eq!(judge_answer(None, &list, &a.friends_id, &key, now), Answer::Unattested);
    assert_eq!(judge_answer(Some(b"{}"), &list, &a.friends_id, &key, now), Answer::Unattested);
    // For another ID than the one asked for: not the holder's word about this one.
    assert_eq!(judge_answer(Some(&encoded), &list, "maple-harbor", &key, now), Answer::Unattested);
    // Long expired: no better than none.
    assert_eq!(judge_answer(Some(&encoded), &list, &a.friends_id, &key, now + 90.0 * 86_400.0), Answer::Unattested);
    // Shown by another key: copied, so refused outright.
    assert_eq!(judge_answer(Some(&encoded), &list, &a.friends_id, &[7; 32], now), Answer::Refused);
    let big = vec![b' '; attestation::MAX_BYTES + 1];
    assert_eq!(Attestation::from_bytes(&big), None);
}

#[test]
fn a_release_signs_the_bytes_the_host_checks() {
    let v = vectors();
    let release = &v["release"];
    let challenge = b64::decode_value(release.get("challenge"), 32).unwrap();
    let key = b64::decode_array::<32>(release.get("identity_key")).unwrap();
    let (host, id) = (release["host_id"].as_str().unwrap(), release["friends_id"].as_str().unwrap());
    let message = szfriends_online::host::release::release_message(host, &challenge, &key, id);
    let signed = [szfriends_online::host::release::RELEASE_DOMAIN.as_bytes(), &message].concat();
    assert_eq!(hex::encode(signed), release["signed_bytes_hex"].as_str().unwrap());
    let seed: [u8; 32] = hex::decode(v["keys"]["identity"]["seed"].as_str().unwrap()).unwrap().try_into().unwrap();
    let identity = szfriends_identity::Identity::from_secrets(&seed, &[9; 32]);
    assert_eq!(identity.public_key(), key);
    let signature = identity.sign(&message, szfriends_online::host::release::RELEASE_DOMAIN);
    assert_eq!(b64::encode_url(&signature), release["sig"].as_str().unwrap(), "Ed25519 is deterministic");
}

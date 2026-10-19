//! Identity, signatures, REQUEST_BY_ID and Friends IDs against the Objective-C helper (fixtures/vectors).

use szfriends_identity::friends_id::{word_count_for_new_id, WordList, V1_DIGEST};
use szfriends_identity::identity::{self, Identity, SIGNATURE_DOMAINS};
use szfriends_identity::request_by_id;
use szfriends_vectors::{cases, field, load, number, text};
use szfriends_wire::Frame;

fn identity_named(vectors: &serde_json::Value, name: &str) -> Identity {
    let entry = cases(vectors, "identities").iter().find(|i| i["name"] == name).expect("identity");
    Identity::from_secrets(&key(entry, "signing_seed"), &key(entry, "static_private"))
}

fn key(value: &serde_json::Value, name: &str) -> [u8; 32] {
    field(value, name).try_into().expect("32 bytes")
}

#[test]
fn identities_match() {
    let vectors = load("objc-identity.json");
    for entry in cases(&vectors, "identities") {
        let name = text(entry, "name");
        let identity = Identity::from_secrets(&key(entry, "signing_seed"), &key(entry, "static_private"));
        assert_eq!(identity.public_key().to_vec(), field(entry, "public_key"), "{name}");
        assert_eq!(identity.static_public_key().to_vec(), field(entry, "static_public"), "{name}");
        assert_eq!(identity.static_certificate().to_vec(), field(entry, "static_certificate"), "{name}");
        assert_eq!(identity.identity_hash().to_vec(), field(entry, "identity_hash"), "{name}");
        assert_eq!(identity.secret_item().to_vec(), field(entry, "secret_item"), "{name}");
        let loaded = Identity::from_secret_item(&field(entry, "secret_item")).expect("loads");
        assert_eq!(loaded.public_key(), identity.public_key());
        let certificate = identity.static_certificate();
        assert_eq!(
            identity::identity_key_from_certificate(&certificate, &identity.static_public_key()),
            Some(identity.public_key())
        );
        assert_eq!(identity::identity_key_from_certificate(&certificate, &[9; 32]), None, "another static key");
    }
}

#[test]
fn a_damaged_secret_item_is_corrupt_never_another_identity() {
    let vectors = load("objc-identity.json");
    let item = field(&cases(&vectors, "identities")[0], "secret_item");
    for position in 0..item.len() {
        let mut damaged = item.clone();
        damaged[position] ^= 0x01;
        // Bit 0 of the clamped key's low byte and the seed's bits all change a checked byte or a derived key.
        assert!(Identity::from_secret_item(&damaged).is_err(), "byte {position}");
    }
    assert!(Identity::from_secret_item(&item[..132]).is_err());
}

#[test]
fn signatures_and_domains_match() {
    let vectors = load("objc-identity.json");
    let domains: Vec<&str> = cases(&vectors, "signature_domains").iter().map(|d| d.as_str().unwrap()).collect();
    assert_eq!(domains, SIGNATURE_DOMAINS);
    let alice = identity_named(&vectors, "alice");
    for case in cases(&vectors, "signatures") {
        let (domain, message) = (text(case, "domain"), field(case, "message"));
        let signature = alice.sign(&message, domain);
        assert_eq!(signature.to_vec(), field(case, "signature"), "{domain}");
        assert!(identity::verify(&signature, &message, domain, &alice.public_key()));
        for other in SIGNATURE_DOMAINS.iter().filter(|d| **d != domain) {
            assert!(!identity::verify(&signature, &message, other, &alice.public_key()), "{domain} as {other}");
        }
    }
    let message = b"m";
    let signature = alice.sign(message, "SZFriends request v1");
    assert!(!identity::verify(&signature, message, "SZFriends request", &alice.public_key()), "prefix domain");
    assert!(!identity::verify(&signature, message, "", &alice.public_key()), "empty domain");
}

#[test]
fn request_by_id_matches() {
    let vectors = load("objc-identity.json");
    let case = &vectors["request_by_id"];
    let alice = identity_named(&vectors, "alice");
    let h = field(case, "handshake_hash");
    let frame = request_by_id::make_frame(
        &alice,
        text(case, "friends_id"),
        &field(case, "token"),
        &field(case, "callback_secret"),
        &h,
    )
    .expect("frame");
    assert_eq!(frame.encode().expect("encodes"), field(case, "frame"));
    let decoded = Frame::decode(&field(case, "frame")).expect("decodes");
    assert_eq!(
        request_by_id::verify_frame(&decoded, &h).map(|k| k.to_vec()),
        Some(field(case, "verified_identity_key"))
    );
    let mut other_session = h.clone();
    other_session[0] ^= 1;
    assert_eq!(request_by_id::verify_frame(&decoded, &other_session), None, "bound to this session's h");
}

#[test]
fn friends_ids_match() {
    let vectors = load("objc-friends-id.json");
    let list = WordList::bundled().expect("the v1 list validates");
    assert_eq!(list.len() as u64, number(&vectors, "word_count"));
    assert_eq!(u64::from(list.version()), number(&vectors, "word_list_version"));
    assert_eq!(list.word_lines_digest(), text(&vectors, "word_lines_sha256"));
    assert_eq!(V1_DIGEST, text(&vectors, "pinned_digest"));
    for case in cases(&vectors, "normalized") {
        let input = text(case, "input");
        assert_eq!(list.normalized_id(input).as_deref(), case["normalized"].as_str(), "{input:?}");
    }
    for case in cases(&vectors, "random_ids") {
        let draws: Vec<u32> = cases(case, "draws").iter().map(|d| d.as_u64().unwrap() as u32).collect();
        let mut next = draws.iter();
        let id = list.random_id(draws.len(), |_| *next.next().expect("scripted draw"));
        assert_eq!(id, text(case, "id"));
    }
    for case in cases(&vectors, "word_count_for_new_id") {
        let count =
            word_count_for_new_id(case["list_new_id_words"].as_i64().unwrap(), number(case, "collisions_in_a_row"));
        assert_eq!(count as u64, number(case, "word_count"), "{case}");
    }
}

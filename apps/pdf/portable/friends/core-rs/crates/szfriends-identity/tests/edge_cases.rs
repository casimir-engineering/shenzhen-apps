//! Ed25519 verification at the edges where libraries disagree (small-order and mixed-order keys and R, non-canonical
//! S and key encodings), against the helper's libsodium verdicts (fixtures/vectors/objc-edge-cases.json).

use szfriends_identity::identity;
use szfriends_vectors::{cases, field, flag, load, text};

#[test]
fn ed25519_accepts_and_refuses_exactly_what_the_helper_does() {
    let vectors = load("objc-edge-cases.json");
    let (mut accepted, mut refused) = (0, 0);
    for case in cases(&vectors, "ed25519") {
        let helper = flag(case, "accepted");
        let ours = identity::verify(
            &field(case, "signature"),
            &field(case, "message"),
            text(case, "domain"),
            &field(case, "public_key"),
        );
        assert_eq!(ours, helper, "{} ({})", text(case, "name"), text(case, "why"));
        if helper {
            accepted += 1;
        } else {
            refused += 1;
        }
    }
    // The control and the mixed-order key whose torsion drops out; everything else is a refusal.
    assert_eq!(accepted, 2);
    assert!(refused > 50);
}

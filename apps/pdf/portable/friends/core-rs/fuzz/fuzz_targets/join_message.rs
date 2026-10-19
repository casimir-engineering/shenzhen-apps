//! Join messages (ADR 0013) as a stranger on an NN session sends them: every kind's strict decoder, the request's
//! signature check, the end reason, the code normaliser and the new computer's attempt fed the bytes as a reply or a
//! part. Nothing may panic; whatever decodes re-encodes to the same bytes.

#![no_main]

use std::sync::Arc;

use libfuzzer_sys::fuzz_target;
use szfriends_core::identity::join::{self, Joiner, MessageKind};
use szfriends_core::identity::Identity;

fuzz_target!(|data: &[u8]| {
    use MessageKind::*;
    for kind in [Request, Code, Reply, Confirm, Part, Ended, Welcome] {
        if let Some(fields) = join::decode(data, kind) {
            assert_eq!(join::encode(kind, &fields).as_deref(), Some(data), "one encoding per message");
        }
    }
    let _ = join::verified_request(data);
    let _ = join::end_reason(data);
    let _ = join::message_kind(data);
    let _ = join::normalized_code(&String::from_utf8_lossy(data));
    let joiner = Joiner::new(Arc::new(Identity::from_secrets(&[3; 32], &[5; 32])), "amber-falcon", "A", "B", None);
    if let Some(mut attempt) = joiner.attempt("12345678", &[1; 64], Some([2; 32])) {
        let _ = attempt.receive(data);
        let _ = attempt.receive(data);
    }
});

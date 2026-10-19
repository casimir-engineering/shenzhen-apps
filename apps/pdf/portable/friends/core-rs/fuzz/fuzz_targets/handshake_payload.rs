//! Handshake payloads (`HandshakePayload::decode`), read by a responder before it knows who is calling: whatever
//! decodes encodes again, and that encoding decodes to the same payload.

#![no_main]

use libfuzzer_sys::fuzz_target;
use szfriends_wire::HandshakePayload;

fuzz_target!(|data: &[u8]| {
    if let Ok(payload) = HandshakePayload::decode(data) {
        if let Ok(encoded) = payload.encode() {
            let again = HandshakePayload::decode(&encoded).expect("an encoded payload decodes");
            assert_eq!(again.certificate, payload.certificate);
            assert_eq!(again.request_token, payload.request_token);
            assert_eq!(again.attestation, payload.attestation);
            assert_eq!(again.route_class, payload.route_class);
            assert_eq!(again.profile, payload.profile);
        }
    }
});

//! Vectors for ADR 0018's later additions (WP6), in `fixtures/vectors/transfer-more/`: an AES-256-GCM lane's handshake
//! and transport (§ 9.2) and compressed parts (§ 9.4). The Objective-C helper (WP4) must reproduce them with its own
//! code; `friends-vectors-check` compares what its exporter writes there once it writes them (`aes_lane.json`), and
//! its tests read `compressed_parts.json`, whose zstd bytes depend on the library's version.
//!
//! The files are what this test computes; it fails when they differ. `SZFRIENDS_WRITE_TRANSFER_VECTORS=1` writes them.

use serde_json::{json, Value};
use szfriends_core::crypto::noise::{Handshake, HandshakeKeys};
use szfriends_core::wire::stream::{prologue, Preamble};
use szfriends_core::transfer::{compress, frames};
use szfriends_core::wire::{tag, FrameType, NoiseCipher, Pattern, RouteMethod};
use zeroize::Zeroizing;

fn key(hex32: &str) -> Zeroizing<[u8; 32]> {
    Zeroizing::new(hex::decode(hex32).unwrap().try_into().unwrap())
}

/// The IK lane of the helper's own IK vector (`objc-noise.json`, alice to bob), with bit 7 of the pattern byte set:
/// same keys, same payloads, so only the cipher and the prologue differ.
fn aes_lane_vectors() -> Value {
    let ik = szfriends_vectors::cases(&szfriends_vectors::load("objc-noise.json"), "handshakes")
        .iter()
        .find(|v| v["pattern"] == "IK")
        .expect("the IK vector")
        .clone();
    let text = |name: &str| ik[name].as_str().unwrap().to_owned();
    let preamble = Preamble { pattern: Pattern::IK, cipher: NoiseCipher::AesGcm };
    let prologue = prologue(preamble);
    let initiator_keys = HandshakeKeys {
        local_static: Some(key(&text("initiator_static"))),
        remote_static: Some(*key(&text("responder_static_public"))),
        fixed_ephemeral: Some(key(&text("initiator_ephemeral"))),
    };
    let responder_keys = HandshakeKeys {
        local_static: Some(key(&text("responder_static"))),
        remote_static: None,
        fixed_ephemeral: Some(key(&text("responder_ephemeral"))),
    };
    let mut i = Handshake::with_cipher(Pattern::IK, NoiseCipher::AesGcm, true, &prologue, &initiator_keys).unwrap();
    let mut r = Handshake::with_cipher(Pattern::IK, NoiseCipher::AesGcm, false, &prologue, &responder_keys).unwrap();
    let mut messages = Vec::new();
    for (n, message) in szfriends_vectors::cases(&ik, "messages").iter().take(2).enumerate() {
        let payload = szfriends_vectors::field(message, "payload");
        let (writer, reader) = if n == 0 { (&mut i, &mut r) } else { (&mut r, &mut i) };
        let ciphertext = writer.write(&payload).unwrap();
        assert_eq!(reader.read(&ciphertext).unwrap(), payload);
        messages.push(json!({ "payload": hex::encode(&payload), "ciphertext": hex::encode(&ciphertext) }));
    }
    let hash = i.handshake_hash().unwrap();
    let (mut ti, mut tr) = (i.into_transport().unwrap(), r.into_transport().unwrap());
    // A PART's worth, a REKEY (then that direction's new key), one more each way.
    let part: Vec<u8> = (0..1_000u32).map(|n| (n % 251) as u8).collect();
    let plaintexts: [(&str, Vec<u8>); 5] = [
        ("i2r", part.clone()),
        ("r2i", vec![FrameType::Ping as u8]),
        ("i2r", vec![FrameType::Rekey as u8]),
        ("i2r", part[..100].to_vec()),
        ("r2i", part[..17].to_vec()),
    ];
    let mut transport = Vec::new();
    for (direction, plaintext) in plaintexts {
        let (sender, receiver) = if direction == "i2r" { (&mut ti, &mut tr) } else { (&mut tr, &mut ti) };
        let nonce = sender.sending_nonce();
        let ciphertext = sender.encrypt(&plaintext).unwrap();
        assert_eq!(receiver.decrypt(&ciphertext).unwrap(), plaintext);
        if plaintext == [FrameType::Rekey as u8] {
            sender.rekey_outgoing();
            receiver.rekey_incoming();
        }
        transport.push(json!({
            "direction": direction, "nonce": nonce,
            "plaintext": hex::encode(&plaintext), "ciphertext": hex::encode(&ciphertext),
        }));
    }
    json!({
        "construction": "Noise_IK_25519_AESGCM_BLAKE2b on an IK lane: the IK vector of objc-noise.json with the \
                         preamble's pattern byte 0x81 (IK with bit 7, AES-GCM); nonces are 4 zero bytes and the \
                         64-bit counter big-endian, REKEY as ADR 0001 has it",
        "protocol_name": Pattern::IK.protocol_name_with(NoiseCipher::AesGcm),
        "preamble": hex::encode(preamble.bytes()),
        "prologue": hex::encode(prologue),
        "initiator_static": text("initiator_static"),
        "initiator_ephemeral": text("initiator_ephemeral"),
        "responder_static": text("responder_static"),
        "responder_static_public": text("responder_static_public"),
        "responder_ephemeral": text("responder_ephemeral"),
        "messages": messages,
        "handshake_hash": hex::encode(hash),
        "transport": transport,
        "refused_preambles": [
            { "preamble": "535a0180", "why": "AES-GCM with XX" },
            { "preamble": "535a0182", "why": "AES-GCM with NN" },
            { "preamble": "535a0183", "why": "an unknown pattern" },
        ],
    })
}

/// Compressed parts as a receiver must take or refuse them. zstd's output depends on its version, so these are read
/// by the other helper's tests, not exported: each case is a PART's fields and what it expands to, or "refused".
fn compressed_part_vectors() -> Value {
    let text: Vec<u8> = b"ISO-10303-21;\n#42=CARTESIAN_POINT('',(0.,12.5,3.));\n".iter().copied().cycle().take(2_000).collect();
    let packed = zstd::bulk::compress(&text, compress::LEVEL).unwrap();
    let id = [0x5au8; 16];
    // On the relay a part is padded to 8 KiB, so it must be longer than that to go compressed.
    let long: Vec<u8> = text.iter().copied().cycle().take(12_000).collect();
    let relay = compress::compress_part(frames::part(&id, 4_096, &long), RouteMethod::Relay);
    assert_eq!(relay.get(tag::DATA).map(<[u8]>::len), Some(compress::RELAY_PAD_BYTES));
    let bomb = zstd::bulk::compress(&vec![0u8; 1 << 20], compress::LEVEL).unwrap();
    let case = |name: &str, data: &[u8], codec: Option<u8>, length: Option<u32>, expect: Option<&[u8]>| {
        let mut frame = frames::part(&id, 4_096, data);
        if let Some(codec) = codec {
            frame = frame.with(tag::CODEC, [codec]);
        }
        if let Some(length) = length {
            frame = frame.with(tag::LENGTH, length.to_be_bytes());
        }
        let got = compress::part_data(&frame).ok().map(|d| d.into_owned());
        assert_eq!(got.as_deref(), expect, "{name}");
        json!({
            "name": name, "encoded": hex::encode(frame.encode().unwrap()),
            "expands_to": expect.map_or(json!("refused"), |e| json!(hex::encode(e))),
        })
    };
    let relay_data = relay.get(tag::DATA).unwrap().to_vec();
    json!({
        "construction": "PART (type 30) with Codec (44) = 1, zstd, and Length (45, u32be): Data must expand to exactly \
                         Length bytes, 1 to 61,440, on a session where both set capability bit 2; a relay lane pads \
                         Data to a multiple of 8 KiB with a zstd skippable frame (magic 0x184D2A50, little-endian)",
        "sender": {
            "routes": ["bluetooth", "relay"], "level": compress::LEVEL, "sample_bytes": compress::SAMPLE_BYTES,
            "worth_when_sample_at_most": "90 % of its size", "relay_pad_bytes": compress::RELAY_PAD_BYTES,
        },
        "parts": [
            case("plain", &text, None, None, Some(&text)),
            case("zstd", &packed, Some(1), Some(2_000), Some(&text)),
            case("zstd padded for the relay", &relay_data, Some(1), Some(12_000), Some(&long)),
            case("expands to more than Length", &packed, Some(1), Some(1_999), None),
            case("expands to less than Length", &packed, Some(1), Some(2_001), None),
            case("unknown codec", &packed, Some(2), Some(2_000), None),
            case("Length without Codec", &packed, None, Some(2_000), None),
            case("Codec without Length", &packed, Some(1), None, None),
            case("Length 0", &packed, Some(1), Some(0), None),
            case("Length over 61,440", &packed, Some(1), Some(61_441), None),
            case("truncated", &packed[..packed.len() - 1], Some(1), Some(2_000), None),
            case("a bomb: 1 MiB of zeros said to be 61,440 bytes", &bomb, Some(1), Some(61_440), None),
        ],
    })
}

fn all_vectors() -> Vec<(&'static str, Value)> {
    vec![("aes_lane.json", aes_lane_vectors()), ("compressed_parts.json", compressed_part_vectors())]
}

#[test]
fn transfer_more_vectors_are_what_this_core_computes() {
    let directory = szfriends_vectors::fixtures_dir().join("vectors/transfer-more");
    let write = std::env::var_os("SZFRIENDS_WRITE_TRANSFER_VECTORS").is_some_and(|v| v == "1");
    for (name, value) in all_vectors() {
        let text = serde_json::to_string_pretty(&value).unwrap() + "\n";
        let path = directory.join(name);
        if write {
            std::fs::create_dir_all(&directory).unwrap();
            std::fs::write(&path, &text).unwrap();
            continue;
        }
        let committed = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        assert!(committed == text, "{name} differs from ADR 0018 as this core computes it");
    }
}

#[test]
fn the_refused_preambles_are_refused() {
    let vectors = szfriends_vectors::load("transfer-more/aes_lane.json");
    for case in szfriends_vectors::cases(&vectors, "refused_preambles") {
        let bytes = szfriends_vectors::field(case, "preamble");
        assert!(Preamble::parse(&bytes).is_err(), "{}", case["why"]);
    }
    let lane = szfriends_vectors::field(&vectors, "preamble");
    assert_eq!(Preamble::parse(&lane).unwrap().cipher, NoiseCipher::AesGcm);
}

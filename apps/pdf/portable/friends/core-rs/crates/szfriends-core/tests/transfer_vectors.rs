//! ADR 0018's shared test vectors (`fixtures/vectors/transfer/*.json`), written from the record before either helper
//! shipped it, so the Objective-C helper (WP4, `tools/objc-vectors`) builds against the same bytes: trees and leaves
//! for the sizes the ADR lists, every minor-4 frame and the OFFER and OFFER_REPLY fields, block ranges, lane tokens,
//! both sidecars, and the new SYNC and AGAIN messages.
//!
//! The files are what this test computes; it fails when they differ. `SZFRIENDS_WRITE_TRANSFER_VECTORS=1` writes them
//! (only after a reviewed change to ADR 0018, since the other helper must then change too). Every file's content uses
//! the pattern file `byte(i) = i mod 251`.

use std::collections::BTreeMap;

use blake2::digest::{Update, VariableOutput};
use serde_json::{json, Value};
use szfriends_core::transfer::copies::{lane_token, CopyMessage};
use szfriends_core::transfer::sidecar::{BlockMap, Header, SenderTree};
use szfriends_core::transfer::{tree, BlockSet, Geometry, Leaf};
use szfriends_core::wire::{ranges, tag, Frame, FrameType, HandshakePayload};

const MIB: u64 = 1 << 20;

/// `byte(i) = i mod 251` from `offset`, cut from one cycle long enough for any block of these vectors.
fn pattern(offset: u64, length: usize) -> Vec<u8> {
    static CYCLE: std::sync::OnceLock<Vec<u8>> = std::sync::OnceLock::new();
    let cycle = CYCLE.get_or_init(|| (0..(4 << 20) + 251).map(|i| (i % 251) as u8).collect());
    let start = (offset % 251) as usize;
    if length <= cycle.len() - start {
        return cycle[start..start + length].to_vec();
    }
    (offset..offset + length as u64).map(|i| (i % 251) as u8).collect()
}

fn leaves_of(geometry: &Geometry) -> Vec<Leaf> {
    (0..geometry.blocks)
        .map(|i| {
            let (offset, length) = geometry.span(i);
            tree::leaf(i, &pattern(offset, length))
        })
        .collect()
}

fn blake2b(data: &[u8]) -> [u8; 32] {
    let mut hasher = blake2::Blake2bVar::new(32).unwrap();
    hasher.update(data);
    let mut out = [0u8; 32];
    hasher.finalize_variable(&mut out).unwrap();
    out
}

fn hexes(leaves: &[Leaf]) -> Vec<String> {
    leaves.iter().map(hex::encode).collect()
}

fn tree_case(name: &str, size: u64, shift: u8) -> Value {
    let geometry = Geometry::new(size, shift).unwrap();
    let leaves = leaves_of(&geometry);
    let levels = tree::levels(&leaves);
    let top = tree::top(&leaves);
    let mut case = json!({
        "name": name, "size": size, "shift": shift, "blocks": geometry.blocks,
        "leaves": hexes(&leaves), "top": hex::encode(top), "root": hex::encode(tree::root(&geometry, &top)),
    });
    if leaves.len() <= 8 {
        // Every node above the leaves, level by level: what a proof of any block is made of.
        case["nodes"] = json!(levels[1..].iter().map(|level| hexes(level)).collect::<Vec<_>>());
    }
    case
}

fn tree_vectors() -> Value {
    let mut cases = Vec::new();
    for (name, size) in [
        ("empty", 0),
        ("one_byte", 1),
        ("one_block_minus_one", MIB - 1),
        ("one_block", MIB),
        ("one_block_plus_one", MIB + 1),
        ("three_blocks_plus_7", 3 * MIB + 7),
    ] {
        let geometry = Geometry::for_size(size).unwrap();
        cases.push(tree_case(name, size, geometry.shift));
    }
    cases.push(tree_case("three_blocks_plus_7_at_shift_21", 3 * MIB + 7, 21));
    cases.push(tree_case("one_gib_at_shift_20", 1 << 30, 20));
    cases.push(tree_case("one_gib_at_shift_21", 1 << 30, 21));
    let geometries: Vec<Value> = [0, MIB, 64 << 30, (64 << 30) + 1, 1 << 40]
        .iter()
        .map(|&size| {
            let g = Geometry::for_size(size).unwrap();
            json!({"size": size, "shift": g.shift, "blocks": g.blocks})
        })
        .chain(std::iter::once(json!({"size": (1u64 << 40) + 1, "shift": null, "blocks": null})))
        .collect();
    json!({
        "pattern": "byte(i) = i mod 251, i the offset in the file",
        "prefixes": {
            "leaf": hex::encode(tree::LEAF_PREFIX), "node": hex::encode(tree::NODE_PREFIX),
            "root": hex::encode(tree::ROOT_PREFIX),
        },
        "construction": [
            "leaf(i) = BLAKE3(leaf prefix || u64be(i) || block i)",
            "node = BLAKE3(node prefix || left || right); a lone last node moves up unchanged",
            "root = BLAKE3(root prefix || u64be(size) || u8(shift) || top node)",
            "an empty file is one empty block",
        ],
        "geometry": geometries,
        "trees": cases,
    })
}

fn fields_json(frame: &Frame) -> Value {
    let map: serde_json::Map<String, Value> =
        frame.fields.iter().map(|(t, v)| (t.to_string(), json!([hex::encode(v)]))).collect();
    Value::Object(map)
}

fn encode_case(name: &str, frame: Frame) -> Value {
    let encoded = frame.encode().unwrap_or_else(|e| panic!("{name}: {e}"));
    json!({"name": name, "type": frame.frame_type as u8, "fields": fields_json(&frame), "encoded": hex::encode(encoded)})
}

/// A decoding case whose verdict is written here from the ADR, then checked against the codec.
fn decode_case(name: &str, input: Vec<u8>, ok: bool) -> Value {
    let decoded = Frame::decode(&input);
    assert_eq!(decoded.is_ok(), ok, "{name}: {decoded:?}");
    let shown = if input.len() > 4096 {
        // Long inputs as segments: the head in hex, then the run of the last byte that ends them.
        let last = input[input.len() - 1];
        let run = input.iter().rev().take_while(|b| **b == last).count();
        assert!(run > 4096, "{name}");
        let head = &input[..input.len() - run];
        json!([hex::encode(head), format!("{last:02x}*{run}")])
    } else {
        json!(hex::encode(&input))
    };
    let mut case = json!({"name": name, "input": shown, "ok": u8::from(ok)});
    if let Ok(frame) = decoded {
        case["type"] = json!(frame.frame_type as u8);
        case["fields"] = fields_json(&frame);
    }
    case
}

fn raw(frame_type: FrameType, fields: &[(u8, Vec<u8>)]) -> Vec<u8> {
    let mut out = vec![frame_type as u8];
    for (t, v) in fields {
        out.push(*t);
        out.extend_from_slice(&(v.len() as u16).to_be_bytes());
        out.extend_from_slice(v);
    }
    out
}

fn pairs(ranges: &[(u32, u32)]) -> Vec<u8> {
    ranges.iter().flat_map(|(f, c)| [f.to_be_bytes(), c.to_be_bytes()]).flatten().collect()
}

fn frame_vectors() -> Value {
    let id = hex::decode("1fb38b3957c13dfa57e5b603761145a3").unwrap();
    let geometry = Geometry::for_size(3 * MIB + 7).unwrap();
    let leaves = leaves_of(&geometry);
    let root = tree::root_of(&geometry, &leaves).unwrap();
    let digest = blake2b(&pattern(0, (3 * MIB + 7) as usize));
    let with_id = |t: FrameType| Frame::new(t).with(tag::ID, id.clone());
    let offer = with_id(FrameType::Offer)
        .with(tag::NAME, b"pattern.bin".to_vec())
        .with(tag::FILE_TYPE, b"bin".to_vec())
        .with(tag::SIZE, (3 * MIB + 7).to_be_bytes())
        .with(tag::DIGEST, digest);
    let encode = vec![
        encode_case("offer_with_tree", szfriends_core::transfer::frames::offer_with_tree(offer, &geometry, &root)),
        encode_case("offer_reply_blocks", with_id(FrameType::OfferReply).with(tag::ACCEPT, [1]).with(tag::BLOCKS, [1])),
        encode_case("hashes", szfriends_core::transfer::frames::hashes(&id, &leaves).remove(0)),
        encode_case(
            "hashes_second_frame",
            with_id(FrameType::Hashes).with(tag::INDEX, 2000u32.to_be_bytes()).with(tag::HASHES, leaves[3].to_vec()),
        ),
        encode_case("want", szfriends_core::transfer::frames::want(&id, &[(0, 2), (2, 1), (5, 1)]).remove(0)),
        encode_case("part", szfriends_core::transfer::frames::part(&id, MIB, b"hello")),
        encode_case(
            "part_compressed",
            szfriends_core::transfer::frames::part(&id, 0, &[0x28, 0xb5, 0x2f, 0xfd])
                .with(tag::CODEC, [1])
                .with(tag::LENGTH, 61_440u32.to_be_bytes()),
        ),
        encode_case("have", szfriends_core::transfer::frames::have(&id, &[(0, 3)], &[(0, 1)]).remove(0)),
        encode_case("have_durable_only", szfriends_core::transfer::frames::have(&id, &[], &[(1, 2)]).remove(0)),
        // Pieces (field 47): 16 KiB units counted from the start of the file (ADR 0018 § 3).
        encode_case(
            "want_pieces_only",
            szfriends_core::transfer::frames::want_with_pieces(&id, &[], &[(70, 6), (130, 2)]).remove(0),
        ),
        encode_case(
            "want_blocks_and_pieces",
            szfriends_core::transfer::frames::want_with_pieces(&id, &[(2, 1)], &[(70, 6)]).remove(0),
        ),
        encode_case(
            "have_pieces_and_ranges",
            szfriends_core::transfer::frames::have_with_pieces(&id, &[(0, 1)], &[(0, 1)], &[(64, 16)]).remove(0),
        ),
    ];
    let id_field = (tag::ID, id.clone());
    let decode = vec![
        decode_case(
            "hashes_not_whole_leaves",
            raw(FrameType::Hashes, &[id_field.clone(), (tag::INDEX, vec![0; 4]), (tag::HASHES, vec![1; 33])]),
            false,
        ),
        decode_case(
            "hashes_without_index",
            raw(FrameType::Hashes, &[id_field.clone(), (tag::HASHES, vec![1; 32])]),
            false,
        ),
        decode_case(
            "hashes_index_two_bytes",
            raw(FrameType::Hashes, &[id_field.clone(), (tag::INDEX, vec![0; 2]), (tag::HASHES, vec![1; 32])]),
            false,
        ),
        decode_case(
            "hashes_2001_leaves",
            raw(FrameType::Hashes, &[id_field.clone(), (tag::INDEX, vec![0; 4]), (tag::HASHES, vec![1; 64_032])]),
            false,
        ),
        decode_case("want_without_ranges", raw(FrameType::Want, std::slice::from_ref(&id_field)), false),
        decode_case("want_half_a_range", raw(FrameType::Want, &[id_field.clone(), (tag::RANGES, vec![0; 4])]), false),
        // WANT carries Ranges, Pieces or both: at least one ("want_without_ranges" has neither).
        decode_case(
            "want_pieces_half_a_range",
            raw(FrameType::Want, &[id_field.clone(), (tag::PIECES, vec![0; 4])]),
            false,
        ),
        decode_case(
            "want_pieces_only",
            raw(FrameType::Want, &[id_field.clone(), (tag::PIECES, pairs(&[(3, 2)]))]),
            true,
        ),
        decode_case(
            "have_pieces_only",
            raw(FrameType::Have, &[id_field.clone(), (tag::PIECES, pairs(&[(3, 2)]))]),
            true,
        ),
        decode_case(
            "want_8001_ranges",
            raw(FrameType::Want, &[id_field.clone(), (tag::RANGES, vec![0; 64_008])]),
            false,
        ),
        decode_case(
            "part_61441_bytes",
            raw(FrameType::Part, &[id_field.clone(), (tag::OFFSET, vec![0; 8]), (tag::DATA, vec![0xbb; 61_441])]),
            false,
        ),
        decode_case("part_without_offset", raw(FrameType::Part, &[id_field.clone(), (tag::DATA, vec![1])]), false),
        decode_case(
            "part_length_two_bytes",
            raw(
                FrameType::Part,
                &[id_field.clone(), (tag::OFFSET, vec![0; 8]), (tag::DATA, vec![1]), (tag::LENGTH, vec![0; 2])],
            ),
            false,
        ),
        decode_case("have_with_nothing", raw(FrameType::Have, std::slice::from_ref(&id_field)), true),
        decode_case(
            "offer_reply_blocks_not_boolean",
            raw(FrameType::OfferReply, &[id_field.clone(), (tag::ACCEPT, vec![1]), (tag::BLOCKS, vec![2])]),
            false,
        ),
        decode_case(
            "offer_tree_root_short",
            raw(
                FrameType::Offer,
                &[
                    id_field.clone(),
                    (tag::NAME, b"a".to_vec()),
                    (tag::SIZE, vec![0; 8]),
                    (tag::DIGEST, vec![0; 32]),
                    (tag::TREE_ROOT, vec![0; 31]),
                ],
            ),
            false,
        ),
        decode_case(
            "chunk_ignores_part_fields",
            raw(
                FrameType::Chunk,
                &[id_field.clone(), (tag::OFFSET, vec![0; 8]), (tag::DATA, vec![1]), (tag::CODEC, vec![1])],
            ),
            true,
        ),
    ];
    // Ranges: what WANT and HAVE accept beyond the field's length rule.
    let range_cases: Vec<Value> = [
        ("one", vec![(0u32, 1u32)], true),
        ("two", vec![(0, 3), (5, 1)], true),
        ("adjacent", vec![(0, 3), (3, 1)], true),
        ("last_block", vec![(u32::MAX, 1)], true),
        ("empty_range", vec![(4, 0)], false),
        ("overlapping", vec![(0, 3), (2, 1)], false),
        ("descending", vec![(5, 1), (0, 1)], false),
        ("past_the_last_block", vec![(u32::MAX, 2)], false),
    ]
    .into_iter()
    .map(|(name, list, ok)| {
        let input = pairs(&list);
        assert_eq!(ranges::decode(&input).is_some(), ok, "{name}");
        json!({"name": name, "input": hex::encode(input), "ok": u8::from(ok)})
    })
    .collect();
    let payloads: Vec<Value> = [
        ("fast_transfers", HandshakePayload { capabilities: 1, ..HandshakePayload::local() }),
        (
            "lane",
            HandshakePayload {
                capabilities: 1,
                route_class: Some(1),
                lane: Some(lane_token(&[0x5a; 64], 1).to_vec()),
                ..HandshakePayload::local()
            },
        ),
    ]
    .into_iter()
    .map(|(name, payload)| json!({"name": name, "encoded": hex::encode(payload.encode().unwrap())}))
    .collect();
    json!({
        "session_minor": szfriends_core::wire::consts::SESSION_MINOR,
        "piece_shift": szfriends_core::wire::consts::PIECE_SHIFT,
        "capabilities": {"fast_transfers": 1, "aes_lanes": 2, "compressed_parts": 4},
        "close_lane_refused": szfriends_core::wire::CloseReason::LaneRefused as u8,
        "encode": encode, "decode": decode, "ranges": range_cases, "handshake_payloads": payloads,
    })
}

fn lane_vectors() -> Value {
    let cases: Vec<Value> = [(std::array::from_fn::<u8, 64, _>(|i| i as u8), 1u8), ([0xa5; 64], 15)]
        .iter()
        .map(|(h, index)| json!({"h": hex::encode(h), "index": index, "token": hex::encode(lane_token(h, *index))}))
        .collect();
    json!({"construction": "keyed BLAKE2b-128, key h (64 bytes), over \"SZFriends lane v1\" || u8 index", "lanes": cases})
}

fn sidecar_vectors() -> Value {
    let size = 3 * MIB + 7;
    let geometry = Geometry::for_size(size).unwrap();
    let leaves = leaves_of(&geometry);
    let root = tree::root_of(&geometry, &leaves).unwrap();
    let header = Header { geometry, root, digest: blake2b(&pattern(0, size as usize)) };
    let offered = BlockMap::new(header);
    let mut checked = BlockMap::new(header);
    checked.leaves = Some(leaves.clone());
    checked.durable = BlockSet::new(geometry.blocks);
    checked.durable.insert(0);
    checked.durable.insert(2);
    let sender = SenderTree { header, leaves };
    json!({
        "file": {"size": size, "shift": geometry.shift, "pattern": "byte(i) = i mod 251"},
        "map_at_offer": hex::encode(offered.encode()),
        "map_blocks_0_and_2_durable": hex::encode(checked.encode()),
        "tree": hex::encode(sender.encode()),
    })
}

fn message_vectors() -> Value {
    let id = "1fb38b3957c13dfa57e5b603761145a3".to_owned();
    let want = CopyMessage::WantBlocks { id: id.clone(), shift: 20, ranges: vec![(0, 2), (3, 1)] };
    let follow = CopyMessage::BlocksFollow { id, root: [0x42; 32], shift: 20 };
    json!({
        "sync": [
            {"name": "want_blocks", "kind": 7, "encoded": hex::encode(want.encode_sync().unwrap())},
            {"name": "blocks_follow", "kind": 8, "encoded": hex::encode(follow.encode_sync().unwrap())},
        ],
        "again": [
            {"name": "want_blocks", "kind": 4, "encoded": hex::encode(want.encode_again().unwrap())},
            {"name": "blocks_follow", "kind": 5, "encoded": hex::encode(follow.encode_again().unwrap())},
        ],
    })
}

fn all_vectors() -> BTreeMap<&'static str, Value> {
    BTreeMap::from([
        ("tree.json", tree_vectors()),
        ("frames.json", frame_vectors()),
        ("lanes.json", lane_vectors()),
        ("sidecars.json", sidecar_vectors()),
        ("messages.json", message_vectors()),
    ])
}

#[test]
fn transfer_vectors_are_what_this_core_computes() {
    let directory = szfriends_vectors::fixtures_dir().join("vectors/transfer");
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
fn the_committed_trees_check_against_their_roots() {
    // Independent of how they were written: every tree's leaves hash to its root, and every frame vector decodes to
    // its fields.
    let trees = szfriends_vectors::load("transfer/tree.json");
    for case in szfriends_vectors::cases(&trees, "trees") {
        let geometry = Geometry::new(case["size"].as_u64().unwrap(), case["shift"].as_u64().unwrap() as u8).unwrap();
        let leaves: Vec<Leaf> = szfriends_vectors::cases(case, "leaves")
            .iter()
            .map(|l| hex::decode(l.as_str().unwrap()).unwrap().try_into().unwrap())
            .collect();
        let root = tree::root_of(&geometry, &leaves).unwrap();
        assert_eq!(hex::encode(root), case["root"].as_str().unwrap(), "{}", case["name"]);
    }
    let frames = szfriends_vectors::load("transfer/frames.json");
    for case in szfriends_vectors::cases(&frames, "encode") {
        let frame = Frame::decode(&szfriends_vectors::field(case, "encoded")).unwrap();
        assert_eq!(fields_json(&frame), case["fields"], "{}", case["name"]);
    }
    for case in szfriends_vectors::cases(&frames, "decode") {
        let ok = Frame::decode(&szfriends_vectors::bytes(&case["input"])).is_ok();
        assert_eq!(ok, szfriends_vectors::flag(case, "ok"), "{}", case["name"]);
    }
}

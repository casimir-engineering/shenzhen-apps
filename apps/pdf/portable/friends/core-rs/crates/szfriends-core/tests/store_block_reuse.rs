//! Reusing blocks this computer holds (ADR 0018 § 9.5, WP6): a new version of a file a friend sent before arrives
//! with only its changed blocks wanted, the others read from the earlier version and checked against the new leaves;
//! nothing is reused across friends; a file changed since it was indexed gives nothing it no longer holds.

use std::path::{Path, PathBuf};

use szfriends_core::store::{file_digest, Person, Relation, Store};
use szfriends_core::transfer::{tree, Geometry};

struct Scratch(PathBuf);

impl Scratch {
    fn new(label: &str) -> Self {
        let mut bytes = [0u8; 6];
        szfriends_core::crypto::random_bytes(&mut bytes);
        let suffix: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        let base = std::env::temp_dir().join(format!("szf-reuse-{label}-{}-{suffix}", std::process::id()));
        std::fs::create_dir_all(&base).unwrap();
        Self(base)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn friend(store: &mut Store, key: u8) -> String {
    let mut person = Person::new(Relation::Friend);
    person.identity_key = Some([key; 32]);
    person.static_key = Some([key ^ 0xff; 32]);
    store.save_person(&person).unwrap();
    person.conversation_id
}

fn content(size: usize, seed: usize) -> Vec<u8> {
    (0..size).map(|i| (i.wrapping_add(seed).wrapping_mul(2_654_435_761) >> 13) as u8).collect()
}

/// Offers `data` from `conversation` as `id`, accepts it and hands over its leaves: the blocks the store found here
/// are reported at once, as the helper's HAVE after the leaves.
fn offer(store: &mut Store, scratch: &Path, id: &str, conversation: &str, data: &[u8]) -> (Geometry, Vec<(u32, u32)>) {
    let source = scratch.join(format!("{id}.src"));
    std::fs::write(&source, data).unwrap();
    let digest = file_digest(&source, u64::MAX).unwrap();
    let geometry = Geometry::for_size(data.len() as u64).unwrap();
    let hashed = tree::hash_file(&std::fs::File::open(&source).unwrap(), &geometry, false).unwrap();
    store.record_incoming_offer(id, conversation, "model.step", None, data.len() as u64, &digest, 0.0).unwrap();
    store.record_offered_tree(id, conversation, geometry, hashed.root).unwrap();
    store.accept_transfer(id).unwrap();
    assert!(store.begin_blocks(id, conversation).unwrap());
    assert!(store.block_hashes(id, conversation, 0, &hashed.leaves.concat()).unwrap());
    let (complete, _) = store.take_block_have(id);
    (geometry, complete)
}

fn receive_rest(store: &mut Store, id: &str, conversation: &str, data: &[u8], geometry: &Geometry) -> PathBuf {
    for (first, count) in store.block_missing(id) {
        for block in first..first + count {
            let (offset, length) = geometry.span(block);
            for start in (0..length).step_by(61_440) {
                let at = offset as usize + start;
                let end = (at + 61_440).min(offset as usize + length);
                store.block_part(id, conversation, at as u64, &data[at..end]).unwrap();
            }
        }
    }
    assert!(store.blocks_all_durable(id));
    store.finish_block_transfer(id, conversation).unwrap()
}

#[test]
fn a_new_version_from_the_same_friend_wants_only_its_changed_blocks() {
    let scratch = Scratch::new("version");
    let mut store = Store::open(scratch.0.join("state")).unwrap();
    let (mei, ben) = (friend(&mut store, 4), friend(&mut store, 5));
    let first = content(6 * (1 << 20) + 1_000, 1);
    let (geometry, reused) = offer(&mut store, &scratch.0, "11111111111111111111111111111111", &mei, &first);
    assert!(reused.is_empty(), "nothing to reuse yet");
    let saved = receive_rest(&mut store, "11111111111111111111111111111111", &mei, &first, &geometry);
    assert_eq!(std::fs::read(&saved).unwrap(), first);

    // The same model, edited in block 2, and one more block at the end.
    let mut second = first.clone();
    second[(2 << 20) + 77] ^= 0x10;
    second.extend_from_slice(&content(1 << 20, 9));
    let (geometry, reused) = offer(&mut store, &scratch.0, "22222222222222222222222222222222", &mei, &second);
    assert_eq!(reused, vec![(0, 2), (3, 3)], "blocks 0, 1, 3, 4 and 5 are here already");
    assert_eq!(store.block_missing("22222222222222222222222222222222"), vec![(2, 1), (6, 2)]);
    let saved = receive_rest(&mut store, "22222222222222222222222222222222", &mei, &second, &geometry);
    assert_eq!(std::fs::read(&saved).unwrap(), second, "the publish check passed on the reused blocks too");

    // Another friend offering the same bytes learns nothing from this person's files of Mei's.
    let (_, reused) = offer(&mut store, &scratch.0, "33333333333333333333333333333333", &ben, &second);
    assert!(reused.is_empty());
}

#[test]
fn a_file_changed_since_gives_only_what_still_matches() {
    let scratch = Scratch::new("changed");
    let mut store = Store::open(scratch.0.join("state")).unwrap();
    let mei = friend(&mut store, 4);
    let first = content(4 << 20, 3);
    let (geometry, _) = offer(&mut store, &scratch.0, "44444444444444444444444444444444", &mei, &first);
    let saved = receive_rest(&mut store, "44444444444444444444444444444444", &mei, &first, &geometry);
    // The person edited block 1 of the saved file since.
    let file = std::fs::OpenOptions::new().write(true).open(&saved).unwrap();
    tree::write_all_at(&file, b"edited", (1 << 20) + 5).unwrap();
    let (_, reused) = offer(&mut store, &scratch.0, "55555555555555555555555555555555", &mei, &first);
    assert_eq!(reused, vec![(0, 1), (2, 2)], "block 1 fails its leaf there and is wanted from Mei");
    // And a file that is gone is forgotten.
    std::fs::remove_file(&saved).unwrap();
    let (_, reused) = offer(&mut store, &scratch.0, "66666666666666666666666666666666", &mei, &first);
    assert!(reused.is_empty());
}

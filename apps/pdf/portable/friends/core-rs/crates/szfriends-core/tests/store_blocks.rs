//! ADR 0018 § 4 and 5 on disk: a download by blocks out of order, a corrupt block wanted again alone, a crash that
//! loses what was not durable, a block changed on disk under the map, resuming exactly what is missing, the publish
//! check; and the sender's tree beside its snapshot, which catches a snapshot changed under it.

use std::path::PathBuf;

use szfriends_core::store::{file_digest, BlockPart, Person, Relation, Store, StoreError, TransferState};
use szfriends_core::transfer::{tree, BlockServe, Geometry, ServeError};

struct Scratch(PathBuf);

impl Scratch {
    fn new(label: &str) -> Self {
        let mut bytes = [0u8; 6];
        szfriends_core::crypto::random_bytes(&mut bytes);
        let suffix: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        let base = std::env::temp_dir().join(format!("szf-blocks-{label}-{}-{suffix}", std::process::id()));
        std::fs::create_dir_all(&base).unwrap();
        Self(base)
    }

    fn state(&self) -> PathBuf {
        self.0.join("state")
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn friend(store: &mut Store) -> String {
    let mut person = Person::new(Relation::Friend);
    person.identity_key = Some([4; 32]);
    person.static_key = Some([0xfb; 32]);
    store.save_person(&person).unwrap();
    person.conversation_id
}

fn content(size: usize) -> Vec<u8> {
    (0..size).map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8).collect()
}

fn send_block(
    store: &mut Store,
    id: &str,
    conversation: &str,
    data: &[u8],
    geometry: &Geometry,
    block: u32,
) -> BlockPart {
    let (offset, length) = geometry.span(block);
    let mut last = BlockPart::Pending;
    for start in (0..length).step_by(61_440) {
        let end = (start + 61_440).min(length);
        let at = offset as usize + start;
        last = store.block_part(id, conversation, at as u64, &data[at..at + end - start]).unwrap();
    }
    last
}

#[test]
fn a_download_by_blocks_resumes_exactly_what_is_missing_and_checks_before_publishing() {
    let scratch = Scratch::new("receive");
    let data = content(20 * (1 << 20) + 3);
    let source = scratch.0.join("source.bin");
    std::fs::write(&source, &data).unwrap();
    let digest = file_digest(&source, u64::MAX).unwrap();
    let geometry = Geometry::for_size(data.len() as u64).unwrap();
    let hashed = tree::hash_file(&std::fs::File::open(&source).unwrap(), &geometry, false).unwrap();
    let id = "0123456789abcdef0123456789abcdef";
    let conversation = {
        let mut store = Store::open(scratch.state()).unwrap();
        let conversation = friend(&mut store);
        store.record_incoming_offer(id, &conversation, "plan.step", None, data.len() as u64, &digest, 0.0).unwrap();
        store.record_offered_tree(id, &conversation, geometry, hashed.root).unwrap();
        assert!(store.begin_blocks(id, &conversation).is_err(), "not accepted yet");
        store.accept_transfer(id).unwrap();
        assert!(store.begin_blocks(id, &conversation).unwrap());
        assert!(store.block_part(id, &conversation, 0, &data[..10]).is_err(), "no part before the leaves");
        let leaves = hashed.leaves.concat();
        assert!(!store.block_hashes(id, &conversation, 0, &leaves[..32 * 5]).unwrap());
        assert!(store.block_hashes(id, &conversation, 5, &leaves[32 * 5..]).unwrap());
        // Out of order; block 3 arrives corrupted and is wanted again alone.
        for block in [7, 0, 1, 2, 4, 5, 6, 8, 9, 10, 11] {
            assert_eq!(send_block(&mut store, id, &conversation, &data, &geometry, block), BlockPart::Written(block));
        }
        let mut bad = data.clone();
        bad[(3 << 20) + 5] ^= 0x40;
        assert_eq!(send_block(&mut store, id, &conversation, &bad, &geometry, 3), BlockPart::Corrupt(3));
        assert_eq!(store.block_part(id, &conversation, 0, &data[..10]).unwrap(), BlockPart::Late);
        let (complete, durable) = store.take_block_have(id);
        assert_eq!(complete, vec![(0, 3), (4, 8)]);
        assert_eq!(durable, vec![(0, 3), (4, 5)], "the first 8 MiB batch made durable");
        assert_eq!(store.transfer(id).unwrap().unwrap().verified_bytes, 3 << 20, "the contiguous durable prefix");
        conversation
        // Dropped without a flush: blocks 9 to 11 were never made durable.
    };
    // Block 1 changed on disk behind the map's back: it no longer counts.
    {
        let partial = std::fs::read_dir(scratch.state().join("received/.partial"))
            .unwrap()
            .flatten()
            .find(|e| e.path().extension().is_some_and(|x| x == "part"))
            .unwrap()
            .path();
        let file = std::fs::OpenOptions::new().write(true).open(partial).unwrap();
        tree::write_all_at(&file, b"x", (1 << 20) + 9).unwrap();
    }
    let mut store = Store::open(scratch.state()).unwrap();
    assert!(store.has_block_map(id), "the recovery sweep keeps the map of an open download");
    assert!(store.begin_blocks(id, &conversation).unwrap());
    assert_eq!(store.block_missing(id), vec![(1, 1), (3, 1), (9, 12)]);
    assert_eq!(store.transfer(id).unwrap().unwrap().verified_bytes, 1 << 20);
    for block in [1, 3, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20] {
        assert_eq!(send_block(&mut store, id, &conversation, &data, &geometry, block), BlockPart::Written(block));
    }
    assert!(store.blocks_all_durable(id));
    let received = store.finish_block_transfer(id, &conversation).unwrap();
    assert_eq!(std::fs::read(&received).unwrap(), data);
    assert_eq!(store.transfer(id).unwrap().unwrap().state, TransferState::Received);
    assert!(!store.block_map_path(id).exists(), "the map goes with the download");
}

#[test]
fn a_file_whose_bytes_miss_the_offered_digest_is_not_published() {
    // The tree checks, the digest does not: a sender cannot make a file's identity differ from its bytes.
    let scratch = Scratch::new("digest");
    let data = content(3 << 20);
    let geometry = Geometry::for_size(data.len() as u64).unwrap();
    let leaves: Vec<tree::Leaf> =
        (0..3).map(|i| tree::leaf(i, &data[(i as usize) << 20..((i as usize) + 1) << 20])).collect();
    let root = tree::root_of(&geometry, &leaves).unwrap();
    let mut store = Store::open(scratch.state()).unwrap();
    let conversation = friend(&mut store);
    let id = "11111111111111111111111111111111";
    store.record_incoming_offer(id, &conversation, "a.bin", None, data.len() as u64, &[9; 32], 0.0).unwrap();
    store.record_offered_tree(id, &conversation, geometry, root).unwrap();
    store.accept_transfer(id).unwrap();
    store.block_hashes(id, &conversation, 0, &leaves.concat()).unwrap();
    for block in 0..3 {
        send_block(&mut store, id, &conversation, &data, &geometry, block);
    }
    assert_eq!(store.finish_block_transfer(id, &conversation), Err(StoreError::DigestMismatch));
    assert_eq!(store.transfer(id).unwrap().unwrap().state, TransferState::Failed);
}

#[test]
fn the_sender_keeps_its_tree_and_a_changed_snapshot_fails_at_its_first_changed_block() {
    let scratch = Scratch::new("send");
    let data = content(5 * (1 << 20) + 17);
    let source = scratch.0.join("drawing.step");
    std::fs::write(&source, &data).unwrap();
    let mut store = Store::open(scratch.state()).unwrap();
    let conversation = friend(&mut store);
    let record = store.stage_outgoing_file(&source, None, &conversation).unwrap();
    let tree = store.sender_tree(&record).unwrap();
    assert!(store.sender_tree_path(&record.transfer_id).exists());
    assert_eq!(store.sender_tree(&record).unwrap(), tree, "read back from its sidecar");
    let geometry = tree.header.geometry;
    let mut serve = BlockServe::new(&[1; 16], geometry, tree.leaves.clone(), 61_440, 8 << 20);
    serve.want_all();
    let first = serve.next_block().unwrap();
    serve.load_block(first, store.read_outgoing_block(&record, &geometry, first).unwrap()).unwrap();
    // The snapshot changes under the sender: the block that changed is refused before a byte of it leaves.
    {
        let snapshot = record.staged_path.as_ref().unwrap();
        let file = std::fs::OpenOptions::new().write(true).open(snapshot).unwrap();
        tree::write_all_at(&file, b"!", 1 << 20).unwrap();
    }
    while serve.next_part().is_some() {}
    let second = serve.next_block().unwrap();
    assert_eq!(
        serve.load_block(second, store.read_outgoing_block(&record, &geometry, second).unwrap()),
        Err(ServeError::Changed)
    );
    // A sweep at the next start keeps the open transfer's tree and drops a stray sidecar.
    let stray = store.sender_tree_path("ffffffffffffffffffffffffffffffff");
    std::fs::write(&stray, b"stray").unwrap();
    drop(store);
    let store = Store::open(scratch.state()).unwrap();
    assert!(store.sender_tree_path(&record.transfer_id).exists() && !stray.exists());
}

#[test]
fn fast_transfers_are_on_unless_the_setting_says_no() {
    let scratch = Scratch::new("setting");
    let mut store = Store::open(scratch.state()).unwrap();
    assert!(store.fast_transfers_enabled(), "on by default");
    store.set_fast_transfers_enabled(false).unwrap();
    drop(store);
    let mut store = Store::open(scratch.state()).unwrap();
    assert!(!store.fast_transfers_enabled(), "kept across a restart");
    store.set_fast_transfers_enabled(true).unwrap();
    assert!(store.fast_transfers_enabled());
}

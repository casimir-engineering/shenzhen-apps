//! The store's behaviour (`SZFriendsStoreTests`, `SZFriendsOutboxTests`, `SZFriendsTransferReceiveTests`,
//! `SZFriendsStoreMigrationTests`, `SZFriendsStoreCrashTests`): the identity it records, refusing a newer schema, a
//! failed migration, the outbox and its offers, people's keys, and a file received through durable progress, a crash,
//! a digest check and publishing; history deleted by chat and in full.

use std::path::{Path, PathBuf};

use szfriends_core::identity::keystore::StoreIdentity;
use szfriends_core::store::sync_history;
use szfriends_core::store::{
    file_digest, Direction, Item, ItemKind, Migration, OutboxEntry, OutboxEvent, OutboxKind, OutboxState, Person,
    Relation, Store, StoreError, StoreOptions, TransferState, DURABLE_BATCH_BYTES, SHIPPED,
};

struct Scratch(PathBuf);

impl Scratch {
    fn new(label: &str) -> Self {
        let mut bytes = [0u8; 6];
        szfriends_core::crypto::random_bytes(&mut bytes);
        let suffix: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        let base = std::env::temp_dir().join(format!("szf-flows-{label}-{}-{suffix}", std::process::id()));
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

fn friend(store: &mut Store, name: &str, key: u8) -> Person {
    let mut person = Person::new(Relation::Friend);
    person.name = Some(name.to_owned());
    person.identity_key = Some([key; 32]);
    person.static_key = Some([key ^ 0xff; 32]);
    store.save_person(&person).unwrap();
    person
}

fn message(conversation: &str, id: &str, direction: Direction) -> Item {
    Item {
        item_id: id.to_owned(),
        conversation_id: conversation.to_owned(),
        kind: ItemKind::Message,
        direction,
        text: Some(format!("hello {id}")),
        transfer_id: None,
        sent_at: 1_791_787_668.0,
        received_at: 1_791_787_668.0,
        via_assistant: false,
    }
}

fn entry(conversation: &str, id: &str, kind: OutboxKind, item: Option<&str>) -> OutboxEntry {
    OutboxEntry {
        entry_id: id.to_owned(),
        conversation_id: conversation.to_owned(),
        kind,
        state: OutboxState::Delivered,
        created_at: 1_791_787_668.0,
        queued_at: 0.0,
        attempts: 0,
        item_id: item.map(str::to_owned),
        client_token: Some("token-1".to_owned()),
        failure_reason: None,
        payload: None,
    }
}

#[test]
fn the_store_records_its_identity_and_refuses_another() {
    let scratch = Scratch::new("identity");
    assert_eq!(Store::identity_of(scratch.state()).unwrap(), StoreIdentity::NoStore);
    let mut store = Store::open(scratch.state()).unwrap();
    store.record_identity(&[1; 32]).unwrap();
    store.record_identity(&[1; 32]).unwrap();
    assert_eq!(store.record_identity(&[2; 32]), Err(StoreError::IdentityMismatch));
    drop(store);
    assert_eq!(Store::identity_of(scratch.state()).unwrap(), StoreIdentity::Recorded([1; 32]));
}

#[test]
fn a_newer_schema_is_left_alone_and_a_failed_migration_keeps_the_backup() {
    let scratch = Scratch::new("versions");
    drop(Store::open(scratch.state()).unwrap());
    let newer = SHIPPED.iter().copied().chain([Migration { version: 10, min_reader_version: 10, sql: "SELECT 1" }]);
    let options = StoreOptions { migrations: Some(newer.collect()), ..StoreOptions::default() };
    drop(Store::open_with(scratch.state(), options).unwrap());
    assert!(matches!(Store::open(scratch.state()), Err(StoreError::NewerSchema { needs: 10, reads: 9 })));
    let other = Scratch::new("failing");
    drop(Store::open(other.state()).unwrap());
    let broken = SHIPPED.iter().copied().chain([Migration { version: 10, min_reader_version: 0, sql: "NOT SQL" }]);
    let options = StoreOptions { migrations: Some(broken.collect()), ..StoreOptions::default() };
    assert!(matches!(Store::open_with(other.state(), options), Err(StoreError::MigrationFailed(_))));
    assert!(other.state().join("friends.sqlite.before-v10").exists());
    assert_eq!(Store::open(other.state()).unwrap().schema_version(), 9);
}

#[test]
fn a_person_keeps_their_keys_and_history_deduplicates() {
    let scratch = Scratch::new("people");
    let mut store = Store::open(scratch.state()).unwrap();
    let mei = friend(&mut store, "Mei", 7);
    let mut moved = mei.clone();
    moved.identity_key = Some([8; 32]);
    assert_eq!(store.save_person(&moved), Err(StoreError::KeyChangeRefused));
    assert_eq!(store.person_with_identity_key(&[7; 32]).unwrap().unwrap().conversation_id, mei.conversation_id);
    assert!(store.insert_item(&message(&mei.conversation_id, "m1", Direction::Incoming)).unwrap());
    assert!(!store.insert_item(&message(&mei.conversation_id, "m1", Direction::Incoming)).unwrap());
    assert_eq!(store.person_with_conversation(&mei.conversation_id).unwrap().unwrap().unread_count, 1);
    assert_eq!(store.search("HELLO m1", None, 5).unwrap().len(), 1);
}

#[test]
fn the_outbox_moves_through_its_states_and_only_the_owner_acknowledges() {
    let scratch = Scratch::new("outbox");
    let mut store = Store::open(scratch.state()).unwrap();
    let (mei, priya) = (friend(&mut store, "Mei", 1), friend(&mut store, "Priya", 2));
    let item = message(&mei.conversation_id, "m1", Direction::Outgoing);
    let queued =
        store.enqueue(&entry(&mei.conversation_id, "e1", OutboxKind::Message, Some("m1")), Some(&item)).unwrap();
    assert_eq!(queued.state, OutboxState::Queued);
    let duplicate = entry(&mei.conversation_id, "e1", OutboxKind::Message, Some("m1"));
    assert_eq!(store.enqueue(&duplicate, None), Err(StoreError::Constraint));
    store.apply_outbox_event("e1", OutboxEvent::RouteAvailable).unwrap();
    store.apply_outbox_event("e1", OutboxEvent::Written).unwrap();
    let sending = store.outbox_entry("e1").unwrap().unwrap();
    assert_eq!((sending.state, sending.attempts), (OutboxState::Sending, 1));
    // Cancel is too late once written.
    assert_eq!(store.cancel_message("m1", &mei.conversation_id), Err(StoreError::Stale));
    assert!(matches!(
        store.apply_outbox_event_from("e1", OutboxEvent::Acknowledged, &priya.conversation_id),
        Err(StoreError::Invalid(_))
    ));
    store.apply_outbox_event_from("e1", OutboxEvent::Acknowledged, &mei.conversation_id).unwrap();
    assert_eq!(store.outbox_entry("e1").unwrap().unwrap().state, OutboxState::Delivered);
    // A queued message never written can be withdrawn; an old one expires.
    let item = message(&mei.conversation_id, "m2", Direction::Outgoing);
    store.enqueue(&entry(&mei.conversation_id, "e2", OutboxKind::Message, Some("m2")), Some(&item)).unwrap();
    store.cancel_message("m2", &mei.conversation_id).unwrap();
    assert!(store.outbox_entry("e2").unwrap().is_none());
    store.enqueue(&entry(&priya.conversation_id, "e3", OutboxKind::Message, None), None).unwrap();
    let expired = store.expire_outbox(1_791_787_668.0 + 31.0 * 86_400.0).unwrap();
    assert_eq!(expired.len(), 1);
    assert_eq!(expired[0].failure_reason.as_deref(), Some("not_delivered_30_days"));
    assert!(store.pending_outbox(&priya.conversation_id).unwrap().is_empty());
}

fn write_file(path: &Path, size: usize) -> Vec<u8> {
    let data: Vec<u8> = (0..size).map(|i| (i * 7 + i / 251) as u8).collect();
    std::fs::write(path, &data).unwrap();
    data
}

#[test]
fn an_offer_entry_moves_its_transfer_and_an_answer_resumes_at_the_offset() {
    let scratch = Scratch::new("offer");
    let mut store = Store::open(scratch.state()).unwrap();
    let mei = friend(&mut store, "Mei", 3);
    let source = scratch.0.join("Plan.pdf");
    write_file(&source, 100_000);
    let record = store.stage_outgoing_file(&source, None, &mei.conversation_id).unwrap();
    assert_eq!((record.state, record.size, record.file_name.as_str()), (TransferState::Queued, 100_000, "Plan.pdf"));
    assert_eq!(record.digest, file_digest(&source, u64::MAX).unwrap());
    let offer = entry(&mei.conversation_id, "e-offer", OutboxKind::Offer, Some(&record.transfer_id));
    store.enqueue(&offer, None).unwrap();
    store.apply_outbox_event_from("e-offer", OutboxEvent::Acknowledged, &mei.conversation_id).unwrap();
    assert_eq!(store.transfer(&record.transfer_id).unwrap().unwrap().state, TransferState::Offered);
    let answer = store.peer_answered_transfer(&record.transfer_id, true, 4096, &mei.conversation_id).unwrap();
    assert_eq!(answer.state, TransferState::Sending);
    assert_eq!(store.read_outgoing(&answer, 4096, 10).unwrap(), std::fs::read(&source).unwrap()[4096..4106]);
    // A new session resumes the same transfer; an offset past the end is stale.
    store.peer_answered_transfer(&record.transfer_id, true, 8192, &mei.conversation_id).unwrap();
    assert_eq!(
        store.peer_answered_transfer(&record.transfer_id, true, 100_001, &mei.conversation_id).unwrap_err(),
        StoreError::Stale
    );
    store.peer_verified_transfer(&record.transfer_id, &mei.conversation_id).unwrap();
    assert_eq!(store.transfer(&record.transfer_id).unwrap().unwrap().state, TransferState::Delivered);
    assert!(!answer.staged_path.unwrap().exists(), "the snapshot goes once delivered");
}

#[test]
fn a_received_file_survives_a_crash_is_checked_and_never_overwrites() {
    let scratch = Scratch::new("receive");
    let source = scratch.0.join("source.bin");
    let data = write_file(&source, (DURABLE_BATCH_BYTES as usize) + 300_000);
    let digest = file_digest(&source, u64::MAX).unwrap();
    let (conversation, transfer_id) = {
        let mut store = Store::open(scratch.state()).unwrap();
        let mei = friend(&mut store, "Mei", 4);
        let id = "0123456789abcdef0123456789abcdef";
        let size = data.len() as u64;
        store.record_incoming_offer(id, &mei.conversation_id, "../Site photos.pdf", None, size, &digest, 0.0).unwrap();
        // Strangers and wrong conversations never get a byte in.
        assert!(store.append_chunk(id, 0, &data[..10], &mei.conversation_id).is_err(), "not accepted yet");
        store.accept_transfer(id).unwrap();
        assert!(store.append_chunk(id, 0, &data[..10], "someone-else").is_err());
        let mut durable = 0;
        let mut offset = 0;
        while offset < DURABLE_BATCH_BYTES as usize + 100_000 {
            let end = (offset + 61_440).min(data.len());
            durable = store.append_chunk(id, offset as u64, &data[offset..end], &mei.conversation_id).unwrap();
            offset = end;
        }
        assert!(durable >= DURABLE_BATCH_BYTES && durable < offset as u64, "{durable} {offset}");
        assert!(store.append_chunk(id, 5, &data[5..10], &mei.conversation_id).is_err(), "out of place");
        (mei.conversation_id, id.to_owned())
        // Dropped without a flush: the bytes past the durable count were never confirmed.
    };
    let mut store = Store::open(scratch.state()).unwrap();
    let record = store.unfinished_incoming_transfers(&conversation).unwrap().pop().unwrap();
    let resume = record.verified_bytes as usize;
    assert!(resume >= DURABLE_BATCH_BYTES as usize);
    for start in (resume..data.len()).step_by(61_440) {
        let end = (start + 61_440).min(data.len());
        store.append_chunk(&transfer_id, start as u64, &data[start..end], &conversation).unwrap();
    }
    let received = store.finish_transfer(&transfer_id, &digest, &conversation).unwrap();
    assert_eq!(std::fs::read(&received).unwrap(), data);
    assert_eq!(received.file_name().unwrap(), "-Site photos.pdf");
    assert_eq!(store.transfer(&transfer_id).unwrap().unwrap().state, TransferState::Received);
    // A second file of the same name lands beside it; a corrupted one is deleted and fails.
    let digest_other = file_digest(&source, 1000).unwrap();
    let other = "fedcba9876543210fedcba9876543210";
    store.record_incoming_offer(other, &conversation, "-Site photos.pdf", None, 1000, &digest_other, 0.0).unwrap();
    store.accept_transfer(other).unwrap();
    let mut corrupted = data[..1000].to_vec();
    corrupted[999] ^= 1;
    store.append_chunk(other, 0, &corrupted, &conversation).unwrap();
    assert_eq!(store.finish_transfer(other, &digest_other, &conversation), Err(StoreError::DigestMismatch));
    let failed = store.transfer(other).unwrap().unwrap();
    assert_eq!((failed.state, failed.failure_reason.as_deref()), (TransferState::Failed, Some("digest_mismatch")));
    let third = "00112233445566778899aabbccddeeff";
    store.record_incoming_offer(third, &conversation, "-Site photos.pdf", None, 1000, &digest_other, 0.0).unwrap();
    store.accept_transfer(third).unwrap();
    store.append_chunk(third, 0, &data[..1000], &conversation).unwrap();
    let beside = store.finish_transfer(third, &digest_other, &conversation).unwrap();
    assert_eq!(beside.file_name().unwrap(), "-Site photos (2).pdf");
    assert_eq!(std::fs::read(&received).unwrap(), data, "the first file is untouched");
    let partial = scratch.state().join("received").join(".partial");
    assert_eq!(std::fs::read_dir(partial).unwrap().count(), 0, "no staging file is left behind");
}

#[test]
fn a_publish_interrupted_after_claiming_its_name_is_finished_at_the_next_start() {
    let scratch = Scratch::new("claim");
    let source = scratch.0.join("source.bin");
    let data = write_file(&source, 1000);
    let digest = file_digest(&source, u64::MAX).unwrap();
    let id = "abcdefabcdefabcdefabcdefabcdef01";
    let claimed = scratch.state().join("Downloads").join("Plan.pdf");
    {
        let mut store = Store::open(scratch.state()).unwrap();
        let mei = friend(&mut store, "Mei", 5);
        store.record_incoming_offer(id, &mei.conversation_id, "Plan.pdf", None, 1000, &digest, 0.0).unwrap();
        store.accept_transfer(id).unwrap();
        store.append_chunk(id, 0, &data, &mei.conversation_id).unwrap();
        store.flush_progress().unwrap();
        // Where a move without hard links stops between claiming the name and renaming the file over it.
        let conn = rusqlite::Connection::open(store.database_path()).unwrap();
        let text = claimed.to_string_lossy().into_owned();
        let sql = "UPDATE transfers SET publishing = 1, final_path = ?1 WHERE transfer_id = ?2";
        conn.execute(sql, rusqlite::params![text, id]).unwrap();
        std::fs::create_dir_all(claimed.parent().unwrap()).unwrap();
        std::fs::write(&claimed, b"").unwrap();
    }
    let store = Store::open(scratch.state()).unwrap();
    let record = store.transfer(id).unwrap().unwrap();
    assert_eq!(record.state, TransferState::Received);
    assert_eq!(record.received_path.as_deref(), Some(claimed.as_path()), "published under the name it claimed");
    assert_eq!(std::fs::read(&claimed).unwrap(), data);
    let names = std::fs::read_dir(scratch.state().join("Downloads")).unwrap().count();
    assert_eq!(names, 1, "the file, no empty claim beside it");
}

#[test]
fn deleting_history_takes_a_chat_or_every_chat_and_what_was_still_to_send() {
    let scratch = Scratch::new("history");
    let mut store = Store::open(scratch.state()).unwrap();
    let (mei, leo) = (friend(&mut store, "Mei", 3), friend(&mut store, "Leo", 4));
    for (person, id) in [(&mei, "m-1"), (&mei, "m-2"), (&leo, "l-1")] {
        store.insert_item(&message(&person.conversation_id, id, Direction::Incoming)).unwrap();
    }
    let source = scratch.0.join("Plan.pdf");
    write_file(&source, 10_000);
    let record = store.stage_outgoing_file(&source, None, &mei.conversation_id).unwrap();
    let staged = record.staged_path.clone().expect("a snapshot to send");
    store.enqueue(&entry(&mei.conversation_id, "e-offer", OutboxKind::Offer, Some(&record.transfer_id)), None).unwrap();
    // A request carries no item: it is not history, and stays queued.
    store.enqueue(&entry(&mei.conversation_id, "e-request", OutboxKind::Request, None), None).unwrap();
    let count = |store: &Store, sql: &str| -> i64 { store.connection().query_row(sql, [], |r| r.get(0)).unwrap() };

    sync_history::delete_history(store.connection(), store.state_dir(), Some(&mei.conversation_id)).unwrap();
    assert_eq!(count(&store, "SELECT count(*) FROM messages"), 1, "only Leo's message is left");
    assert!(store.transfer(&record.transfer_id).unwrap().is_none(), "the transfer went");
    assert!(!staged.exists() && source.exists(), "its snapshot went; the person's own file stays");
    assert_eq!(count(&store, "SELECT count(*) FROM outbox"), 1, "the offer went, the request stays");

    sync_history::delete_history(store.connection(), store.state_dir(), None).unwrap();
    assert_eq!(count(&store, "SELECT count(*) FROM messages"), 0, "every chat");
    assert_eq!(count(&store, "SELECT count(*) FROM friends WHERE relation = 2"), 2, "friends stay");
    let refused = sync_history::delete_history(store.connection(), store.state_dir(), Some("../x"));
    assert!(refused.is_err());
}

//! Get again (ADR 0016) in the core: the AGAIN messages, the sender's rules (another person's file, one not delivered,
//! a changed, deleted or unchanged source, the limits, "not now" while another of its computers holds it) and the
//! asking side (a copy resumed on a later session, a digest that does not match).

mod sync_support;

use std::io::Write;
use std::time::{Duration, SystemTime};

use sync_support::{identity, Device};
use szfriends_core::presentation::AgainState;
use szfriends_core::store::sync_files::{self, SyncFile};
use szfriends_core::store::{Person, Relation, TransferRecord};
use szfriends_core::sync::again::{NONE_GONE, NONE_NOT_NOW};
use szfriends_core::sync::{again_state, set_again_state, AgainMessage, AgainRequester, AgainServer};

const PART: u64 = 48 * 1024;

fn friend(device: &mut Device, name: &str, relation: Relation) -> String {
    let mut person = Person::new(relation);
    person.identity_key = Some(identity(name).public_key());
    person.static_key = Some(identity(name).static_public_key());
    person.name = Some(name.into());
    device.store.save_person(&person).unwrap();
    device.store.person_with_identity_key(&identity(name).public_key()).unwrap().unwrap().conversation_id
}

/// A file of `size` bytes sent to `conversation` and delivered: its snapshot is gone, its source stays.
fn delivered(device: &mut Device, conversation: &str, name: &str, size: usize) -> TransferRecord {
    let source = device.home.join(name);
    let bytes: Vec<u8> = (0..size).map(|i| (i * 7 % 251) as u8).collect();
    std::fs::write(&source, bytes).unwrap();
    let record = device.store.stage_outgoing_file(&source, None, conversation).unwrap();
    let conn = device.store.connection();
    conn.execute("UPDATE transfers SET state = 5 WHERE transfer_id = ?1", [&record.transfer_id]).unwrap();
    std::fs::remove_file(record.staged_path.as_ref().unwrap()).unwrap();
    device.store.transfer(&record.transfer_id).unwrap().unwrap()
}

fn want(id: &str, offset: u64, parts: u16) -> AgainMessage {
    AgainMessage::Want { id: id.into(), offset, parts }
}

fn none(id: &str, reason: u8) -> Vec<AgainMessage> {
    vec![AgainMessage::None { id: id.into(), reason }]
}

fn nobody(_: &[u8; 32]) -> bool {
    false
}

#[test]
fn messages_encode_as_adr_0016_says() {
    let id = "00112233445566778899aabbccddeeff";
    let wanted = want(id, 0x0102, 8).encode().unwrap();
    assert_eq!(hex::encode(&wanted), format!("01{id}00000000000001020008"));
    let part = AgainMessage::Part { id: id.into(), offset: 5, last: true, bytes: b"abc".to_vec() };
    assert_eq!(hex::encode(part.encode().unwrap()), format!("02{id}000000000000000501616263"));
    let nothing = AgainMessage::None { id: id.into(), reason: 1 };
    assert_eq!(hex::encode(nothing.encode().unwrap()), format!("03{id}01"));
    for message in [want(id, 0x0102, 8), part, nothing] {
        assert_eq!(AgainMessage::decode(&message.encode().unwrap()), Some(message));
    }
    let full = AgainMessage::Part { id: id.into(), offset: 0, last: false, bytes: vec![1; PART as usize] };
    assert!(AgainMessage::decode(&full.encode().unwrap()).is_some(), "48 KiB fits");
    let mut over = full.encode().unwrap();
    over.push(0);
    assert_eq!(AgainMessage::decode(&over), None, "one byte over");
    assert_eq!(AgainMessage::decode(&wanted[..wanted.len() - 1]), None, "a short WANT");
    assert_eq!(AgainMessage::decode(&[4; 18]), None, "an unknown kind");
    assert_eq!(want("T_UPPER", 0, 1).encode(), None, "only an offer id travels");
}

#[test]
fn the_sender_gives_only_a_delivered_file_it_still_has_unchanged() {
    let mut raph = Device::new("raph");
    let mei = friend(&mut raph, "mei", Relation::Friend);
    let leo = friend(&mut raph, "leo", Relation::Friend);
    let mut server = AgainServer::new();
    let file = delivered(&mut raph, &mei, "Plan.pdf", 100_000);
    let id = file.transfer_id.as_str();
    // From the file it was sent from, unchanged: the parts asked for, at most 16.
    let parts = server.answer(&raph.store, &mei, &want(id, 0, 8), 0.0, &nobody);
    assert_eq!(parts.len(), 3, "100,000 bytes are three parts");
    assert!(matches!(&parts[2], AgainMessage::Part { last: true, offset, bytes, .. }
        if *offset == 2 * PART && bytes.len() == 100_000 - 2 * PART as usize));
    // Another person's file, an unknown id and a file not delivered are all "doesn't have it".
    assert_eq!(server.answer(&raph.store, &leo, &want(id, 0, 8), 1.0, &nobody), none(id, NONE_GONE));
    let unknown = "0123456789abcdef0123456789abcdef";
    assert_eq!(server.answer(&raph.store, &mei, &want(unknown, 0, 8), 1.0, &nobody), none(unknown, NONE_GONE));
    let source = raph.home.join("Queued.pdf");
    std::fs::write(&source, b"queued").unwrap();
    let queued = raph.store.stage_outgoing_file(&source, None, &mei).unwrap();
    let asked = want(&queued.transfer_id, 0, 1);
    assert_eq!(server.answer(&raph.store, &mei, &asked, 1.0, &nobody), none(&queued.transfer_id, NONE_GONE));
    // Someone who is not a friend now.
    let mut removed = raph.store.person_with_conversation(&mei).unwrap().unwrap();
    removed.relation = Relation::Removed;
    raph.store.save_person(&removed).unwrap();
    assert_eq!(server.answer(&raph.store, &mei, &want(id, 0, 8), 1.0, &nobody), none(id, NONE_GONE));
    removed.relation = Relation::Friend;
    raph.store.save_person(&removed).unwrap();
    // The person edits the file it was sent from: a file it does not have.
    let path = file.source_path.clone().unwrap();
    let mut handle = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
    handle.write_all(b"!").unwrap();
    handle.set_modified(SystemTime::now() + Duration::from_secs(5)).unwrap();
    drop(handle);
    assert_eq!(server.answer(&raph.store, &mei, &want(id, 0, 8), 2.0, &nobody), none(id, NONE_GONE));
    // Deleted: gone, unless another of its computers holds it, when the friend waits for that one.
    std::fs::remove_file(&path).unwrap();
    assert_eq!(server.answer(&raph.store, &mei, &want(id, 0, 8), 3.0, &nobody), none(id, NONE_GONE));
    let holder = identity("mac mini").public_key();
    let record = SyncFile {
        transfer_id: id.into(),
        conversation_id: mei.clone(),
        item_id: None,
        outgoing: true,
        state: 5,
        file_name: "Plan.pdf".into(),
        uniform_type: None,
        size: file.size,
        digest: file.digest.to_vec(),
        created_at: 1.0,
        holders: vec![holder],
    };
    sync_files::save_sync_file(raph.store.connection(), &record).unwrap();
    let ours = |key: &[u8; 32]| *key == holder;
    assert_eq!(server.answer(&raph.store, &mei, &want(id, 0, 8), 4.0, &ours), none(id, NONE_NOT_NOW));
}

#[test]
fn the_sender_copies_one_file_at_a_time_and_checks_digests_at_most_20_times_an_hour() {
    let mut raph = Device::new("raph");
    let mei = friend(&mut raph, "mei", Relation::Friend);
    let mut server = AgainServer::new();
    let big = delivered(&mut raph, &mei, "Big.pdf", 20 * PART as usize);
    let small = delivered(&mut raph, &mei, "Small.pdf", 10);
    let (b, s) = (big.transfer_id.as_str(), small.transfer_id.as_str());
    let first = server.answer(&raph.store, &mei, &want(b, 0, 100), 0.0, &nobody);
    assert_eq!(first.len(), 16, "at most 16 parts per WANT");
    assert_eq!(server.answer(&raph.store, &mei, &want(s, 0, 1), 30.0, &nobody), none(s, NONE_NOT_NOW));
    assert_eq!(server.answer(&raph.store, &mei, &want(s, 0, 1), 61.0, &nobody).len(), 1, "a minute later");
    // Twenty files checked within the hour; the 21st waits, a file checked already does not count.
    let mut server = AgainServer::new();
    let files: Vec<TransferRecord> = (0..21).map(|n| delivered(&mut raph, &mei, &format!("f{n}.pdf"), 5)).collect();
    for (n, file) in files.iter().take(20).enumerate() {
        let answer = server.answer(&raph.store, &mei, &want(&file.transfer_id, 0, 1), n as f64, &nobody);
        assert!(matches!(answer[..], [AgainMessage::Part { last: true, .. }]), "{n}");
    }
    let last = &files[20].transfer_id;
    assert_eq!(server.answer(&raph.store, &mei, &want(last, 0, 1), 30.0, &nobody), none(last, NONE_NOT_NOW));
    let again = server.answer(&raph.store, &mei, &want(&files[0].transfer_id, 0, 1), 31.0, &nobody);
    assert_eq!(again.len(), 1, "checked once, not again");
    assert_eq!(server.answer(&raph.store, &mei, &want(last, 0, 1), 3601.0, &nobody).len(), 1, "an hour on");
}

/// Mei's computer knows the file Raph sent from its record only (another computer of hers received it).
fn asked_on(mei: &mut Device, raph: &str, file: &TransferRecord, digest: Vec<u8>) {
    let record = SyncFile {
        transfer_id: file.transfer_id.clone(),
        conversation_id: raph.into(),
        item_id: None,
        outgoing: false,
        state: 6,
        file_name: file.file_name.clone(),
        uniform_type: None,
        size: file.size,
        digest,
        created_at: 1.0,
        holders: Vec::new(),
    };
    sync_files::save_sync_file(mei.store.connection(), &record).unwrap();
    set_again_state(&mei.store, &file.transfer_id, AgainState::Asked).unwrap();
}

/// Carries `rounds` round trips between Mei's requester and Raph's server.
fn run(mei: &mut Device, requester: &mut AgainRequester, raph: &Device, server: &mut AgainServer, rounds: usize) {
    let conversation = raph.store.person_with_identity_key(&identity("mei").public_key()).unwrap().unwrap();
    for _ in 0..rounds {
        let wants = requester.take_messages();
        for message in wants.iter().filter_map(|m| AgainMessage::decode(m)) {
            let answers = server.answer(&raph.store, &conversation.conversation_id, &message, 0.0, &nobody);
            for answer in answers {
                requester.receive(&mut mei.engine, &mei.store, &answer);
            }
        }
    }
}

#[test]
fn the_requester_resumes_on_a_later_session_and_publishes_a_whole_matching_file() {
    let mut raph = Device::new("raph");
    let mut mei = Device::new("mei");
    let to_mei = friend(&mut raph, "mei", Relation::Friend);
    let to_raph = friend(&mut mei, "raph", Relation::Friend);
    let mut server = AgainServer::new();
    let file = delivered(&mut raph, &to_mei, "Site photos.zip", 30 * PART as usize + 17);
    asked_on(&mut mei, &to_raph, &file, file.digest.to_vec());
    let mut first = AgainRequester::new(&to_raph);
    first.start_next(&mei.engine, &mei.store);
    run(&mut mei, &mut first, &raph, &mut server, 1);
    let partial = mei.engine.again_partial_path(&file.transfer_id);
    let held = std::fs::metadata(&partial).unwrap().len();
    assert!(held > 0 && held < file.size, "part of it: {held}");
    assert!(first.copying().is_some_and(|(id, f)| id == file.transfer_id && f > 0.0));
    // The session ends; the next one resumes from what is here.
    drop(first);
    let mut second = AgainRequester::new(&to_raph);
    second.start_next(&mei.engine, &mei.store);
    let resumed = second.take_messages();
    let AgainMessage::Want { offset, .. } = AgainMessage::decode(&resumed[0]).unwrap() else { panic!("a WANT") };
    assert_eq!(offset, held, "resumes from its length");
    for message in resumed.iter().filter_map(|m| AgainMessage::decode(m)) {
        for answer in server.answer(&raph.store, &to_mei, &message, 0.0, &nobody) {
            second.receive(&mut mei.engine, &mei.store, &answer);
        }
    }
    run(&mut mei, &mut second, &raph, &mut server, 10);
    assert!(second.copying().is_none() && !partial.exists());
    assert_eq!(again_state(&mei.store, &file.transfer_id), AgainState::None);
    let row = mei.store.transfer(&file.transfer_id).unwrap().expect("a row from the record");
    let published = mei.home.join(row.received_path.unwrap());
    assert_eq!(szfriends_core::store::file_digest(&published, u64::MAX).unwrap(), file.digest);
    assert!(mei.engine.local_path_of_file(&mei.store, &file.transfer_id).is_some(), "held here again");
}

#[test]
fn a_copy_whose_digest_does_not_match_is_gone_and_none_0_ends_the_request() {
    let mut raph = Device::new("raph");
    let mut mei = Device::new("mei");
    let to_mei = friend(&mut raph, "mei", Relation::Friend);
    let to_raph = friend(&mut mei, "raph", Relation::Friend);
    let mut server = AgainServer::new();
    let file = delivered(&mut raph, &to_mei, "Quote.pdf", 1000);
    asked_on(&mut mei, &to_raph, &file, vec![9; 32]);
    let mut requester = AgainRequester::new(&to_raph);
    requester.start_next(&mei.engine, &mei.store);
    run(&mut mei, &mut requester, &raph, &mut server, 3);
    assert_eq!(again_state(&mei.store, &file.transfer_id), AgainState::Gone);
    assert!(!mei.engine.again_partial_path(&file.transfer_id).exists());
    assert!(mei.store.transfer(&file.transfer_id).unwrap().is_none(), "nothing kept of it");
    // The friend no longer has another one: NONE 0, gone; NONE 1 leaves it asked.
    let other = delivered(&mut raph, &to_mei, "Other.pdf", 10);
    asked_on(&mut mei, &to_raph, &other, other.digest.to_vec());
    std::fs::remove_file(other.source_path.as_ref().unwrap()).unwrap();
    let mut requester = AgainRequester::new(&to_raph);
    requester.start_next(&mei.engine, &mei.store);
    let id = other.transfer_id.as_str();
    requester.receive(&mut mei.engine, &mei.store, &AgainMessage::None { id: id.into(), reason: NONE_NOT_NOW });
    assert_eq!(again_state(&mei.store, id), AgainState::Asked);
    assert!(requester.copying().is_none(), "not again on this session");
    let mut requester = AgainRequester::new(&to_raph);
    requester.start_next(&mei.engine, &mei.store);
    run(&mut mei, &mut requester, &raph, &mut server, 2);
    assert_eq!(again_state(&mei.store, id), AgainState::Gone);
}

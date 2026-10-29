//! ADR 0018 § 9.3: a store batch — files received together are recorded, checked and published under one commit,
//! each file's name claimed durably before it takes it, and acknowledged only once [`Store::end_batch`] returns it.

use std::path::PathBuf;

use szfriends_core::store::{file_digest, Person, Relation, Store, TransferState};

struct Scratch(PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn scratch() -> Scratch {
    let mut bytes = [0u8; 6];
    szfriends_core::crypto::random_bytes(&mut bytes);
    let suffix: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    let base = std::env::temp_dir().join(format!("szf-batch-{}-{suffix}", std::process::id()));
    std::fs::create_dir_all(&base).unwrap();
    Scratch(base)
}

#[test]
fn files_received_in_one_batch_are_published_when_it_ends() {
    let scratch = scratch();
    let mut store = Store::open(scratch.0.join("state")).unwrap();
    let mut person = Person::new(Relation::Friend);
    person.identity_key = Some([4; 32]);
    person.static_key = Some([5; 32]);
    store.save_person(&person).unwrap();
    let conversation = person.conversation_id.clone();
    let source = scratch.0.join("src.bin");
    let files: Vec<(String, &str, Vec<u8>)> = (0..3u8)
        .map(|i| {
            (format!("{:032x}", i + 1), if i == 2 { "a.txt" } else { ["a.txt", "b.txt"][i as usize] }, vec![i; 1000])
        })
        .collect();
    store.begin_batch().unwrap();
    for (id, name, data) in &files {
        std::fs::write(&source, data).unwrap();
        let digest = file_digest(&source, u64::MAX).unwrap();
        store.record_incoming_offer(id, &conversation, name, None, data.len() as u64, &digest, 0.0).unwrap();
        store.accept_transfer(id).unwrap();
        store.append_chunk(id, 0, data, &conversation).unwrap();
        let path = store.finish_transfer(id, &digest, &conversation).unwrap();
        assert!(path.as_os_str().is_empty(), "published when the batch ends, not before");
        assert_eq!(store.transfer(id).unwrap().unwrap().state, TransferState::Receiving);
    }
    let published = store.end_batch().unwrap();
    assert_eq!(published.len(), 3);
    let mut names: Vec<String> = published
        .iter()
        .map(|p| p.result.as_ref().unwrap().file_name().unwrap().to_string_lossy().into_owned())
        .collect();
    names.sort();
    assert_eq!(names, ["a (2).txt", "a.txt", "b.txt"], "two files of one name: the second takes the next name");
    for (id, _, data) in &files {
        let record = store.transfer(id).unwrap().unwrap();
        assert_eq!(record.state, TransferState::Received);
        assert_eq!(&std::fs::read(record.received_path.unwrap()).unwrap(), data);
    }
    assert!(!store.in_batch());
}

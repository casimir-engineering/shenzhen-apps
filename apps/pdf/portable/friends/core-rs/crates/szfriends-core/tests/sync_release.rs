//! ADR 0016 between Rust devices of one person (`SZFriendsSyncReleaseTests.m`): a device that no longer has a file's
//! bytes stops counting as one that holds them, on every device, whichever way its FILE HELD events reach them; what
//! the person moved or deleted never copies back by itself, and Get brings it back into the folder received files go
//! to; the device that sent a file holds it while the file it was sent from is unchanged.

mod sync_support;

use std::io::{Seek, SeekFrom, Write};
use std::path::Path;
use std::time::{Duration, SystemTime};

use sync_support::{identity, joined, sync, Device};
use szfriends_core::store::sync_files;
use szfriends_core::store::{Person, Relation, TransferRecord};
use szfriends_core::sync::AUTO_COPY_MAX;

fn holds(on: &Device, transfer_id: &str, holder: &Device) -> bool {
    let file = sync_files::sync_file(on.store.connection(), transfer_id).unwrap().expect("the file record");
    file.holders.contains(&holder.identity.public_key())
}

/// Mei, a friend, and a file of `size` bytes sent to her from `device`.
fn stage_file(device: &mut Device, name: &str, size: u64) -> TransferRecord {
    let mut mei = Person::new(Relation::Friend);
    mei.identity_key = Some(identity("mei").public_key());
    mei.static_key = Some(identity("mei").static_public_key());
    mei.name = Some("Mei".into());
    device.store.save_person(&mei).unwrap();
    let mei = device.store.person_with_identity_key(&identity("mei").public_key()).unwrap().unwrap();
    let source = device.home.join(name);
    let mut file = std::fs::File::create(&source).unwrap();
    file.write_all(&[7; 4096]).unwrap();
    file.set_len(size).unwrap();
    drop(file);
    device.store.stage_outgoing_file(&source, None, &mei.conversation_id).unwrap()
}

fn received_path(device: &Device, transfer_id: &str) -> Option<String> {
    sync_files::transfer(device.store.connection(), transfer_id).unwrap()?.received_path
}

#[test]
fn a_deleted_copy_is_released_everywhere_and_get_brings_it_back() {
    let mut devices = joined(&["alice", "bob", "carol"]);
    let mut c = devices.pop().unwrap();
    let mut b = devices.pop().unwrap();
    let mut a = devices.pop().unwrap();
    let file = stage_file(&mut a, "Plan.pdf", 20_000);
    let id = file.transfer_id.clone();
    sync(&mut a, &mut b).unwrap();
    let copy = received_path(&b, &id).expect("a small file copies");
    assert!(b.engine.local_path_of_file(&b.store, &id).is_some());
    sync(&mut a, &mut b).unwrap();
    assert!(holds(&a, &id, &b) && holds(&b, &id, &b), "b holds it, as a knows");

    // The person deletes it on b: b says it no longer holds it, and a hears so.
    std::fs::remove_file(&copy).unwrap();
    b.engine.capture_local_changes(&b.store);
    assert!(!holds(&b, &id, &b), "b no longer counts itself");
    sync(&mut a, &mut b).unwrap();
    assert!(!holds(&a, &id, &b) && holds(&a, &id, &a), "a hears b let it go");
    assert!(b.engine.files_wanted(&b.store).is_empty(), "what the person deleted does not copy back by itself");
    assert!(b.engine.local_path_of_file(&b.store, &id).is_none());
    // c hears b's held and released together: b is not listed there either.
    sync(&mut b, &mut c).unwrap();
    assert!(!holds(&c, &id, &b) && holds(&c, &id, &a), "c: only a holds it");

    // Get: copied again from a into the folder received files go to, and b holds it again everywhere.
    b.engine.request_file(&b.store, &id).unwrap();
    assert_eq!(b.engine.files_wanted(&b.store).len(), 1, "Get");
    sync(&mut a, &mut b).unwrap();
    let back = b.engine.local_path_of_file(&b.store, &id).expect("back after Get");
    assert!(!b.engine.is_file_requested(&b.store, &id));
    let row = received_path(&b, &id).unwrap();
    assert_eq!(b.home.join(&row), back, "the row points at the new copy");
    sync(&mut a, &mut b).unwrap();
    sync(&mut b, &mut c).unwrap();
    assert!(holds(&a, &id, &b) && holds(&c, &id, &b), "b holds it again, everywhere");
}

#[test]
fn the_sender_holds_a_file_while_the_one_it_was_sent_from_is_unchanged() {
    let mut devices = joined(&["alice", "bob"]);
    let mut b = devices.pop().unwrap();
    let mut a = devices.pop().unwrap();
    let file = stage_file(&mut a, "Site photos.zip", AUTO_COPY_MAX + 1);
    let id = file.transfer_id.clone();
    let source = file.source_path.clone().expect("where it was sent from is kept");
    assert_ne!(file.source_mtime_ns, 0);
    a.engine.capture_local_changes(&a.store);
    // Delivered: the snapshot goes, and the file it was sent from still holds the same bytes.
    std::fs::remove_file(file.staged_path.as_ref().unwrap()).unwrap();
    a.engine.capture_local_changes(&a.store);
    assert_eq!(a.engine.local_path_of_file(&a.store, &id).as_deref(), Some(source.as_path()));
    assert!(holds(&a, &id, &a), "held from where it was sent");
    // The person edits that file: a no longer has what it sent.
    edit(&source);
    a.engine.capture_local_changes(&a.store);
    assert!(a.engine.local_path_of_file(&a.store, &id).is_none(), "an edited file is not the file it sent");
    assert!(!holds(&a, &id, &a));
    sync(&mut a, &mut b).unwrap();
    let on_b = sync_files::sync_file(b.store.connection(), &id).unwrap().unwrap();
    assert!(on_b.holders.is_empty(), "b sees nobody holds it");
}

fn edit(path: &Path) {
    let mut handle = std::fs::OpenOptions::new().write(true).open(path).unwrap();
    handle.seek(SeekFrom::Start(10)).unwrap();
    handle.write_all(b"edited").unwrap();
    handle.set_modified(SystemTime::now() + Duration::from_secs(5)).unwrap();
}

/// Android 10 keeps a received file as a MediaStore item, which only the app's publisher reaches: held while the
/// publisher says it is there at its size, read through the copy it makes, and let go once it is gone.
#[test]
fn a_file_in_androids_downloads_is_held_through_the_publisher() {
    use std::sync::{Arc, Mutex};
    use szfriends_core::store::{ExternalPublisher, ReceivedDefaults};
    struct MediaStore(Mutex<Option<u64>>, std::path::PathBuf);
    impl ExternalPublisher for MediaStore {
        fn publish(&self, _staged: &Path, _name: &str) -> std::io::Result<(String, String)> {
            Err(std::io::Error::other("not here"))
        }
        fn size(&self, location: &str) -> Option<u64> {
            (location == "content://media/external/downloads/7").then(|| *self.0.lock().unwrap()).flatten()
        }
        fn copy_out(&self, _location: &str) -> Option<std::path::PathBuf> {
            Some(self.1.clone())
        }
    }
    let mut devices = joined(&["alice", "bob"]);
    let mut b = devices.pop().unwrap();
    let mut a = devices.pop().unwrap();
    let id = stage_file(&mut a, "Plan.pdf", 20_000).transfer_id;
    sync(&mut a, &mut b).unwrap();
    let copy = received_path(&b, &id).expect("a small file copies");
    let media = Arc::new(MediaStore(Mutex::new(Some(20_000)), Path::new(&copy).to_owned()));
    let defaults = ReceivedDefaults { external: Some(media.clone()), ..ReceivedDefaults::default() };
    b.store.set_received_defaults(defaults);
    let sql = "UPDATE transfers SET received_path = 'content://media/external/downloads/7' WHERE transfer_id = ?1";
    b.store.connection().execute(sql, [&id]).unwrap();
    assert_eq!(b.engine.local_path_of_file(&b.store, &id).as_deref(), Some(Path::new(&copy)), "read via its copy");
    b.engine.capture_local_changes(&b.store);
    assert!(holds(&b, &id, &b), "held while it is there");
    *media.0.lock().unwrap() = None;
    assert!(b.engine.local_path_of_file(&b.store, &id).is_none(), "gone");
    b.engine.capture_local_changes(&b.store);
    assert!(!holds(&b, &id, &b), "let go once the person deleted it");
}

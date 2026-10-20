//! Where received files are published (PROTOCOL.md § Views, `settings`, "The folder received files go to"): the
//! default Downloads, "Name (2).ext" on a clash, the folder the person chose and its checks, falling back when a
//! folder cannot take a file, an external publisher (Android's MediaStore), crash recovery, and the `received` view.
//! Every folder is a temporary one: nothing here reaches the person's own Downloads.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use szfriends_core::store::{
    file_digest, ExternalPublisher, FolderRefusal, Person, PhoneFolder, ReceivedDefaults, ReceivedFallback,
    ReceivedSource, Relation, SavedPlace, Store, StoreOptions, TransferState, RECEIVED_FALLBACK_FILE,
    RECEIVED_FOLDER_FILE,
};

struct Scratch(PathBuf);

impl Scratch {
    fn new(label: &str) -> Self {
        let mut bytes = [0u8; 6];
        szfriends_core::crypto::random_bytes(&mut bytes);
        let suffix: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        let base = std::env::temp_dir().join(format!("szf-folder-{label}-{}-{suffix}", std::process::id()));
        std::fs::create_dir_all(&base).unwrap();
        Self(std::fs::canonicalize(base).unwrap())
    }

    fn state(&self) -> PathBuf {
        self.0.join("state")
    }

    fn folder(&self, name: &str) -> PathBuf {
        let path = self.0.join(name);
        std::fs::create_dir_all(&path).unwrap();
        path
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn open(scratch: &Scratch, defaults: ReceivedDefaults) -> Store {
    let options = StoreOptions { received: Some(defaults), ..StoreOptions::default() };
    Store::open_with(scratch.state(), options).unwrap()
}

fn friend(store: &mut Store) -> String {
    let mut person = Person::new(Relation::Friend);
    person.name = Some("Mei".to_owned());
    person.identity_key = Some([5; 32]);
    person.static_key = Some([0xfa; 32]);
    store.save_person(&person).unwrap();
    person.conversation_id
}

fn new_id() -> String {
    let mut bytes = [0u8; 16];
    szfriends_core::crypto::random_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Receives `data` as `name` from the friend in `conversation`; the published path (or location).
fn receive(store: &mut Store, conversation: &str, name: &str, data: &[u8]) -> (String, PathBuf) {
    let id = new_id();
    let digest = digest_of(data);
    store.record_incoming_offer(&id, conversation, name, None, data.len() as u64, &digest, 0.0).unwrap();
    store.accept_transfer(&id).unwrap();
    if !data.is_empty() {
        store.append_chunk(&id, 0, data, conversation).unwrap();
    }
    let published = store.finish_transfer(&id, &digest, conversation).unwrap();
    assert_eq!(store.transfer(&id).unwrap().unwrap().state, TransferState::Received);
    (id, published)
}

fn digest_of(data: &[u8]) -> [u8; 32] {
    let scratch = std::env::temp_dir().join(format!("szf-digest-{}", new_id()));
    std::fs::write(&scratch, data).unwrap();
    let digest = file_digest(&scratch, u64::MAX).unwrap();
    std::fs::remove_file(scratch).unwrap();
    digest
}

fn staging_is_empty(scratch: &Scratch) -> bool {
    std::fs::read_dir(scratch.state().join("received").join(".partial")).map_or(true, |d| d.count() == 0)
}

#[test]
fn files_go_to_downloads_and_never_replace_one_another() {
    let scratch = Scratch::new("default");
    let downloads = scratch.0.join("Downloads");
    let mut store = open(&scratch, ReceivedDefaults::folder(downloads.clone()));
    let mei = friend(&mut store);
    let (first, path) = receive(&mut store, &mei, "Plan.pdf", b"first");
    assert_eq!(path, downloads.join("Plan.pdf"), "the default folder is made when missing");
    let (second, beside) = receive(&mut store, &mei, "Plan.pdf", b"second");
    assert_eq!(beside, downloads.join("Plan (2).pdf"));
    std::fs::write(downloads.join("Plan (3).pdf"), b"the person's own").unwrap();
    let (_, third) = receive(&mut store, &mei, "Plan.pdf", b"third");
    assert_eq!(third, downloads.join("Plan (4).pdf"));
    assert_eq!(std::fs::read(&path).unwrap(), b"first");
    assert_eq!(std::fs::read(downloads.join("Plan (3).pdf")).unwrap(), b"the person's own");
    assert!(staging_is_empty(&scratch), "nothing is left in staging");
    assert_eq!(store.received_folder(), Some(downloads.clone()));
    assert!(store.chosen_received_folder().is_none());

    let files = store.received_files();
    assert_eq!(files.len(), 3);
    let names: Vec<&str> = files.iter().map(|f| f.file_name.as_str()).collect();
    assert!(names.contains(&"Plan.pdf") && names.contains(&"Plan (2).pdf") && names.contains(&"Plan (4).pdf"));
    assert!(files.windows(2).all(|w| w[0].received_at >= w[1].received_at), "newest first");
    assert!(files.iter().all(|f| f.source == ReceivedSource::Friend));
    let listed = |id: &str| files.iter().find(|f| f.transfer_id == id).unwrap().path.clone();
    assert_eq!(listed(&second), beside.to_string_lossy());
    // A file the person deleted is not listed any more.
    std::fs::remove_file(&path).unwrap();
    assert!(store.received_files().iter().all(|f| f.transfer_id != first));
}

#[test]
fn the_folder_the_person_chooses_is_checked_kept_and_used() {
    let scratch = Scratch::new("chosen");
    let downloads = scratch.folder("Downloads");
    let chosen = scratch.folder("From friends");
    let mut store = open(&scratch, ReceivedDefaults::folder(downloads.clone()));
    let mei = friend(&mut store);

    assert_eq!(store.set_received_folder("relative/folder"), Err(FolderRefusal::NotAbsolute));
    assert_eq!(store.set_received_folder(""), Err(FolderRefusal::NotAbsolute));
    let missing = scratch.0.join("nowhere");
    assert_eq!(store.set_received_folder(&missing.to_string_lossy()), Err(FolderRefusal::Missing));
    let file = scratch.0.join("a file");
    std::fs::write(&file, b"x").unwrap();
    assert_eq!(store.set_received_folder(&file.to_string_lossy()), Err(FolderRefusal::NotAllowed));
    let inside = scratch.state().join("received");
    std::fs::create_dir_all(&inside).unwrap();
    assert_eq!(store.set_received_folder(&inside.to_string_lossy()), Err(FolderRefusal::NotAllowed));
    assert_eq!(store.set_received_folder(&scratch.state().to_string_lossy()), Err(FolderRefusal::NotAllowed));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let locked = scratch.folder("locked");
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o500)).unwrap();
        let refused = store.set_received_folder(&locked.to_string_lossy());
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o700)).unwrap();
        if !rustix_is_root() {
            assert_eq!(refused, Err(FolderRefusal::NotAllowed), "a folder that cannot be written");
        }
    }
    assert!(std::fs::read_dir(&chosen).unwrap().next().is_none(), "checking leaves nothing behind");

    // Through a link and with a trailing separator: the real path is what is kept.
    #[cfg(unix)]
    let given = {
        let link = scratch.0.join("link to folder");
        std::os::unix::fs::symlink(&chosen, &link).unwrap();
        format!("{}/", link.to_string_lossy())
    };
    #[cfg(not(unix))]
    let given = chosen.to_string_lossy().into_owned();
    store.set_received_folder(&given).unwrap();
    let kept = std::fs::read_to_string(scratch.state().join(RECEIVED_FOLDER_FILE)).unwrap();
    assert_eq!(Path::new(&kept), chosen.as_path());
    assert_eq!(store.chosen_received_folder(), Some(chosen.clone()));
    assert_eq!(store.received_folder(), Some(chosen.clone()));
    let (_, path) = receive(&mut store, &mei, "Bracket.step", b"solid");
    assert_eq!(path, chosen.join("Bracket.step"));
    assert_eq!(store.saved_place(&path), Some(SavedPlace::Folder("From friends".into())));
    assert_eq!(store.received_fallback(), None);

    // Kept across a restart.
    drop(store);
    let mut store = open(&scratch, ReceivedDefaults::folder(downloads.clone()));
    assert_eq!(store.chosen_received_folder(), Some(chosen.clone()));

    // A chosen folder that went away: Downloads takes the file, and that is remembered across a restart.
    std::fs::rename(&chosen, scratch.0.join("moved away")).unwrap();
    let (_, path) = receive(&mut store, &mei, "Bracket.step", b"solid");
    assert_eq!(path, downloads.join("Bracket.step"));
    assert_eq!(store.saved_place(&path), Some(SavedPlace::Downloads));
    assert_eq!(store.received_fallback(), Some(ReceivedFallback::Downloads));
    drop(store);
    let mut store = open(&scratch, ReceivedDefaults::folder(downloads.clone()));
    assert_eq!(store.received_fallback(), Some(ReceivedFallback::Downloads));

    // Back again: the next file saved there clears it.
    std::fs::rename(scratch.0.join("moved away"), &chosen).unwrap();
    let (_, path) = receive(&mut store, &mei, "Bracket.step", b"solid");
    assert_eq!(path, chosen.join("Bracket (2).step"));
    assert_eq!(store.received_fallback(), None);
    assert!(!scratch.state().join(RECEIVED_FALLBACK_FILE).exists());

    // Read-only (as a refusal by the system would be): Downloads again.
    #[cfg(unix)]
    if !rustix_is_root() {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&chosen, std::fs::Permissions::from_mode(0o500)).unwrap();
        let (_, path) = receive(&mut store, &mei, "Bracket.step", b"solid");
        std::fs::set_permissions(&chosen, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(path, downloads.join("Bracket (2).step"));
        assert_eq!(store.received_fallback(), Some(ReceivedFallback::Downloads));
    }
    std::fs::remove_dir_all(&chosen).unwrap();
    let _ = receive(&mut store, &mei, "Bracket.step", b"solid");
    assert_eq!(store.received_fallback(), Some(ReceivedFallback::Downloads));

    // Choosing Downloads again clears the choice, and what happened to the last file with it.
    store.set_received_folder(&downloads.to_string_lossy()).unwrap();
    assert!(!scratch.state().join(RECEIVED_FOLDER_FILE).exists());
    assert_eq!(store.received_folder(), Some(downloads));
    assert_eq!(store.received_fallback(), None);
}

#[cfg(unix)]
fn rustix_is_root() -> bool {
    std::fs::metadata("/").is_ok_and(|_| std::env::var("USER").as_deref() == Ok("root"))
}

#[test]
fn a_file_is_never_lost_when_no_folder_takes_it() {
    let scratch = Scratch::new("fallback");
    // The default "folder" is a file: it can be neither made nor written.
    let blocked = scratch.0.join("Downloads");
    std::fs::write(&blocked, b"not a folder").unwrap();
    let mut store = open(&scratch, ReceivedDefaults::folder(blocked.clone()));
    let mei = friend(&mut store);
    let (_, path) = receive(&mut store, &mei, "Plan.pdf", b"kept");
    assert_eq!(path, scratch.state().join("received").join("Plan.pdf"));
    assert_eq!(std::fs::read(&path).unwrap(), b"kept");
    assert_eq!(std::fs::read(&blocked).unwrap(), b"not a folder");
    assert_eq!(store.saved_place(&path), None, "its item keeps \"Received\"");
    assert_eq!(store.received_fallback(), Some(ReceivedFallback::Kept));
}

/// Copies into a folder of its own and answers a content URI, as the Android plugin does with MediaStore.
#[derive(Default)]
struct FakeMediaStore {
    folder: PathBuf,
    fail: bool,
    calls: Mutex<Vec<String>>,
}

impl ExternalPublisher for FakeMediaStore {
    fn publish(&self, staged: &Path, name: &str) -> std::io::Result<(String, String)> {
        self.calls.lock().unwrap().push(name.to_owned());
        if self.fail {
            return Err(std::io::Error::other("no MediaStore"));
        }
        std::fs::copy(staged, self.folder.join(name))?;
        Ok((format!("content://media/external/downloads/{}", self.calls.lock().unwrap().len()), name.to_owned()))
    }
}

#[test]
fn a_phone_publishes_through_its_platform_and_falls_back_to_its_own_folder() {
    let scratch = Scratch::new("external");
    let media = Arc::new(FakeMediaStore { folder: scratch.folder("media"), ..FakeMediaStore::default() });
    let defaults = ReceivedDefaults {
        folder: None,
        external: Some(media.clone() as Arc<dyn ExternalPublisher>),
        phone: Some(PhoneFolder::Downloads),
    };
    let mut store = open(&scratch, defaults);
    let mei = friend(&mut store);
    let (id, location) = receive(&mut store, &mei, "Photo.jpg", b"jpeg");
    assert_eq!(location, PathBuf::from("content://media/external/downloads/1"));
    assert_eq!(store.transfer(&id).unwrap().unwrap().received_path, Some(location.clone()));
    assert_eq!(std::fs::read(scratch.0.join("media/Photo.jpg")).unwrap(), b"jpeg");
    assert!(staging_is_empty(&scratch));
    let files = store.received_files();
    assert_eq!(
        (files[0].file_name.as_str(), files[0].path.as_str()),
        ("Photo.jpg", "content://media/external/downloads/1")
    );
    assert_eq!(store.received_folder(), None, "no folder to show");
    assert_eq!(store.saved_place(&location), Some(SavedPlace::Downloads));
    assert_eq!(store.received_fallback(), None);
    assert_eq!(store.set_received_folder(&scratch.0.to_string_lossy()), Err(FolderRefusal::NotAllowed));

    // Without MediaStore (an older Android): the app's own folder.
    let failing = Arc::new(FakeMediaStore { folder: scratch.folder("media"), fail: true, ..FakeMediaStore::default() });
    store.set_received_defaults(ReceivedDefaults {
        folder: None,
        external: Some(failing as Arc<dyn ExternalPublisher>),
        phone: Some(PhoneFolder::Downloads),
    });
    let (_, path) = receive(&mut store, &mei, "Photo.jpg", b"jpeg");
    assert_eq!(path, scratch.state().join("received").join("Photo.jpg"));
    assert_eq!(store.saved_place(&path), None);
    assert_eq!(store.received_fallback(), Some(ReceivedFallback::Kept));
}

#[test]
fn an_iphone_saves_in_the_apps_files() {
    let scratch = Scratch::new("ios");
    let documents = scratch.folder("Documents");
    let defaults =
        ReceivedDefaults { folder: Some(documents.clone()), external: None, phone: Some(PhoneFolder::AppFiles) };
    let mut store = open(&scratch, defaults);
    let mei = friend(&mut store);
    let (_, path) = receive(&mut store, &mei, "Model.stl", b"solid");
    assert_eq!(path, documents.join("Model.stl"));
    assert_eq!(store.saved_place(&path), Some(SavedPlace::AppFiles));
    assert_eq!(store.received_fallback(), None);
}

/// Sets a transfer that is fully staged as the crash left it: publishing, with `final_path` recorded.
fn staged_and_claimed(scratch: &Scratch, data: &[u8], final_path: &Path) -> (String, String) {
    let id = new_id();
    let digest = digest_of(data);
    let mut store = open(scratch, ReceivedDefaults::folder(scratch.0.join("Downloads")));
    let mei = friend(&mut store);
    store.record_incoming_offer(&id, &mei, "Plan.pdf", None, data.len() as u64, &digest, 0.0).unwrap();
    store.accept_transfer(&id).unwrap();
    store.append_chunk(&id, 0, data, &mei).unwrap();
    store.flush_progress().unwrap();
    let conn = rusqlite::Connection::open(store.database_path()).unwrap();
    let sql = "UPDATE transfers SET publishing = 1, final_path = ?1 WHERE transfer_id = ?2";
    conn.execute(sql, rusqlite::params![final_path.to_string_lossy(), id]).unwrap();
    (id, mei)
}

#[test]
fn a_copy_to_another_volume_cut_short_is_made_again_at_the_next_start() {
    let scratch = Scratch::new("part");
    let downloads = scratch.folder("Downloads");
    let destination = downloads.join("Plan.pdf");
    let (id, _) = staged_and_claimed(&scratch, b"whole file", &destination);
    let part = downloads.join(".Plan.pdf.part");
    std::fs::write(&part, b"whole").unwrap();
    let store = open(&scratch, ReceivedDefaults::folder(downloads.clone()));
    let record = store.transfer(&id).unwrap().unwrap();
    assert_eq!(record.state, TransferState::Received);
    assert_eq!(record.received_path.as_deref(), Some(destination.as_path()));
    assert_eq!(std::fs::read(&destination).unwrap(), b"whole file");
    assert!(!part.exists(), "the half copy is gone");
    assert!(staging_is_empty(&scratch));
}

#[test]
fn a_copy_finished_before_a_crash_is_kept_and_not_published_twice() {
    let scratch = Scratch::new("copied");
    let downloads = scratch.folder("Downloads");
    let destination = downloads.join("Plan.pdf");
    let (id, _) = staged_and_claimed(&scratch, b"whole file", &destination);
    std::fs::write(&destination, b"whole file").unwrap();
    let store = open(&scratch, ReceivedDefaults::folder(downloads.clone()));
    let record = store.transfer(&id).unwrap().unwrap();
    assert_eq!(record.received_path.as_deref(), Some(destination.as_path()));
    assert_eq!(std::fs::read_dir(&downloads).unwrap().count(), 1, "no Plan (2).pdf");
    assert!(staging_is_empty(&scratch));
}

#[test]
fn a_store_without_a_platform_keeps_files_inside_its_own_directory() {
    let scratch = Scratch::new("contained");
    if std::env::var_os(szfriends_core::store::ENV_DOWNLOADS_DIR).is_some() {
        return;
    }
    let mut store = Store::open(scratch.state()).unwrap();
    let mei = friend(&mut store);
    let (_, path) = receive(&mut store, &mei, "Plan.pdf", b"x");
    assert_eq!(path, scratch.state().join("Downloads").join("Plan.pdf"));
}

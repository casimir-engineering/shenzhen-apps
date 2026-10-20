//! The phones' key stores, a restored store's Start again, and the foreground lifecycle, on any computer: the
//! Keystore and the Keychain are replaced by fakes that behave as the plugin's Kotlin and Swift halves do.

use std::collections::HashMap;
use std::fs;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::channel;
use std::sync::Mutex;

use serde_json::{json, Value};
use szfriends_contract::framing::encode;
use szfriends_contract::handshake::HelperFacts;
use szfriends_contract::lifecycle::PROTOCOL;
use szfriends_helper::client::{AppInfo, ClientConnection};
use szfriends_helper::server::Server;
use szfriends_helper::transport::{memory_pair, PeerInfo};
use szfriends_identity::keystore::{MemoryKeyStore, IDENTITY_SECRET_NAME};
use zeroize::Zeroizing;

use super::keys::{Keychain, KeychainKeyStore, SealedFileKeyStore, Sealer, Unsealed};
use super::*;

struct TempDir(PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        let mut random = [0u8; 8];
        szfriends_crypto::random_bytes(&mut random);
        let name = format!("szf-phone-{label}-{}", random.iter().map(|b| format!("{b:02x}")).collect::<String>());
        let path = std::env::temp_dir().join(name);
        fs::create_dir_all(&path).expect("a temporary directory");
        Self(fs::canonicalize(path).expect("canonical"))
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// The Keystore: keys by alias; "sealing" XORs with the key and prefixes the alias, so a wrong key is caught.
#[derive(Default)]
struct FakeKeystore {
    keys: Mutex<HashMap<String, u8>>,
}

impl Sealer for FakeKeystore {
    fn seal(&self, alias: &str, secret: &[u8]) -> Result<Vec<u8>, String> {
        let mut keys = self.keys.lock().unwrap();
        let next = keys.len() as u8 + 0x41;
        let key = *keys.entry(alias.to_owned()).or_insert(next);
        Ok([alias.as_bytes(), b":", &secret.iter().map(|b| b ^ key).collect::<Vec<_>>()].concat())
    }

    fn unseal(&self, alias: &str, sealed: &[u8]) -> Result<Unsealed, String> {
        let Some(key) = self.keys.lock().unwrap().get(alias).copied() else { return Ok(Unsealed::KeyGone) };
        let body = sealed.strip_prefix(format!("{alias}:").as_bytes()).ok_or("tag mismatch")?;
        Ok(Unsealed::Secret(Zeroizing::new(body.iter().map(|b| b ^ key).collect())))
    }

    fn forget(&self, alias: &str) -> Result<(), String> {
        self.keys.lock().unwrap().remove(alias);
        Ok(())
    }
}

#[test]
fn a_sealed_key_file_reads_back_never_replaces_and_reads_absent_once_its_keystore_key_is_gone() {
    let home = TempDir::new("sealed");
    let keystore = Arc::new(FakeKeystore::default());
    let store = SealedFileKeyStore::new(home.0.join("keys"), keystore.clone());
    assert_eq!(store.secret(IDENTITY_SECRET_NAME).unwrap(), None, "nothing yet");
    store.store(IDENTITY_SECRET_NAME, b"secret one").unwrap();
    let file = fs::read(home.0.join("keys/identity.sealed")).unwrap();
    assert!(!file.windows(10).any(|w| w == b"secret one"), "the file holds the sealed bytes only");
    assert_eq!(store.secret(IDENTITY_SECRET_NAME).unwrap().unwrap().as_slice(), b"secret one");
    assert_eq!(store.store(IDENTITY_SECRET_NAME, b"secret two"), Err(IdentityError::StoreFailed), "never replaced");
    assert_eq!(store.secret(IDENTITY_SECRET_NAME).unwrap().unwrap().as_slice(), b"secret one");

    // A file the Keystore no longer has a key for (copied from another phone) is no secret at all.
    keystore.keys.lock().unwrap().clear();
    assert_eq!(store.secret(IDENTITY_SECRET_NAME).unwrap(), None);
    store.store(IDENTITY_SECRET_NAME, b"secret three").expect("the dead file is taken back");
    assert_eq!(store.secret(IDENTITY_SECRET_NAME).unwrap().unwrap().as_slice(), b"secret three");

    // A file the key refuses is unavailable, never absent.
    fs::write(home.0.join("keys/identity.sealed"), b"tampered").unwrap();
    assert_eq!(store.secret(IDENTITY_SECRET_NAME), Err(IdentityError::Unavailable));
    store.delete(IDENTITY_SECRET_NAME).unwrap();
    assert!(!home.0.join("keys/identity.sealed").exists());
    assert!(keystore.keys.lock().unwrap().is_empty(), "the Keystore key goes with the file");
    assert_eq!(store.secret("../escape"), Err(IdentityError::Unavailable));
}

#[derive(Default)]
struct FakeKeychain {
    items: Mutex<HashMap<String, Vec<u8>>>,
    locked: AtomicBool,
}

impl Keychain for FakeKeychain {
    fn read(&self, account: &str) -> Result<Option<Zeroizing<Vec<u8>>>, String> {
        if self.locked.load(Ordering::SeqCst) {
            return Err("errSecInteractionNotAllowed".into());
        }
        Ok(self.items.lock().unwrap().get(account).map(|v| Zeroizing::new(v.clone())))
    }

    fn add(&self, account: &str, secret: &[u8]) -> Result<(), String> {
        let mut items = self.items.lock().unwrap();
        if items.contains_key(account) {
            return Err("errSecDuplicateItem".into());
        }
        items.insert(account.to_owned(), secret.to_vec());
        Ok(())
    }

    fn delete(&self, account: &str) -> Result<(), String> {
        self.items.lock().unwrap().remove(account);
        Ok(())
    }
}

#[test]
fn a_keychain_item_is_unavailable_while_locked_and_never_replaced() {
    let keychain = Arc::new(FakeKeychain::default());
    let store = KeychainKeyStore::new(keychain.clone());
    store.store(IDENTITY_SECRET_NAME, b"one").unwrap();
    assert!(keychain.items.lock().unwrap().contains_key("szfriends.identity"));
    assert_eq!(store.store(IDENTITY_SECRET_NAME, b"two"), Err(IdentityError::StoreFailed));
    keychain.locked.store(true, Ordering::SeqCst);
    assert_eq!(store.secret(IDENTITY_SECRET_NAME), Err(IdentityError::Unavailable));
    keychain.locked.store(false, Ordering::SeqCst);
    assert_eq!(store.secret(IDENTITY_SECRET_NAME).unwrap().unwrap().as_slice(), b"one");
}

/// Keys that survive restarts of the service, as the Keychain does.
fn shared_keys() -> (Arc<MemoryKeyStore>, Keys) {
    struct Shared(Arc<MemoryKeyStore>);
    impl KeyStore for Shared {
        fn secret(&self, name: &str) -> Result<Option<Zeroizing<Vec<u8>>>, IdentityError> {
            self.0.secret(name)
        }
        fn store(&self, name: &str, secret: &[u8]) -> Result<(), IdentityError> {
            self.0.store(name, secret)
        }
        fn delete(&self, name: &str) -> Result<(), IdentityError> {
            self.0.delete(name)
        }
    }
    let memory = Arc::new(MemoryKeyStore::default());
    let keys = memory.clone();
    (memory, Arc::new(move || Box::new(Shared(keys.clone())) as Box<dyn KeyStore>))
}

struct Client(ClientConnection);

impl Client {
    fn connect(service: &Arc<PhoneService>) -> (Server, Self) {
        let facts = HelperFacts { version: "1.0".into(), build_number: 1, protocol: PROTOCOL, pid: 1 };
        let server = Server::new(service.clone(), facts, channel().0, Box::new(|_, _| false));
        let (ours, theirs) = memory_pair();
        server.add(theirs, PeerInfo::default());
        let mut connection = ClientConnection::new(ours);
        let app = AppInfo {
            app_id: "com.example.phone".into(),
            app_name: "Phone Test".into(),
            app_version: "1.0".into(),
            toolkit: "tauri".into(),
            reveal_in: "Files".into(),
            capabilities: vec!["files.share".into()],
            open_formats: vec!["stl".into()],
            locale: "en".into(),
        };
        let answer = connection.hello(&app, None).unwrap();
        assert_eq!(answer["type"], "welcome", "{answer}");
        (server, Self(connection))
    }

    /// Sends one intent; the frames up to and including its reply.
    fn send(&mut self, id: &str, frame: Value) -> Vec<Value> {
        let mut frame = frame;
        frame["id"] = json!(id);
        self.0.stream().write_all(&encode(&frame).unwrap()).unwrap();
        let mut frames = Vec::new();
        while let Ok(Some(next)) = self.0.next_frame() {
            let done = next["type"] == "reply" && next["re"] == id;
            frames.push(next);
            if done {
                break;
            }
        }
        frames
    }
}

#[test]
fn a_store_without_its_key_offers_start_again_which_starts_afresh_and_keeps_received_files() {
    let home = TempDir::new("restored");
    let (memory, keys) = shared_keys();
    let first = PhoneService::start(home.0.clone(), keys.clone());
    assert_eq!(first.state(), "service");
    first.shutdown();
    drop(first);
    let recorded = Store::identity_of(&home.0).unwrap();

    // The key survives a restart: the same identity serves the same store.
    let again = PhoneService::start(home.0.clone(), keys.clone());
    assert_eq!(again.state(), "service");
    assert_eq!(Store::identity_of(&home.0).unwrap(), recorded);
    again.shutdown();
    drop(again);

    // Restored from a backup without the key.
    fs::create_dir_all(home.0.join("received")).unwrap();
    fs::write(home.0.join("received/Gearbox.step"), b"kept").unwrap();
    memory.delete(IDENTITY_SECRET_NAME).unwrap();
    let restored = PhoneService::start(home.0.clone(), keys.clone());
    assert_eq!(restored.state(), "restored");
    assert_eq!(memory.secret(IDENTITY_SECRET_NAME).unwrap(), None, "nothing was created");
    let (_server, mut client) = Client::connect(&restored);
    let frames = client.send("1", json!({"type": "subscribe", "view": "list"}));
    let list = &frames[0]["data"];
    assert_eq!(list["banner"]["kind"], "identity_unavailable");
    assert_eq!(list["banner"]["text"], restored::BANNER);
    assert_eq!(list["banner"]["action"]["label"], restored::START_AGAIN);
    assert_eq!(list["banner"]["action"]["action"], "reset_friends");
    assert!(list["name_prompt"].is_null() && list["empty"].is_null() && list["footer"].is_null());
    let refused = client.send("2", json!({"type": "send_message", "conversation_id": "c", "text": "hi"}));
    assert_eq!(refused.last().unwrap()["error"]["code"], "identity_unavailable");
    let unconfirmed = client.send("3", json!({"type": "reset_friends", "confirm": "yes"}));
    assert_eq!(unconfirmed.last().unwrap()["error"]["code"], "invalid_field");

    let started = client.send("4", json!({"type": "reset_friends", "confirm": "reset"}));
    assert_eq!(started.last().unwrap()["ok"], true, "{started:?}");
    let goodbye = client.0.next_frame().unwrap().unwrap();
    assert_eq!((goodbye["type"].as_str(), goodbye["reason"].as_str()), (Some("goodbye"), Some("reset")));
    assert_eq!(restored.state(), "service");
    assert_ne!(Store::identity_of(&home.0).unwrap(), recorded, "a new identity");
    assert!(memory.secret(IDENTITY_SECRET_NAME).unwrap().is_some());
    assert_eq!(fs::read(home.0.join("received/Gearbox.step")).unwrap(), b"kept");
    restored.shutdown();
}

#[test]
fn friends_pauses_only_after_the_grace_period_in_the_background() {
    let home = TempDir::new("lifecycle");
    let (_, keys) = shared_keys();
    let service = PhoneService::with_grace(
        home.0.clone(),
        keys,
        szfriends_core::store::ReceivedDefaults::contained(&home.0),
        Duration::from_millis(80),
    );
    service.suspended();
    std::thread::sleep(Duration::from_millis(20));
    service.resumed();
    std::thread::sleep(Duration::from_millis(150));
    assert!(!service.paused(), "back within the grace period: nothing paused");
    service.suspended();
    std::thread::sleep(Duration::from_millis(200));
    assert!(service.paused(), "the grace period ended in the background");
    service.resumed();
    assert!(!service.paused(), "resumed in the foreground");
    service.shutdown();
}

/// Copies where a test says, as the Kotlin side's MediaStore does: nothing here reaches a real Downloads.
struct FakeMediaStore(PathBuf);

impl szfriends_core::store::ExternalPublisher for FakeMediaStore {
    fn publish(&self, staged: &std::path::Path, name: &str) -> std::io::Result<(String, String)> {
        fs::copy(staged, self.0.join(name))?;
        Ok(("content://media/external/downloads/7".into(), name.into()))
    }
}

#[test]
fn received_files_go_to_downloads_on_android_and_to_the_files_app_on_ios() {
    use received::{defaults, Phone};
    use szfriends_core::store::PhoneFolder;
    let home = TempDir::new("received-defaults");
    let state = home.0.join("Friends");
    let media: Arc<dyn szfriends_core::store::ExternalPublisher> = Arc::new(FakeMediaStore(home.0.clone()));

    let android = defaults(Phone::Android(33), &state, false, None, Some(media.clone()));
    assert_eq!((android.folder.as_ref(), android.phone), (None, Some(PhoneFolder::Downloads)));
    assert!(android.external.is_some(), "MediaStore publishes");
    let android_10 = defaults(Phone::Android(29), &state, false, None, Some(media.clone()));
    assert_eq!(android_10.phone, Some(PhoneFolder::Downloads), "no permission needed from Android 10");
    let android_9 = defaults(Phone::Android(28), &state, false, None, Some(media.clone()));
    assert_eq!((android_9.folder, android_9.phone), (Some(state.join("received")), Some(PhoneFolder::App)));
    assert!(android_9.external.is_none(), "no storage permission is asked for");

    let container = PathBuf::from("/var/mobile/Containers/Data/Application/ABC");
    let ios = defaults(Phone::Ios, &state, false, Some(container.clone()), None);
    assert_eq!((ios.folder, ios.phone), (Some(container.join("Documents")), Some(PhoneFolder::AppFiles)));

    // A test home keeps received files inside itself, on either phone.
    for phone in [Phone::Android(33), Phone::Ios] {
        let test = defaults(phone, &state, true, Some(container.clone()), Some(media.clone()));
        assert_eq!(test.folder, Some(state.join("Downloads")));
        assert!(test.external.is_none() && test.phone.is_some());
    }
}

#[test]
fn a_phones_settings_say_where_received_files_go_and_offer_no_change() {
    use szfriends_core::store::{PhoneFolder, ReceivedDefaults};
    let home = TempDir::new("received-settings");
    let settings = |received: ReceivedDefaults, state: &std::path::Path| {
        let (_, keys) = shared_keys();
        let service = PhoneService::start_with(state.to_path_buf(), keys, received);
        let (_server, mut client) = Client::connect(&service);
        let frames = client.send("1", json!({"type": "subscribe", "view": "settings"}));
        let row = frames[0]["data"]["received"].clone();
        let refused = client.send("2", json!({"type": "set_received_folder", "path": home.0.to_string_lossy()}));
        let code = refused.last().unwrap()["error"]["code"].clone();
        service.shutdown();
        (row, code)
    };
    let documents = home.0.join("Documents");
    let ios = ReceivedDefaults { folder: Some(documents), external: None, phone: Some(PhoneFolder::AppFiles) };
    let (row, code) = settings(ios, &home.0.join("ios"));
    assert_eq!(row["label"], "Save received files to");
    assert_eq!(row["value"], "Phone Test", "the app's folder in Files");
    assert_eq!(row["note"], "In the Files app, under On My iPhone.");
    assert!(row["path"].is_null() && row["action"].is_null() && row["change"].is_null(), "{row}");
    assert_eq!(code, "not_allowed", "a phone's folder does not change");

    let media: Arc<dyn szfriends_core::store::ExternalPublisher> = Arc::new(FakeMediaStore(home.0.clone()));
    let android = ReceivedDefaults { folder: None, external: Some(media), phone: Some(PhoneFolder::Downloads) };
    let (row, _) = settings(android, &home.0.join("android"));
    assert_eq!((row["value"].as_str(), row["note"].as_str()), (Some("Downloads"), Some("")));
    assert!(row["path"].is_null() && row["action"].is_null() && row["change"].is_null(), "{row}");
}

//! The identity manager's rules over the memory and file stores. No test reaches a real keychain.

use std::sync::atomic::Ordering;

use szfriends_identity::keystore::{
    IdentityManager, IdentityState, KeyStore, MemoryKeyStore, StoreIdentity, IDENTITY_SECRET_NAME,
};
use szfriends_identity::{Identity, IdentityError};

#[test]
fn creates_once_then_loads_the_same_identity() {
    let manager = IdentityManager::new(MemoryKeyStore::default());
    let (first, state) = manager.load_or_create(StoreIdentity::NoStore).expect("created");
    assert_eq!(state, IdentityState::Created);
    let (again, state) = manager.load_or_create(StoreIdentity::NoStore).expect("loaded");
    assert_eq!(state, IdentityState::Ready);
    assert_eq!(first.public_key(), again.public_key());
}

#[test]
fn an_unreadable_or_damaged_secret_is_never_replaced() {
    let store = MemoryKeyStore::default();
    store.store(IDENTITY_SECRET_NAME, &[1, 2, 3]).expect("planted");
    assert_eq!(IdentityManager::new(store).load_or_create(StoreIdentity::NoStore).unwrap_err(), IdentityError::Corrupt);

    let store = MemoryKeyStore::default();
    store.store(IDENTITY_SECRET_NAME, &Identity::generate().secret_item()).expect("stored");
    store.locked.store(true, Ordering::SeqCst);
    let manager = IdentityManager::new(store);
    assert_eq!(
        manager.load_or_create(StoreIdentity::NoStore).unwrap_err(),
        IdentityError::Unavailable,
        "a locked store"
    );
    assert_eq!(
        manager.load_or_create(StoreIdentity::NoStore).unwrap_err(),
        IdentityError::Unavailable,
        "and still not replaced"
    );
}

#[test]
fn a_store_without_its_key_is_key_missing_never_a_new_identity() {
    // An iOS or Android backup restored on a new phone: the store came back, the device-only key did not.
    let manager = IdentityManager::new(MemoryKeyStore::default());
    let recorded = StoreIdentity::Recorded(Identity::generate().public_key());
    assert_eq!(manager.load_or_create(recorded).unwrap_err(), IdentityError::KeyMissing);
    assert_eq!(manager.load_or_create(recorded).unwrap_err(), IdentityError::KeyMissing, "and nothing was created");

    // Start again: the caller removes the store, then the manager makes a new identity.
    let new = manager.reset().expect("start again");
    let (loaded, state) = manager.load_or_create(StoreIdentity::NoStore).expect("loads");
    assert_eq!((loaded.public_key(), state), (new.public_key(), IdentityState::Ready));
}

#[test]
fn a_key_and_a_store_of_different_identities_are_never_mixed() {
    let manager = IdentityManager::new(MemoryKeyStore::default());
    let (mine, _) = manager.load_or_create(StoreIdentity::NoStore).expect("created");
    let (same, state) = manager.load_or_create(StoreIdentity::Recorded(mine.public_key())).expect("its own store");
    assert_eq!((same.public_key(), state), (mine.public_key(), IdentityState::Ready));
    let other = StoreIdentity::Recorded(Identity::generate().public_key());
    assert_eq!(manager.load_or_create(other).unwrap_err(), IdentityError::StoreMismatch);
}

#[test]
fn reset_makes_a_new_identity() {
    let manager = IdentityManager::new(MemoryKeyStore::default());
    let (old, _) = manager.load_or_create(StoreIdentity::NoStore).expect("created");
    let new = manager.reset().expect("reset");
    assert_ne!(old.public_key(), new.public_key());
    assert_eq!(manager.load_or_create(StoreIdentity::NoStore).expect("loads").0.public_key(), new.public_key());
}

#[cfg(unix)]
#[test]
fn file_store_refuses_what_is_not_ours() {
    use std::os::unix::fs::PermissionsExt;
    use szfriends_identity::keystore::FileKeyStore;

    let directory = std::env::temp_dir().join(format!("keys-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    let store = FileKeyStore::new(&directory);
    assert_eq!(store.secret("identity").expect("absent"), None);
    store.store("identity", b"secret").expect("stored");
    assert_eq!(store.store("identity", b"other").unwrap_err(), IdentityError::StoreFailed, "never replaces");
    assert_eq!(store.secret("identity").expect("read").expect("present").as_slice(), b"secret");
    let mode = std::fs::metadata(directory.join("identity")).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
    std::fs::set_permissions(directory.join("identity"), std::fs::Permissions::from_mode(0o644)).unwrap();
    assert_eq!(store.secret("identity").unwrap_err(), IdentityError::Unavailable, "readable by others");
    std::fs::remove_file(directory.join("identity")).unwrap();
    std::os::unix::fs::symlink("/etc/hosts", directory.join("identity")).unwrap();
    assert_eq!(store.secret("identity").unwrap_err(), IdentityError::Unavailable, "a symbolic link");
    store.delete("identity").expect("deleted");
    assert!(store.store("../escape", b"x").is_err() && store.store(".hidden", b"x").is_err());
    let _ = std::fs::remove_dir_all(&directory);
}

#[cfg(unix)]
#[test]
fn file_store_takes_back_the_empty_claim_of_an_interrupted_store() {
    use std::os::unix::fs::OpenOptionsExt;
    use szfriends_identity::keystore::FileKeyStore;

    let directory = std::env::temp_dir().join(format!("keys-claim-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    let store = FileKeyStore::new(&directory);
    store.store("other", b"x").expect("the directory exists");
    // What a store leaves when it stops after claiming the name, before the secret is moved in.
    std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(directory.join("identity")).unwrap();
    assert_eq!(store.secret("identity").expect("an empty claim is no secret"), None);
    store.store("identity", b"secret").expect("the claim is taken back");
    assert_eq!(store.secret("identity").expect("read").expect("present").as_slice(), b"secret");
    assert_eq!(store.store("identity", b"other").unwrap_err(), IdentityError::StoreFailed, "never replaces");
    let _ = std::fs::remove_dir_all(&directory);
}

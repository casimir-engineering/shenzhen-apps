//! For test harnesses only: two Friends homes made friends of each other, as an accepted request leaves them (keys
//! and presence secrets exchanged), so end-to-end tests can exchange messages and files without a request first.
//! Each home gets a key store of its own ([`test_key_store`]), never the person's.

use std::path::Path;

use szfriends_core::store::{Person, Relation, Store};
use szfriends_identity::keystore::{IdentityManager, KeyStore};
use szfriends_identity::Identity;

/// A home's own key store: 0600 files under it on Unix, DPAPI files under it on Windows.
pub fn test_key_store(home: &Path) -> Box<dyn KeyStore> {
    #[cfg(unix)]
    return Box::new(szfriends_identity::keystore::FileKeyStore::new(home.join("keys")));
    #[cfg(windows)]
    return Box::new(crate::windows::keystore::DpapiKeyStore::new(home.join("keys")));
}

fn open(home: &Path, name: &str) -> Result<(Identity, Store), String> {
    std::fs::create_dir_all(home).map_err(|e| e.to_string())?;
    let recorded = Store::identity_of(home).map_err(|e| e.to_string())?;
    let manager = IdentityManager::new(super::Keys(test_key_store(home)));
    let (identity, _) = manager.load_or_create(recorded).map_err(|e| format!("{e:?}"))?;
    let mut store = Store::open(home).map_err(|e| e.to_string())?;
    store.record_identity(&identity.public_key()).map_err(|e| e.to_string())?;
    store
        .connection()
        .execute("INSERT INTO profile (id, name) VALUES (1, ?1) ON CONFLICT(id) DO UPDATE SET name = ?1", [name])
        .map_err(|e| e.to_string())?;
    Ok((identity, store))
}

/// `secret` is the friend's own presence secret, which an accepted request hands over.
fn add(store: &mut Store, friend: &Identity, name: &str, secret: [u8; 32]) -> Result<String, String> {
    let mut person = match store.person_with_identity_key(&friend.public_key()) {
        Ok(Some(person)) => person,
        _ => Person::new(Relation::Friend),
    };
    person.relation = Relation::Friend;
    person.identity_key = Some(friend.public_key());
    person.static_key = Some(friend.static_public_key());
    person.name = Some(name.to_owned());
    // As an accepted request leaves them: each holds the other's presence secret, so they find each other nearby
    // and online.
    person.presence_secret = Some(secret);
    store.save_person(&person).map_err(|e| e.to_string())?;
    Ok(person.conversation_id)
}

/// Makes `a` (named `names.0`) and `b` (`names.1`) friends; the conversation ids, in each home.
pub fn befriend(a: &Path, b: &Path, names: (&str, &str)) -> Result<(String, String), String> {
    let (identity_a, mut store_a) = open(a, names.0)?;
    let (identity_b, mut store_b) = open(b, names.1)?;
    let secret_a = store_a.ensure_own_presence_secret().map_err(|e| e.to_string())?;
    let secret_b = store_b.ensure_own_presence_secret().map_err(|e| e.to_string())?;
    Ok((add(&mut store_a, &identity_b, names.1, secret_b)?, add(&mut store_b, &identity_a, names.0, secret_a)?))
}

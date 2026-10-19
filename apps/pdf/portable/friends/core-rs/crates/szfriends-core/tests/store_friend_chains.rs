//! A friend's device chain in the store (`SZFriendsStoreDevices.m`; ADR 0012): kept once it verifies from the root
//! we pinned, after which a lookup by any of the friend's authorized devices finds the friend, and a removed one finds
//! nobody; and an Add by ID answered by a friend's second computer moving to the person once their chain names it.

use std::path::PathBuf;

use szfriends_core::identity::chain::{device_consent, DeviceChain};
use szfriends_core::identity::Identity;
use szfriends_core::store::devices::{self, ChainMerge};
use szfriends_core::store::{Person, Relation, Store, StoreError};

fn identity(name: &str) -> Identity {
    let label = |l: String| szfriends_core::crypto::blake2b::<32>(None, &[l.as_bytes()]);
    let mut private = label(format!("{name} static"));
    private[0] &= 248;
    private[31] = (private[31] & 127) | 64;
    Identity::from_secrets(&label(format!("{name} seed")), &private)
}

struct Home(PathBuf, Option<Store>);

impl Home {
    fn new(name: &str) -> Self {
        let mut bytes = [0u8; 8];
        szfriends_core::crypto::random_bytes(&mut bytes);
        let path = std::env::temp_dir().join(format!("szf-friend-chain-{name}-{}", hex::encode(bytes)));
        let store = Store::open(&path).unwrap();
        Self(path, Some(store))
    }

    fn store(&mut self) -> &mut Store {
        self.1.as_mut().expect("open")
    }

    fn get(&self) -> &Store {
        self.1.as_ref().expect("open")
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        drop(self.1.take());
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Mei's chain: her Mac first, then her laptop.
fn mei_chain() -> (DeviceChain, Identity, Identity) {
    let (mac, laptop) = (identity("mei mac"), identity("mei laptop"));
    let genesis = DeviceChain::genesis(&mac, "Mei's Mac", "macOS", 1.0e9).unwrap();
    let consent = device_consent(&laptop, genesis.root_key());
    let (key, static_key) = (laptop.public_key(), laptop.static_public_key());
    let chain = genesis.adding(&key, &static_key, &consent, "Mei's laptop", "Ubuntu", &mac, 1.0e9 + 1.0).unwrap();
    (chain, mac, laptop)
}

fn friend(store: &mut Store, key: &Identity) -> Person {
    let mut mei = Person::new(Relation::Friend);
    mei.identity_key = Some(key.public_key());
    mei.static_key = Some(key.static_public_key());
    mei.name = Some("Mei".into());
    store.save_person(&mei).unwrap();
    mei
}

#[test]
fn a_friends_chain_lets_their_other_devices_find_them_and_a_removed_one_find_nobody() {
    let mut home = Home::new("ann");
    let (chain, mac, laptop) = mei_chain();
    let mei = friend(home.store(), &mac);
    assert!(home.get().person_with_identity_key(&laptop.public_key()).unwrap().is_none(), "no chain yet");
    let conn = home.get().connection();
    assert_eq!(devices::merge_friend_chain(conn, chain.encoded(), &mac.public_key()).unwrap(), ChainMerge::Changed);
    assert_eq!(devices::merge_friend_chain(conn, chain.encoded(), &mac.public_key()).unwrap(), ChainMerge::Unchanged);
    let found = home.get().person_with_identity_key(&laptop.public_key()).unwrap().expect("Mei, from her laptop");
    assert_eq!(found.conversation_id, mei.conversation_id);
    // A chain from another root is not Mei's.
    let stranger = DeviceChain::genesis(&identity("someone"), "PC", "Windows", 1.0e9).unwrap();
    assert!(devices::merge_friend_chain(conn, stranger.encoded(), &mac.public_key()).is_err());
    // Mei removes her laptop: it speaks for nobody from then on.
    let revoked = chain.revoking(&laptop.public_key(), &mac, 1.0e9 + 2.0).unwrap();
    let conn = home.get().connection();
    devices::merge_friend_chain(conn, revoked.encoded(), &mac.public_key()).unwrap();
    assert!(home.get().person_with_identity_key(&laptop.public_key()).unwrap().is_none());
    assert!(devices::is_revoked_device(home.get().connection(), &laptop.public_key()).unwrap());
}

#[test]
fn an_answer_from_a_second_computer_moves_to_the_person_once_its_chain_names_it() {
    let mut home = Home::new("bo");
    let (chain, mac, laptop) = mei_chain();
    // Bo's Add by ID was answered by Mei's laptop: the row names the laptop.
    let mut row = Person::new(Relation::OutgoingRequest);
    row.identity_key = Some(laptop.public_key());
    row.static_key = Some(laptop.static_public_key());
    home.store().save_person(&row).unwrap();
    let conn = home.get().connection();
    let other = DeviceChain::genesis(&identity("someone"), "PC", "Windows", 1.0e9).unwrap();
    assert!(matches!(
        devices::rekey_conversation(conn, &row.conversation_id, &laptop.public_key(), &other),
        Err(StoreError::Invalid(_))
    ));
    devices::rekey_conversation(conn, &row.conversation_id, &laptop.public_key(), &chain).unwrap();
    let moved = home.get().person_with_conversation(&row.conversation_id).unwrap().unwrap();
    assert_eq!(moved.identity_key, Some(mac.public_key()), "the person is her root");
    assert_eq!(moved.static_key, Some(mac.static_public_key()), "dialed at her first computer");
    let from_laptop = home.get().person_with_identity_key(&laptop.public_key()).unwrap().unwrap();
    assert_eq!(from_laptop.conversation_id, row.conversation_id);
    // Only once: the root is taken now.
    let conn = home.get().connection();
    assert!(devices::rekey_conversation(conn, &row.conversation_id, &laptop.public_key(), &chain).is_err());
}

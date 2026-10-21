//! Two Rust devices of one person in memory: a chain holding both, history and a friend synced each way, a deletion
//! reaching the other device, and a removal: the removed device's later events refused, and it learns it was removed.

mod sync_support;

use sync_support::{identity, joined_pair, sync};
use szfriends_core::store::devices;
use szfriends_core::store::{Person, Relation};

#[test]
fn history_and_friends_reach_the_other_device_both_ways() {
    let (mut a, mut b) = joined_pair();
    let mut carol = Person::new(Relation::Friend);
    carol.identity_key = Some(identity("carol").public_key());
    carol.static_key = Some(identity("carol").static_public_key());
    carol.name = Some("Carol".into());
    a.store.save_person(&carol).unwrap();
    a.message(&carol.conversation_id, "m1", "hello from carol", 1.0e9 + 1.0);
    sync(&mut a, &mut b).unwrap();
    let on_b = b.store.person_with_identity_key(&identity("carol").public_key()).unwrap().expect("carol on bob");
    assert_eq!(on_b.name.as_deref(), Some("Carol"));
    assert_eq!(b.texts(&on_b.conversation_id), ["hello from carol"]);
    b.message(&on_b.conversation_id, "m2", "second", 1.0e9 + 2.0);
    sync(&mut a, &mut b).unwrap();
    assert_eq!(a.texts(&carol.conversation_id), ["hello from carol", "second"]);
    // Erase on one, gone on both.
    a.engine.delete_history(&a.store, Some(&carol.conversation_id)).unwrap();
    assert!(a.texts(&carol.conversation_id).is_empty());
    sync(&mut a, &mut b).unwrap();
    assert!(b.texts(&on_b.conversation_id).is_empty());
    // A late copy stays erased.
    assert!(!b.message(&on_b.conversation_id, "m1", "hello again", 1.0e9 + 3.0));
    assert!(b.texts(&on_b.conversation_id).is_empty());
}

#[test]
fn a_removed_device_learns_it_and_its_later_events_count_for_nothing() {
    let (mut a, mut b) = joined_pair();
    let mut carol = Person::new(Relation::Friend);
    carol.identity_key = Some(identity("carol").public_key());
    a.store.save_person(&carol).unwrap();
    sync(&mut a, &mut b).unwrap();
    let chain = devices::own_chain(a.store.connection()).unwrap().unwrap();
    let revoked = chain.revoking(&b.identity.public_key(), &a.identity, 1.0e9 + 5.0).unwrap();
    devices::merge_own_chain(a.store.connection(), &revoked).unwrap();
    a.engine.record_revocation(&a.store, &b.identity.public_key()).unwrap();
    // Bob writes after its removal, before it heard of it.
    let on_b = b.store.person_with_identity_key(&identity("carol").public_key()).unwrap().unwrap();
    b.message(&on_b.conversation_id, "late", "written after removal", 1.0e9 + 6.0);
    let result = sync(&mut a, &mut b);
    assert!(a.texts(&carol.conversation_id).is_empty(), "nothing bob wrote after its removal: {result:?}");
    let own = devices::own_chain(b.store.connection()).unwrap().unwrap();
    assert!(own.revokes(&b.identity.public_key()), "bob holds the chain that removed it");
    assert!(b.engine.root_key(&b.store).is_none());
}

#[test]
fn taking_someone_off_the_list_reaches_the_other_device_and_a_new_request_brings_them_back() {
    let (mut a, mut b) = joined_pair();
    let mut carol = Person::new(Relation::Friend);
    carol.identity_key = Some(identity("carol").public_key());
    a.store.save_person(&carol).unwrap();
    sync(&mut a, &mut b).unwrap();
    // Removed and taken off the list on Alice's Mac.
    carol.relation = Relation::Removed;
    carol.left_list_at = Some(1.0e9 + 10.0);
    a.store.save_person(&carol).unwrap();
    sync(&mut a, &mut b).unwrap();
    let on_b = b.store.person_with_identity_key(&identity("carol").public_key()).unwrap().unwrap();
    assert_eq!((on_b.relation, on_b.left_list_at), (Relation::Removed, Some(1.0e9 + 10.0)));
    // Carol asks again, and Bob's PC hears it first: back on the list on both.
    let mut asking = on_b.clone();
    asking.relation = Relation::IncomingRequest;
    asking.request_at = Some(1.0e9 + 20.0);
    b.store.save_person(&asking).unwrap();
    assert_eq!(b.store.person_with_conversation(&on_b.conversation_id).unwrap().unwrap().left_list_at, None);
    sync(&mut a, &mut b).unwrap();
    let on_a = a.store.person_with_conversation(&carol.conversation_id).unwrap().unwrap();
    assert_eq!((on_a.relation, on_a.left_list_at), (Relation::IncomingRequest, None));
}

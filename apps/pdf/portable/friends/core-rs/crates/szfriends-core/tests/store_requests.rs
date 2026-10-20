//! Requests in the store (`SZFriendsStoreAddByIDTests.m`, `SZFriendsStoreRequestTests.m`): when a waiting request
//! began, Add by ID requests and who may answer them, requests lapsing, and the nearby settings.

use std::path::PathBuf;

use szfriends_core::store::requests::{INCOMING_REQUEST_LIFETIME_SECONDS, OUTGOING_REQUEST_LIFETIME_SECONDS};
use szfriends_core::store::{unix_now, IdRequest, Person, Relation, Store, StoreError, ID_REQUEST_MAX_PENDING};

struct Scratch(PathBuf);

impl Scratch {
    fn new(label: &str) -> Self {
        let mut bytes = [0u8; 6];
        szfriends_core::crypto::random_bytes(&mut bytes);
        let suffix: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        let base = std::env::temp_dir().join(format!("szf-requests-{label}-{}-{suffix}", std::process::id()));
        std::fs::create_dir_all(&base).unwrap();
        Self(base)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn open(scratch: &Scratch) -> Store {
    Store::open(scratch.0.join("state")).unwrap()
}

fn person(store: &mut Store, relation: Relation, key: u8, friends_id: Option<&str>) -> Person {
    let mut person = Person::new(relation);
    person.identity_key = Some([key; 32]);
    person.static_key = Some([key ^ 0xff; 32]);
    person.friends_id = friends_id.map(str::to_owned);
    store.save_person(&person).unwrap();
    store.person_with_conversation(&person.conversation_id).unwrap().unwrap()
}

#[test]
fn a_waiting_request_keeps_when_it_began() {
    let scratch = Scratch::new("since");
    let mut store = open(&scratch);
    let mut asker = Person::new(Relation::IncomingRequest);
    asker.identity_key = Some([1; 32]);
    asker.request_at = Some(1000.0);
    asker.request_found_nearby = true;
    store.save_person(&asker).unwrap();
    let read = store.person_with_conversation(&asker.conversation_id).unwrap().unwrap();
    assert_eq!(read.request_since, Some(1000.0));
    assert!(read.request_found_nearby);
    asker.request_at = Some(5000.0);
    store.save_person(&asker).unwrap();
    let again = store.person_with_conversation(&asker.conversation_id).unwrap().unwrap();
    assert_eq!(again.request_at, Some(5000.0), "the card shows the latest ask");
    assert_eq!(again.request_since, Some(1000.0), "asking again does not move the start");
    asker.relation = Relation::Friend;
    store.save_person(&asker).unwrap();
    assert_eq!(store.person_with_conversation(&asker.conversation_id).unwrap().unwrap().request_since, None);
    // A future ask starts now, never later.
    let mut future = Person::new(Relation::OutgoingRequest);
    future.request_at = Some(unix_now() + 3600.0);
    store.save_person(&future).unwrap();
    let since = store.person_with_conversation(&future.conversation_id).unwrap().unwrap().request_since.unwrap();
    assert!(since <= unix_now());
}

#[test]
fn unconfirmed_answers_live_only_on_incoming_requests() {
    let scratch = Scratch::new("unconfirmed");
    let mut store = open(&scratch);
    let mut answer = Person::new(Relation::IncomingRequest);
    answer.identity_key = Some([2; 32]);
    answer.unconfirmed_answer_id = Some("apple-banana".into());
    store.save_person(&answer).unwrap();
    let read = store.person_with_conversation(&answer.conversation_id).unwrap().unwrap();
    assert_eq!(read.unconfirmed_answer_id.as_deref(), Some("apple-banana"));
    answer.relation = Relation::Friend;
    store.save_person(&answer).unwrap();
    assert_eq!(store.person_with_conversation(&answer.conversation_id).unwrap().unwrap().unconfirmed_answer_id, None);
}

#[test]
fn add_by_id_rows_and_their_limit() {
    let scratch = Scratch::new("byid");
    let mut store = open(&scratch);
    let now = unix_now();
    let mut first = IdRequest::new("apple-banana", now);
    let row = store.start_id_request(&mut first).unwrap();
    assert_eq!(first.conversation_id, row);
    let person = store.person_with_conversation(&row).unwrap().unwrap();
    assert_eq!(person.relation, Relation::OutgoingRequest);
    assert_eq!(person.identity_key, None);
    assert_eq!(store.pending_id_requests(now).len(), 1);
    // Asking again for the same ID reuses the keyless row.
    let mut again = IdRequest::new("apple-banana", now + 1.0);
    assert_eq!(store.start_id_request(&mut again).unwrap(), row);
    assert_eq!(store.pending_id_requests(now + 1.0).len(), 1, "a new token replaces the old one");
    for i in 0..ID_REQUEST_MAX_PENDING - 1 {
        store.start_id_request(&mut IdRequest::new(&format!("cherry-{i}"), now)).unwrap();
    }
    let refused = store.start_id_request(&mut IdRequest::new("date-fig", now));
    assert_eq!(refused, Err(StoreError::Constraint));
    let rows = store.people_by_latest_interaction().unwrap();
    assert!(!rows.iter().any(|p| p.friends_id.as_deref() == Some("date-fig")), "a refused request leaves no row");
}

#[test]
fn answers_get_their_own_rows_and_slots_run_out() {
    let scratch = Scratch::new("answers");
    let mut store = open(&scratch);
    let now = unix_now();
    let mut request = IdRequest::new("apple-banana", now);
    let row = store.start_id_request(&mut request).unwrap();
    let token = request.request_token;
    assert!(store.id_request_admits(&token, &[10; 32], false, now));
    let first = store.conversation_for_id_answer(&token, [10; 32], [11; 32], false, now).unwrap();
    assert_eq!(first, row, "the request's own row takes the first key");
    assert_eq!(store.conversation_for_id_answer(&token, [10; 32], [11; 32], false, now).unwrap(), row, "again");
    assert!(store.pending_id_requests(now).is_empty(), "answered: no longer offered");
    assert!(store.id_request_with_token(&token, now).is_some(), "but its token still admits");
    let second = store.conversation_for_id_answer(&token, [20; 32], [21; 32], false, now).unwrap();
    assert_ne!(second, row, "another key is another person");
    assert!(!store.id_request_admits(&token, &[30; 32], false, now), "two unattested at most");
    assert!(store.id_request_admits(&token, &[30; 32], true, now), "the last slot waits for the holder");
    store.conversation_for_id_answer(&token, [30; 32], [31; 32], true, now).unwrap();
    assert!(!store.id_request_admits(&token, &[40; 32], true, now), "three at most");
    assert!(store.identity_key_answers_unexpired_id_request(&[20; 32], now));
    let later = now + 8.0 * 86_400.0;
    assert!(store.id_request_with_token(&token, later).is_none(), "an expired token admits nobody");
    assert!(!store.identity_key_answers_unexpired_id_request(&[20; 32], later));
}

#[test]
fn a_known_holder_takes_their_row_back() {
    let scratch = Scratch::new("reclaim");
    let mut store = open(&scratch);
    let now = unix_now();
    let mut removed = person(&mut store, Relation::Removed, 50, Some("apple-banana"));
    removed.comparison_code = Some("123456".into());
    store.save_person(&removed).unwrap();
    let mut request = IdRequest::new("apple-banana", now);
    let row = store.start_id_request(&mut request).unwrap();
    assert_ne!(row, removed.conversation_id, "a row holding a key is never reused for a new request");
    let conversation =
        store.conversation_for_id_answer(&request.request_token, [50; 32], [50 ^ 0xff; 32], false, now).unwrap();
    assert_eq!(conversation, removed.conversation_id);
    assert!(store.person_with_conversation(&row).unwrap().is_none(), "the keyless row folded into theirs");
    let back = store.person_with_conversation(&conversation).unwrap().unwrap();
    assert_eq!(back.relation, Relation::OutgoingRequest);
    assert_eq!(back.comparison_code, None, "a new friendship gets its own code");
    // Someone else's key answering keeps their own row unchanged.
    let other = person(&mut store, Relation::Removed, 60, Some("other-id"));
    let mut second = IdRequest::new("cherry-date", now);
    store.start_id_request(&mut second).unwrap();
    let kept = store.conversation_for_id_answer(&second.request_token, [60; 32], [60 ^ 0xff; 32], false, now).unwrap();
    assert_eq!(kept, other.conversation_id);
    assert_eq!(store.person_with_conversation(&kept).unwrap().unwrap().relation, Relation::Removed);
    // A blocked key never answers.
    let blocked = person(&mut store, Relation::Blocked, 70, None);
    let mut third = IdRequest::new("elder-fig", now);
    store.start_id_request(&mut third).unwrap();
    assert!(!store.id_request_admits(&third.request_token, &blocked.identity_key.unwrap(), true, now));
}

#[test]
fn requests_lapse() {
    let scratch = Scratch::new("lapse");
    let mut store = open(&scratch);
    let now = unix_now();
    let mut stranger = Person::new(Relation::IncomingRequest);
    stranger.identity_key = Some([80; 32]);
    stranger.request_at = Some(now - INCOMING_REQUEST_LIFETIME_SECONDS - 10.0);
    store.save_person(&stranger).unwrap();
    let mut former = Person::new(Relation::IncomingRequest);
    former.identity_key = Some([81; 32]);
    former.request_at = Some(now - INCOMING_REQUEST_LIFETIME_SECONDS - 10.0);
    store.save_person(&former).unwrap();
    store.record_event(&former.conversation_id, "now_friends").unwrap();
    let mut nearby = Person::new(Relation::OutgoingRequest);
    nearby.identity_key = Some([82; 32]);
    nearby.request_found_nearby = true;
    nearby.request_at = Some(now - OUTGOING_REQUEST_LIFETIME_SECONDS - 10.0);
    store.save_person(&nearby).unwrap();
    let lapsed = store.expire_incoming_requests(now).unwrap();
    assert_eq!(lapsed.len(), 2);
    assert!(store.person_with_conversation(&stranger.conversation_id).unwrap().is_none());
    let kept = store.person_with_conversation(&former.conversation_id).unwrap().unwrap();
    assert_eq!(kept.relation, Relation::Removed, "history kept");
    assert_eq!(store.expire_outgoing_requests(now).unwrap().len(), 1);
    assert!(store.person_with_conversation(&nearby.conversation_id).unwrap().is_none());
}

#[test]
fn nearby_settings() {
    let scratch = Scratch::new("settings");
    let mut store = open(&scratch);
    assert!(!store.nearby_permissions_requested());
    store.set_nearby_permissions_requested().unwrap();
    assert!(store.nearby_permissions_requested());
    assert_eq!(store.own_presence_secret(), None);
    let secret = store.ensure_own_presence_secret().unwrap();
    assert_eq!(store.ensure_own_presence_secret().unwrap(), secret);
    let now = unix_now();
    store.set_visibility_deadline(Some(now + 100.0)).unwrap();
    store.set_visibility_deadline(Some(now + 300.0)).unwrap();
    assert_eq!(store.visibility_deadline(), Some(now + 100.0), "a running deadline is never extended");
    store.set_visibility_deadline(Some(now + 50.0)).unwrap();
    assert_eq!(store.visibility_deadline(), Some(now + 50.0), "an earlier one applies");
    store.set_visibility_deadline(None).unwrap();
    assert_eq!(store.visibility_deadline(), None);
}

#[test]
fn host_attestations_confirm_ids_and_lapse_with_a_rename() {
    let scratch = Scratch::new("attest");
    let mut store = open(&scratch);
    let holder = person(&mut store, Relation::OutgoingRequest, 4, Some("guessed-id"));
    assert!(!holder.friends_id_confirmed);
    let proof = br#"{"day":"2026-10-13"}"#;
    store.confirm_friends_id(&holder.conversation_id, "maple-river", proof, "2026-10-13").unwrap();
    let read = store.person_with_conversation(&holder.conversation_id).unwrap().unwrap();
    assert_eq!(read.friends_id.as_deref(), Some("maple-river"), "the host's word outranks the guess");
    assert!(read.friends_id_confirmed);
    let keyless = Person::new(Relation::OutgoingRequest);
    store.save_person(&keyless).unwrap();
    assert!(matches!(
        store.confirm_friends_id(&keyless.conversation_id, "maple-river", proof, "2026-10-13"),
        Err(StoreError::Invalid(_))
    ));
    assert_eq!(store.confirm_friends_id("nobody", "maple-river", proof, "2026-10-13"), Err(StoreError::NotFound));
    assert!(store.confirm_friends_id(&holder.conversation_id, "maple-river", proof, "13-10-2026").is_err());

    // Our own: kept only for the ID the profile has, readable only while it still has it.
    let conn = store.connection();
    conn.execute("INSERT INTO profile (id, friends_id, friends_id_state) VALUES (1, 'quiet-fox', 1)", []).unwrap();
    assert_eq!(store.save_friends_id_attestation("other-id", proof, "2026-10-13"), Err(StoreError::Stale));
    assert_eq!(store.friends_id_attestation(), None);
    store.save_friends_id_attestation("quiet-fox", proof, "2026-10-13").unwrap();
    assert_eq!(store.friends_id_attestation().as_deref(), Some(&proof[..]));
    store.connection().execute("UPDATE profile SET friends_id = 'loud-fox' WHERE id = 1", []).unwrap();
    assert_eq!(store.friends_id_attestation(), None, "a rename voids it");
}

#[test]
fn only_a_removed_or_blocked_person_can_be_off_the_list() {
    let scratch = Scratch::new("off-list");
    let mut store = open(&scratch);
    let mut mei = person(&mut store, Relation::Removed, 1, None);
    mei.left_list_at = Some(1000.0);
    store.save_person(&mei).unwrap();
    let read = store.person_with_conversation(&mei.conversation_id).unwrap().unwrap();
    assert_eq!(read.left_list_at, Some(1000.0));
    // Blocking keeps them off it; a request from either side brings them back.
    mei.relation = Relation::Blocked;
    store.save_person(&mei).unwrap();
    assert_eq!(store.person_with_conversation(&mei.conversation_id).unwrap().unwrap().left_list_at, Some(1000.0));
    for relation in [Relation::IncomingRequest, Relation::OutgoingRequest, Relation::Friend] {
        let mut again = mei.clone();
        again.relation = relation;
        store.save_person(&again).unwrap();
        let read = store.person_with_conversation(&mei.conversation_id).unwrap().unwrap();
        assert_eq!(read.left_list_at, None, "{relation:?} saves no left_list_at");
        let stored: Option<f64> = store
            .connection()
            .query_row("SELECT left_list_at FROM friends WHERE conversation_id = ?1", [&mei.conversation_id], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(stored, None);
    }
    // A column an older helper left behind counts only while the relation allows it.
    store
        .connection()
        .execute(
            "UPDATE friends SET left_list_at = 2000, relation = 0 WHERE conversation_id = ?1",
            [&mei.conversation_id],
        )
        .unwrap();
    assert_eq!(store.person_with_conversation(&mei.conversation_id).unwrap().unwrap().left_list_at, None);
    store
        .connection()
        .execute("UPDATE friends SET relation = 3 WHERE conversation_id = ?1", [&mei.conversation_id])
        .unwrap();
    let removed = store.people_by_latest_interaction().unwrap();
    assert_eq!(removed[0].left_list_at, Some(2000.0));
}

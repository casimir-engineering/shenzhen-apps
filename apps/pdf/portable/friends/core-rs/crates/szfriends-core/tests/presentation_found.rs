//! How a nearby person was found (client capability `nearby.found`): Nearby's rows and a friend's list row name every
//! discovery method that sees the person now, in the order local network, direct Wi-Fi, Bluetooth; nobody is "found"
//! who no method sees; and a client without `nearby.found` gets the rows it always got (`SZFriendsPresentationFoundTests.m`).
//!
//! nearby-found.json: both methods working, nobody visible, four people as nearby_visible_bluetooth_off has them, found
//! over: Kenji (friend) the local network and Bluetooth, Lena (stranger) Bluetooth, Tomás (request sent) the local
//! network, coral-lagoon (stranger, no name) direct Wi-Fi, the local network and Bluetooth. list-found.json: the list's
//! people, Mei found over the local network and Bluetooth, Kenji over Bluetooth, and Lena (a request, not a friend)
//! over the local network, which her row never says.

mod presentation;

use std::collections::HashMap;

use presentation::world::*;
use presentation::{expect_fixture, validate_snapshot};
use serde_json::{json, Value};
use szfriends_core::presentation::{AdapterState, Audience, NearbyFacts, Relation, RouteMethod};

fn found_audience() -> Audience {
    let mut audience = audience();
    audience.capabilities.insert("nearby.found".into());
    audience
}

fn nearby_row(audience: Audience, methods: &[RouteMethod]) -> Value {
    let mut facts = nearby_visible_bluetooth_off();
    for person in &mut facts.people {
        person.found_methods = methods.to_vec();
    }
    let nearby = builder(audience).nearby(&facts, &profile_raph(), "", now());
    validate_snapshot(&nearby, "nearby", "found");
    nearby["people"][0].clone()
}

#[test]
fn nearby_rows_name_each_method() {
    if presentation::tree_missing() {
        return;
    }
    let cases: [(&[RouteMethod], Value); 5] = [
        (&[], Value::Null),
        (&[RouteMethod::Lan], json!({"methods": ["lan"], "label": "Local network"})),
        (&[RouteMethod::Bluetooth], json!({"methods": ["bluetooth"], "label": "Bluetooth"})),
        (
            &[RouteMethod::Bluetooth, RouteMethod::Lan],
            json!({"methods": ["lan", "bluetooth"], "label": "Local network and Bluetooth"}),
        ),
        (
            &[RouteMethod::Bluetooth, RouteMethod::PeerToPeerWifi, RouteMethod::Lan],
            json!({"methods": ["lan", "p2p_wifi", "bluetooth"], "label": "Local network, Direct Wi-Fi and Bluetooth"}),
        ),
    ];
    for (methods, expected) in cases {
        let row = nearby_row(found_audience(), methods);
        assert_eq!(row["found"], expected, "{methods:?}");
        let spoken = row["accessibility_label"].as_str().unwrap();
        match expected["label"].as_str() {
            Some(label) => assert!(spoken.ends_with(&format!(", Found over {label}")), "{spoken}"),
            None => assert!(!spoken.contains("Found over"), "{spoken}"),
        }
    }
    let plain = nearby_row(audience(), &[RouteMethod::Lan]);
    assert!(plain.get("found").is_none() && !plain["accessibility_label"].as_str().unwrap().contains("Found"));
}

#[test]
fn a_friend_in_the_list_while_nearby() {
    if presentation::tree_missing() {
        return;
    }
    let mut people = presentation::world::people();
    people.get_mut("c_mei").unwrap().found_methods = vec![RouteMethod::Lan, RouteMethod::Bluetooth];
    people.get_mut("c_lena").unwrap().found_methods = vec![RouteMethod::Lan]; // a request: only friends' rows say
    let all = everyone(&people);
    let list = builder(found_audience()).list(&all, &preview_items(), &profile_raph(), "", now());
    validate_snapshot(&list, "list", "found");
    let rows: HashMap<String, Value> = list["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| (r["conversation_id"].as_str().unwrap().to_owned(), r.clone()))
        .collect();
    assert_eq!(
        rows["c_mei"]["found"],
        json!({"methods": ["lan", "bluetooth"], "label": "Local network and Bluetooth"})
    );
    assert!(rows["c_mei"]["accessibility_label"]
        .as_str()
        .unwrap()
        .ends_with(", Found over Local network and Bluetooth"));
    assert!(rows["c_kenji"]["found"].is_null(), "not seen nearby now");
    assert!(rows["c_lena"]["found"].is_null(), "not a friend");
    let plain = builder(audience()).list(&all, &preview_items(), &profile_raph(), "", now());
    assert!(plain["rows"].as_array().unwrap().iter().all(|r| r.get("found").is_none()));
}

fn found_nearby() -> NearbyFacts {
    use RouteMethod::{Bluetooth, Lan, PeerToPeerWifi};
    let seen = |nearby_id: Option<&str>,
                conversation: Option<&str>,
                name: Option<&str>,
                friends_id: &str,
                animal: i64,
                stranger: bool,
                relation: Relation,
                found: &[RouteMethod]| {
        let mut person = nearby_person(nearby_id, conversation, name, friends_id, animal, stranger, relation, found[0]);
        person.found_methods = found.to_vec();
        person
    };
    NearbyFacts {
        network_state: AdapterState::Working,
        bluetooth_state: AdapterState::Working,
        working_since: Some(hk("2026-10-12 14:40:10")),
        people: vec![
            seen(
                None,
                Some("c_kenji"),
                Some("Kenji Sato"),
                "cedar-lantern",
                1,
                false,
                Relation::Friend,
                &[Lan, Bluetooth],
            ),
            seen(Some("n_7c1e"), None, Some("Lena Weber"), "amber-falcon", 3, true, Relation::Friend, &[Bluetooth]),
            seen(
                Some("n_2b90"),
                Some("c_tomas"),
                Some("Tomás Rivera"),
                "juniper-spring",
                4,
                true,
                Relation::OutgoingRequest,
                &[Lan],
            ),
            seen(
                Some("n_9d44"),
                None,
                None,
                "coral-lagoon",
                10,
                true,
                Relation::Friend,
                &[Bluetooth, Lan, PeerToPeerWifi],
            ),
        ],
        ..Default::default()
    }
}

#[test]
fn the_found_fixtures() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(found_audience());
    let nearby = builder.nearby(&found_nearby(), &profile_raph(), "", now());
    expect_fixture(&nearby, "nearby-found.json", "nearby");
    let mut people = presentation::world::people();
    people.get_mut("c_mei").unwrap().found_methods = vec![RouteMethod::Lan, RouteMethod::Bluetooth];
    people.get_mut("c_kenji").unwrap().found_methods = vec![RouteMethod::Bluetooth];
    people.get_mut("c_lena").unwrap().found_methods = vec![RouteMethod::Lan];
    let list = builder.list(&everyone(&people), &preview_items(), &profile_raph(), "", now());
    expect_fixture(&list, "list-found.json", "list");
}

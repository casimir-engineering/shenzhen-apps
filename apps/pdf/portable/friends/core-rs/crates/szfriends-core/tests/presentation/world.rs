//! The facts behind the golden fixtures (`SZFriendsPresentationWorld.m`): the people, items, profile and Nearby state
//! the mockups show, at the fixtures' clock (Monday 12 October 2026, 14:47:48 Hong Kong time). Times are Hong Kong
//! wall-clock times, matching the fixtures' labels and their RFC 3339 instants.

use std::collections::HashMap;

#[allow(unused_imports)] // the suites that build conversations use them
pub use super::items::*;
use szfriends_core::presentation::mentions::key_from_string;
use szfriends_core::presentation::time::{days_from_civil, TimeZone};
use szfriends_core::presentation::{
    AdapterState, Audience, IdState, NearbyFacts, NearbyPersonFacts, PersonFacts, Picture, ProfileFacts,
    ReceivedFolderFacts, Relation, RouteKind, RouteMethod, SnapshotBuilder,
};

pub const KEY_MEI: &str = "4VfVbTCPmosk0EmB4HbM9anI6WU2iMvJAX4lM3fFJu0";
pub const KEY_KENJI: &str = "gLwC335QDCEsaH4RFgglBnA5_tuYt2iBPS9iyZ9PfFM";
pub const KEY_LENA: &str = "Gx7e5Y2l0M5eZN_EoY_5Af4YbPJ-ZDkVBz8bp_RVH1k";
pub const KEY_DANIEL: &str = "wqxssxkOxWnY3gErAhojbyDStwGh7ItOEPkCK8k7c_U";
pub const KEY_PRIYA: &str = "w9_wFJ6KVjt4YRmiX2wXPjxOORLKfcq7MbOoSxPXMc4";
pub const KEY_TULIP: &str = "Vvv7gpi00_qnpLi5abuYO2omFoq5oKTt29E3Pnq-Tm4";
pub const KEY_JONAS: &str = "GjynlfI-lEigaBnJKZJ_NkcDKuY-m15vLmDagtJlr84";
pub const KEY_RAPH: &str = "C7p4jaaHK1zWWJGVH-YasjrlEk8qfJvd3KLmn0IFY3E";
/// Someone none of them is friends with (Leo Park, bonfire-otter), and a key that is not Kenji's.
pub const KEY_LEO: &str = "tN1JdICMMlIsgspydMWcnrWDAec9jXbspfRfygj7Q6o";
pub const KEY_FORGED: &str = "s3f8Kz4p4VLH9QagQL1wR2ZwPi-p1QEz22O2RmM2NBo";

pub fn key(text: &str) -> [u8; 32] {
    key_from_string(text).expect("a canonical key")
}

/// An instant at a Hong Kong wall-clock time ("2026-10-11 18:02" or "2026-10-12 14:47:48").
pub fn hk(wall_clock: &str) -> f64 {
    let number = |range: std::ops::Range<usize>| wall_clock[range].parse::<i64>().unwrap();
    let days = days_from_civil(number(0..4), number(5..7) as u32, number(8..10) as u32);
    let seconds = if wall_clock.len() > 16 { number(17..19) } else { 0 };
    (days * 86_400 + number(11..13) * 3600 + number(14..16) * 60 + seconds - 8 * 3600) as f64
}

pub fn now() -> f64 {
    hk("2026-10-12 14:47:48")
}

/// ShenzhenPDF in Hong Kong, with the hello fixture's capabilities and formats.
pub fn audience() -> Audience {
    let set = |items: &[&str]| items.iter().map(|s| s.to_string()).collect();
    Audience {
        app_name: "ShenzhenPDF".into(),
        reveal_in: "Finder".into(),
        locale: "en-GB".into(),
        capabilities: set(&["attach.items", "drop.files", "drop.tabs", "search.export"]),
        open_formats: set(&["pdf", "epub", "xps", "cbz", "md", "markdown"]),
        time_zone: TimeZone::fixed(8 * 3600),
        helper_capabilities: set(&["received.folder"]),
    }
}

pub fn builder(audience: Audience) -> SnapshotBuilder {
    SnapshotBuilder::new(audience, Some(super::animal_set()))
}

pub fn profile_raph() -> ProfileFacts {
    ProfileFacts {
        name: Some("Raph".into()),
        friends_id: "cottage-violet".into(),
        friends_id_state: IdState::Unreserved,
        picture: Picture::animal(1, 0),
        identity_public_key: Some(key(KEY_RAPH)),
        received: ReceivedFolderFacts { path: Some("/Users/raph/Downloads".into()), ..ReceivedFolderFacts::default() },
        ..Default::default()
    }
}

pub fn profile_id_changed() -> ProfileFacts {
    ProfileFacts {
        name: None,
        friends_id: "walnut-garden".into(),
        previous_friends_id: Some("walnut-valley".into()),
        friends_id_state: IdState::Changed,
        picture: Picture::animal(1, 10),
        ..profile_raph()
    }
}

#[allow(clippy::too_many_arguments)]
fn person(
    conversation: &str,
    name: Option<&str>,
    friends_id: &str,
    animal: i64,
    relation: Relation,
    kind: RouteKind,
    method: RouteMethod,
    last: &str,
    preview: Option<&str>,
) -> PersonFacts {
    PersonFacts {
        conversation_id: conversation.into(),
        name: name.map(str::to_owned),
        friends_id: Some(friends_id.into()),
        picture: Picture::animal(1, animal),
        relation,
        route_kind: kind,
        route_method: method,
        last_interaction_at: hk(last),
        last_preview_item_id: preview.map(str::to_owned),
        ..Default::default()
    }
}

/// The list's seven people, keyed by conversation id.
pub fn people() -> HashMap<String, PersonFacts> {
    use RouteKind::{Local, None as NoRoute, Offline};
    use RouteMethod::{Bluetooth, Lan, None as NoMethod, PeerToPeerWifi};
    let mut lena = person(
        "c_lena",
        Some("Lena Weber"),
        "amber-falcon",
        3,
        Relation::IncomingRequest,
        Local,
        Lan,
        "2026-10-12 14:40",
        None,
    );
    lena.identity_key = Some(key(KEY_LENA));
    lena.request_at = Some(hk("2026-10-12 14:40"));
    lena.request_found_nearby = true;
    lena.comparison_code = Some("418270".into());
    let mut mei = person(
        "c_mei",
        Some("Mei Lin"),
        "jasmine-street",
        7,
        Relation::Friend,
        Local,
        Lan,
        "2026-10-12 14:32:05",
        Some("m_a4109f52"),
    );
    mei.identity_key = Some(key(KEY_MEI));
    mei.unread_count = 1;
    mei.verified = true;
    mei.verified_at = Some(hk("2026-10-03 10:12"));
    mei.auto_accept = true;
    mei.received_file_count = 14;
    mei.received_reveal_path = Some("/Users/raph/Downloads".into());
    let mut kenji = person(
        "c_kenji",
        Some("Kenji Sato"),
        "cedar-lantern",
        1,
        Relation::Friend,
        Local,
        Bluetooth,
        "2026-10-12 13:10",
        Some("t_kenji_site"),
    );
    kenji.identity_key = Some(key(KEY_KENJI));
    kenji.offers_waiting = 1;
    let mut daniel = person(
        "c_daniel",
        Some("Daniel Ortiz"),
        "quiet-harvest",
        5,
        Relation::Friend,
        Local,
        PeerToPeerWifi,
        "2026-10-12 11:05",
        Some("t_daniel_guide"),
    );
    daniel.identity_key = Some(key(KEY_DANIEL));
    daniel.auto_accept = true;
    let mut priya = person(
        "c_priya",
        Some("Priya Raman"),
        "silver-ocean",
        9,
        Relation::Friend,
        Offline,
        NoMethod,
        "2026-10-11 18:02:10",
        Some("t_6a2f90b8"),
    );
    priya.identity_key = Some(key(KEY_PRIYA));
    // Added by ID; the Friends host confirmed the answer came from the ID's holder, so the row marks the ID.
    let mut tulip = person(
        "c_tulip",
        None,
        "tulip-canyon",
        11,
        Relation::Friend,
        Offline,
        NoMethod,
        "2026-10-03 16:00",
        Some("e_tulip_friends"),
    );
    tulip.friends_id_confirmed = true;
    tulip.identity_key = Some(key(KEY_TULIP));
    // Blocked two weeks ago: the row stays so the person can unblock, drawn muted. No session, so no route.
    let mut jonas = person(
        "c_jonas",
        Some("Jonas Berg"),
        "copper-pebble",
        4,
        Relation::Blocked,
        NoRoute,
        NoMethod,
        "2026-09-28 11:40",
        None,
    );
    jonas.identity_key = Some(key(KEY_JONAS));
    [lena, mei, kenji, daniel, priya, tulip, jonas].into_iter().map(|p| (p.conversation_id.clone(), p)).collect()
}

/// Everyone, in a stable order.
pub fn everyone(people: &HashMap<String, PersonFacts>) -> Vec<PersonFacts> {
    let mut all: Vec<PersonFacts> = people.values().cloned().collect();
    all.sort_by(|a, b| a.conversation_id.cmp(&b.conversation_id));
    all
}

#[allow(clippy::too_many_arguments)]
fn nearby_person(
    nearby_id: Option<&str>,
    conversation: Option<&str>,
    name: Option<&str>,
    friends_id: &str,
    animal: i64,
    stranger: bool,
    relation: Relation,
    route: RouteMethod,
) -> NearbyPersonFacts {
    NearbyPersonFacts {
        nearby_id: nearby_id.map(str::to_owned),
        conversation_id: conversation.map(str::to_owned),
        name: name.map(str::to_owned),
        friends_id: Some(friends_id.into()),
        picture: Picture::animal(1, animal),
        is_stranger: stranger,
        relation,
        route_method: route,
        found_methods: Vec::new(),
    }
}

pub fn nearby_visible_bluetooth_off() -> NearbyFacts {
    NearbyFacts {
        visibility_deadline: Some(hk("2026-10-12 14:52:00")),
        network_state: AdapterState::Working,
        bluetooth_state: AdapterState::RadioOff,
        searching: true,
        working_since: Some(hk("2026-10-12 14:40:10")),
        people: vec![
            nearby_person(
                None,
                Some("c_kenji"),
                Some("Kenji Sato"),
                "cedar-lantern",
                1,
                false,
                Relation::Friend,
                RouteMethod::Lan,
            ),
            nearby_person(
                Some("n_7c1e"),
                None,
                Some("Lena Weber"),
                "amber-falcon",
                3,
                true,
                Relation::Friend,
                RouteMethod::Lan,
            ),
            nearby_person(
                Some("n_2b90"),
                Some("c_tomas"),
                Some("Tomás Rivera"),
                "juniper-spring",
                4,
                true,
                Relation::OutgoingRequest,
                RouteMethod::Lan,
            ),
            nearby_person(Some("n_9d44"), None, None, "coral-lagoon", 10, true, Relation::Friend, RouteMethod::Lan),
        ],
        ..Default::default()
    }
}

pub fn nearby_local_network_denied() -> NearbyFacts {
    NearbyFacts {
        network_state: AdapterState::Denied,
        bluetooth_state: AdapterState::Working,
        searching: true,
        working_since: Some(hk("2026-10-12 14:40:10")),
        people: vec![nearby_person(
            None,
            Some("c_kenji"),
            Some("Kenji Sato"),
            "cedar-lantern",
            1,
            false,
            Relation::Friend,
            RouteMethod::Bluetooth,
        )],
        ..Default::default()
    }
}

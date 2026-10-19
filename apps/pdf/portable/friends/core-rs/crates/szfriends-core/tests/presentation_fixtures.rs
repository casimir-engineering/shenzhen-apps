//! Every golden fixture under `fixtures/snapshots/` rebuilt from the facts behind it, as the same JSON value the
//! Objective-C builder makes (`SZFriendsPresentationTests.m`, `...JoinTests.m`, `...LinksTests.m`,
//! `...MentionTests.m`, `...AssistantTests.m`), each also validated against PROTOCOL.md's schema blocks. The people
//! come through a real store first (`through_store`). The devices-* and online-* fixtures are in
//! `presentation_devices.rs`.

mod presentation;

use std::collections::HashMap;

use presentation::world::*;
use presentation::{expect_fixture, through_store, validate_snapshot};
use szfriends_core::presentation::{
    DownloadLinkFacts, ItemFacts, JoinRequestFacts, JoiningFacts, JoiningState, LinksFacts, MentionDirectory,
    PersonFacts, ProfileFacts, SnapshotBuilder,
};

/// Every snapshot fixture, and the suite that builds it.
const COVERED: [&str; 34] = [
    "badge.json",
    "list.json",
    "list-id-changed.json",
    "nearby-visible-bluetooth-off.json",
    "nearby-local-network-denied.json",
    "conversation-mei.json",
    "conversation-kenji-offer.json",
    "conversation-priya-queued.json",
    "conversation-request-lena.json",
    "details-mei.json",
    "profile-unreserved.json",
    "settings.json",
    "key-change-details-mei.json",
    "list-join-requests.json",
    "badge-join-requests.json",
    "join-idle.json",
    "join-wrong-code.json",
    "join-denied.json",
    "join-joined.json",
    "profile-links.json",
    "conversation-daniel-mentions.json",
    "message-status.json",
    // presentation_devices.rs
    "devices-profile.json",
    "devices-list.json",
    "devices-list-removed.json",
    "devices-list-new-computer.json",
    "devices-conversation-you.json",
    "devices-conversation-mei-files.json",
    "devices-settings.json",
    "devices-details-mei.json",
    "online-list.json",
    "online-conversation-kenji-relay.json",
    "online-conversation-priya-unreachable.json",
    "online-conversation-priya-connecting.json",
];

fn people() -> HashMap<String, PersonFacts> {
    through_store(&presentation::world::people())
}

#[test]
fn every_snapshot_fixture_is_built() {
    if presentation::tree_missing() {
        return;
    }
    let mut files: Vec<String> = std::fs::read_dir(presentation::friends_dir().join("fixtures/snapshots"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|name| name.ends_with(".json"))
        .collect();
    files.sort();
    let mut covered: Vec<String> = COVERED.iter().map(|s| s.to_string()).collect();
    covered.sort();
    assert_eq!(files, covered);
}

#[test]
fn the_list_badge_and_nearby() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(audience());
    let people = people();
    let all = everyone(&people);
    expect_fixture(&builder.badge(&all, 0), "badge.json", "badge");
    expect_fixture(&builder.list(&all, &preview_items(), &profile_raph(), "", now()), "list.json", "list");
    let changed = builder.list(&[], &HashMap::new(), &profile_id_changed(), "", now());
    expect_fixture(&changed, "list-id-changed.json", "list");
    let visible = builder.nearby(&nearby_visible_bluetooth_off(), &profile_raph(), "", now());
    expect_fixture(&visible, "nearby-visible-bluetooth-off.json", "nearby");
    let denied = builder.nearby(&nearby_local_network_denied(), &profile_raph(), "", now());
    expect_fixture(&denied, "nearby-local-network-denied.json", "nearby");
}

#[test]
fn conversations() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(audience());
    let people = people();
    // waiting_elsewhere: Lena's request and Kenji's offer wait; each conversation counts the others.
    let built = |id: &str, items: &[ItemFacts], earlier: bool, waiting: i64| {
        builder.conversation(&people[id], items, earlier, None, waiting, now())
    };
    expect_fixture(&built("c_mei", &items_for("c_mei"), false, 2), "conversation-mei.json", "conversation");
    expect_fixture(&built("c_kenji", &items_for("c_kenji"), true, 1), "conversation-kenji-offer.json", "conversation");
    expect_fixture(
        &built("c_priya", &items_for("c_priya"), false, 2),
        "conversation-priya-queued.json",
        "conversation",
    );
    expect_fixture(&built("c_lena", &[], false, 1), "conversation-request-lena.json", "conversation");
}

#[test]
fn details_profile_and_settings() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(audience());
    let people = people();
    // Every view below the list carries the list's count: Lena's request and Kenji's offer wait.
    expect_fixture(&builder.details(&people["c_mei"], 2, now()), "details-mei.json", "details");
    expect_fixture(&builder.profile(&profile_raph(), 2), "profile-unreserved.json", "profile");
    expect_fixture(&builder.settings(&profile_raph(), &everyone(&people)), "settings.json", "settings");
    // Mei's new key waits for review: her row waits too, so the two others are "more".
    let mut mei = people["c_mei"].clone();
    mei.key_change_pending = true;
    expect_fixture(&builder.details(&mei, 2, now()), "key-change-details-mei.json", "details");
}

fn join_requests() -> Vec<JoinRequestFacts> {
    let waiting = JoinRequestFacts {
        join_id: "5f2d0c4be1a94a7b8d3e6f1a2b3c4d5e".into(),
        device_name: "Raph’s MacBook Air".into(),
        system: "macOS 26.1".into(),
        received_at: hk("2026-10-12 14:46"),
        ..Default::default()
    };
    let approved = JoinRequestFacts {
        join_id: "0a1b2c3d4e5f60718293a4b5c6d7e8f9".into(),
        device_name: "Raph’s Mac mini".into(),
        system: "macOS 15.7".into(),
        received_at: hk("2026-10-12 14:45"),
        approved: true,
        code: Some("48312207".into()),
        code_expires_at: Some(hk("2026-10-12 14:51")),
    };
    vec![approved, waiting]
}

#[test]
fn joining() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(audience());
    let people = everyone(&people());
    let mut list = builder.list(&people, &preview_items(), &profile_raph(), "", now());
    validate_snapshot(&list, "list", "list-join-requests.json without its join rows");
    list["join_requests"] = builder.join_request_rows(&join_requests(), now());
    expect_fixture(&list, "list-join-requests.json", "list");
    expect_fixture(&builder.badge(&people, join_requests().len()), "badge-join-requests.json", "badge");
    let joining = |state, id: Option<&str>| JoiningFacts { state, friends_id: id.map(str::to_owned) };
    expect_fixture(&builder.join(&joining(JoiningState::Idle, None)), "join-idle.json", "join");
    let id = Some("cottage-violet");
    expect_fixture(&builder.join(&joining(JoiningState::WrongCode, id)), "join-wrong-code.json", "join");
    expect_fixture(&builder.join(&joining(JoiningState::Denied, id)), "join-denied.json", "join");
    expect_fixture(&builder.join(&joining(JoiningState::Joined, id)), "join-joined.json", "join");
}

pub fn links_audience() -> szfriends_core::presentation::Audience {
    let mut audience = audience();
    audience.helper_capabilities = ["nearby.network", "host.checkin", "links"].iter().map(|s| s.to_string()).collect();
    audience
}

pub fn profile_with_links(downloads: Vec<DownloadLinkFacts>) -> ProfileFacts {
    let links = LinksFacts {
        friend_url: Some("https://friends.example/f#AbTdSXSAjDJSLILKcnTFnJ61gwHnPY127KX0X8oI-0Oq".into()),
        downloads,
        now: now(),
    };
    ProfileFacts { links: Some(links), ..profile_raph() }
}

pub fn download(link_id: &str, name: &str, downloads: u64, days: f64) -> DownloadLinkFacts {
    DownloadLinkFacts {
        link_id: link_id.into(),
        file_name: name.into(),
        downloads,
        expires_at: now() + days * 86_400.0,
    }
}

#[test]
fn your_links() {
    if presentation::tree_missing() {
        return;
    }
    let downloads = vec![
        download("EBESExQVFhcYGRobHB0eHw", "Site photos.pdf", 3, 6.0),
        download(
            "IiMkJSYnKCkqKywtLi8wMQ",
            "Supplier contract v3 with the long annex and the signed amendments.pdf",
            0,
            1.0,
        ),
    ];
    let profile = builder(links_audience()).profile(&profile_with_links(downloads), 2);
    expect_fixture(&profile, "profile-links.json", "profile");
}

pub fn mention_builder(people: &HashMap<String, PersonFacts>) -> SnapshotBuilder {
    let mut audience = audience();
    audience.capabilities.insert("mentions".into());
    let mut builder = builder(audience);
    builder.mention_directory = Some(MentionDirectory::new(&everyone(people), &profile_raph()));
    builder
}

#[test]
fn mentions_in_daniels_conversation() {
    if presentation::tree_missing() {
        return;
    }
    // The golden fixture: a friend, a stranger, the reader, someone who asked, someone blocked, and a forgery.
    let people = people();
    let builder = mention_builder(&people);
    let built = builder.conversation(&people["c_daniel"], &items_for("c_daniel"), false, None, 2, now());
    expect_fixture(&built, "conversation-daniel-mentions.json", "conversation");
}

/// The world's items with these ids, each knowing its conversation as the helper's facts do.
fn items_by_id(ids: &[&str]) -> Vec<ItemFacts> {
    let mut found = Vec::new();
    for id in ids {
        for conversation in ["c_mei", "c_kenji", "c_priya"] {
            for mut item in items_for(conversation) {
                if item.item_id == *id {
                    item.conversation_id = Some(conversation.into());
                    found.push(item);
                }
            }
        }
    }
    found
}

#[test]
fn message_status() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(audience());
    let people = people();
    // Mei's own question and Priya's queued file have no row; the message Raph cancelled has one, saying so.
    let asked = items_by_id(&["m_c4d27a19", "m_7a3e5b21", "m_a4109f52", "t_6a2f90b8", "m_5f2a90c1"]);
    let data = builder.message_status_view(&asked, &people);
    expect_fixture(&data, "message-status.json", "message_status");
    let priya = builder.conversation(&people["c_priya"], &items_for("c_priya"), false, None, 2, now());
    let in_conversation = priya["items"].as_array().unwrap().iter().find(|i| i["item_id"] == "m_c4d27a19").unwrap();
    assert_eq!(data["messages"][0]["status"], in_conversation["status"]);
}

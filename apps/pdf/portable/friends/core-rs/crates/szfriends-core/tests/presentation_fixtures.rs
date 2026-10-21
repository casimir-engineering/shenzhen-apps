//! Every golden fixture under `fixtures/snapshots/` rebuilt from the facts behind it, as the same JSON value the
//! Objective-C builder makes (`SZFriendsPresentationTests.m`, `...JoinTests.m`, `...LinksTests.m`,
//! `...MentionTests.m`, `...AssistantTests.m`), each also validated against PROTOCOL.md's schema blocks. The people
//! come through a real store first (`through_store`). The devices-*, online-* and phone-* fixtures are in
//! `presentation_devices.rs`; phone-* only the Rust core builds, since only it serves phones.

mod presentation;

use std::collections::HashMap;

use presentation::world::*;
use presentation::{expect_fixture, through_store, validate_snapshot};
use szfriends_core::presentation::Audience;
use szfriends_core::presentation::{
    DownloadLinkFacts, ItemFacts, JoinRequestFacts, JoiningFacts, JoiningState, LinksFacts, MentionDirectory,
    PersonFacts, ProfileFacts, ReceivedFolderFacts, SnapshotBuilder,
};
use szfriends_core::store::{PhoneFolder, ReceivedFallback, ReceivedFile, ReceivedSource};

/// Every snapshot fixture, and the suite that builds it.
const COVERED: [&str; 43] = [
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
    "received.json",
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
    "devices-list-join-reset.json",
    "devices-settings-join.json",
    "phone-settings-join.json",
    "devices-conversation-you.json",
    "devices-conversation-mei-files.json",
    "devices-conversation-mei-again.json",
    "devices-settings.json",
    "devices-details-mei.json",
    "phone-settings.json",
    "online-list.json",
    "online-conversation-kenji-relay.json",
    "online-conversation-priya-unreachable.json",
    "online-conversation-priya-connecting.json",
    // presentation_remove.rs
    "list-menu.json",
    // presentation_found.rs
    "nearby-found.json",
    "list-found.json",
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

/// The folder received files go to (helper capability `received.folder`): the chosen folder by its name, phones
/// without path or buttons, an older helper's row without them; and the `received` view.
#[test]
fn received_folder_and_received_view() {
    if presentation::tree_missing() {
        return;
    }
    let people = people();
    let settings = |audience: Audience, received: ReceivedFolderFacts| {
        let profile = ProfileFacts { received, ..profile_raph() };
        builder(audience).settings(&profile, &everyone(&people))["received"].clone()
    };
    let chosen = ReceivedFolderFacts {
        path: Some("/Users/raph/Documents/From friends".into()),
        chosen_name: Some("From friends".into()),
        phone: None,
        fallback: None,
    };
    let row = settings(audience(), chosen.clone());
    assert_eq!(row["value"], "From friends");
    assert_eq!(row["path"], "/Users/raph/Documents/From friends");
    assert_eq!(row["action"]["path"], "/Users/raph/Documents/From friends");
    assert_eq!(row["change"]["action"], "choose_received_folder");
    assert_eq!(row["note"], "");
    // The last file could not be saved there: the note says where it went instead.
    let fallback = |fallback| ReceivedFolderFacts { fallback: Some(fallback), ..chosen.clone() };
    let row = settings(audience(), fallback(ReceivedFallback::Downloads));
    assert_eq!(row["note"], "The last file couldn’t be saved here, so it went to Downloads.");
    let row = settings(audience(), fallback(ReceivedFallback::Kept));
    assert_eq!(
        row["note"],
        format!("The last file couldn’t be saved here, so {} kept it. Open it from its chat.", audience().app_name)
    );

    let mut older = audience();
    older.helper_capabilities.clear();
    let row = settings(older, chosen);
    assert!(row.get("value").is_none() && row.get("change").is_none() && row.get("path").is_none(), "{row}");
    assert_eq!(row["action"]["action"], "show_file");

    let mut phone = audience();
    phone.app_name = "Shenzhen 3D".into();
    phone.capabilities.insert("files.share".into());
    let ios = ReceivedFolderFacts { phone: Some(PhoneFolder::AppFiles), ..ReceivedFolderFacts::default() };
    let row = settings(phone.clone(), ios);
    assert_eq!(row["value"], "Shenzhen 3D");
    assert_eq!(row["note"], "In the Files app, under On My iPhone.");
    assert!(row["path"].is_null() && row["action"].is_null() && row["change"].is_null(), "{row}");
    let android = ReceivedFolderFacts { phone: Some(PhoneFolder::Downloads), ..ReceivedFolderFacts::default() };
    let row = settings(phone, android);
    assert_eq!((row["value"].as_str(), row["note"].as_str()), (Some("Downloads"), Some("")));
    assert!(row["path"].is_null() && row["action"].is_null() && row["change"].is_null(), "{row}");

    let file = |id: &str, name: &str, at: i64, source: ReceivedSource| ReceivedFile {
        transfer_id: id.into(),
        path: format!("/Users/raph/Downloads/{name}"),
        file_name: name.into(),
        received_at: at,
        source,
    };
    let files = [
        file("t_9b31e7a2", "Supplier contract v3 (2).pdf", 1792310520, ReceivedSource::Friend),
        file("t_c81f04d2", "Bracket rev B.step", 1792306810, ReceivedSource::Device),
        file("t_5d0a6c11", "Site photos.zip", 1792221405, ReceivedSource::Link),
        file("t_7e2f44b0", "Supplier contract v3.pdf", 1792138002, ReceivedSource::Friend),
    ];
    expect_fixture(&builder(audience()).received(&files), "received.json", "received");
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

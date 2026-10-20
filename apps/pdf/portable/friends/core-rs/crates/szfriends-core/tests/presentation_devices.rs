//! One profile on several computers and online friends, built from facts (`SZFriendsPresentationDevicesBuildTests.m`,
//! `SZFriendsPresentationOnlineTests.m`): every devices-* and online-* fixture rebuilt as the same JSON value, each
//! validated against PROTOCOL.md, and the states around them. Without devices facts every view stays the one-computer
//! view; a helper that does not announce `online` says nothing of the Internet, whatever the facts hold.

mod presentation;

use std::collections::{BTreeMap, BTreeSet, HashMap};

use presentation::world::*;
use presentation::{expect_fixture, through_store, validate_snapshot};
use szfriends_core::presentation::{
    Audience, DeviceFacts, DeviceFileFacts, DevicesFacts, IdentityState, ItemFacts, OnlineReach, OutboxState,
    PersonFacts, ProfileFacts, ReceivedFolderFacts, Relation, RouteKind, RouteMethod, TransferState,
};
use szfriends_core::store::PhoneFolder;

fn computer(id: &str, name: &str, system: &str, this: bool, connected: bool, seen: Option<&str>) -> DeviceFacts {
    DeviceFacts {
        device_id: id.into(),
        name: name.into(),
        system: system.into(),
        this_computer: this,
        connected,
        last_seen_at: seen.map(hk),
    }
}

fn four_computers() -> DevicesFacts {
    DevicesFacts {
        now: now(),
        computers: vec![
            computer("d_1e9c4a70", "Raph’s MacBook Pro", "macOS 26.1", true, true, None),
            computer("d_5b07e2c9", "Raph’s Mac mini", "macOS 15.7", false, true, Some("2026-10-12 14:47")),
            computer("d_93f2d618", "Studio workstation", "Linux", false, false, Some("2026-10-11 18:02")),
            computer("d_c0a47b3e", "Raph’s MacBook Air", "macOS 26.1", false, false, None),
        ],
        ..Default::default()
    }
}

fn you(last: &str) -> PersonFacts {
    let profile = profile_raph();
    PersonFacts {
        conversation_id: "you".into(),
        name: profile.name,
        friends_id: Some(profile.friends_id),
        picture: profile.picture,
        relation: Relation::Friend,
        last_interaction_at: hk(last),
        ..Default::default()
    }
}

#[test]
fn your_computers() {
    if presentation::tree_missing() {
        return;
    }
    let mut builder = builder(audience());
    builder.devices = Some(four_computers());
    expect_fixture(&builder.profile(&profile_raph(), 2), "devices-profile.json", "profile");
    // Within the hour: minutes; this computer cannot remove itself; a removed computer offers nothing.
    let devices = builder.devices.as_mut().unwrap();
    devices.computers.truncate(1);
    devices.computers.push(computer("d_2", "Office iMac", "macOS 26.1", false, false, Some("2026-10-12 14:40")));
    let rows = builder.profile(&profile_raph(), 2)["devices"]["rows"].clone();
    assert_eq!(rows[1]["last_connected"], "7 min ago");
    assert_eq!(rows[1]["accessibility_label"], "Office iMac, macOS 26.1, last connected 7 minutes ago");
    builder.devices.as_mut().unwrap().removed = true;
    let rows = builder.profile(&profile_raph(), 2)["devices"]["rows"].clone();
    assert!(rows[1]["remove"].is_null() && rows[0]["rename"].is_null(), "a removed computer removes nothing");
    builder.devices = None;
    assert!(builder.profile(&profile_raph(), 2).get("devices").is_none(), "without the capability, no devices");
}

#[test]
fn lists_on_several_computers() {
    if presentation::tree_missing() {
        return;
    }
    let mut builder = builder(audience());
    let people = through_store(&presentation::world::people());
    let mut facts = four_computers();
    facts.you = Some(you("2026-10-12 15:02"));
    facts.you_preview = Some(transfer(
        "t_6a2e9f14",
        true,
        "2026-10-12 15:02",
        "Bracket drawing rev C.pdf",
        41_203_776,
        TransferState::Sending,
    ));
    builder.devices = Some(facts);
    let mei_only = vec![people["c_mei"].clone()];
    let mut list = builder.list(&mei_only, &preview_items(), &profile_raph(), "", now());
    list["join_requests"] = serde_json::json!([]);
    expect_fixture(&builder.list_with_devices(list, &mei_only, "", now()), "devices-list.json", "list");
    let all = everyone(&people);
    let filtered = builder.list(&all, &preview_items(), &profile_raph(), "mei", now());
    let filtered = builder.list_with_devices(filtered, &all, "mei", now());
    assert!(filtered["rows"].as_array().unwrap().iter().all(|r| r["conversation_id"] != "you"), "You matches You");

    // Removed: the rows stay to read, no drops, no join rows.
    let mut mei = people["c_mei"].clone();
    mei.route_kind = RouteKind::None;
    mei.route_method = RouteMethod::None;
    let devices = builder.devices.as_mut().unwrap();
    devices.you = None;
    devices.removed = true;
    let mut removed = builder.list(std::slice::from_ref(&mei), &preview_items(), &profile_raph(), "", now());
    removed["join_requests"] = serde_json::json!([{"join_id": "x"}]);
    let built = builder.list_with_devices(removed, &[mei], "", now());
    expect_fixture(&built, "devices-list-removed.json", "list");

    // A new computer: no name yet, nobody in Friends, offered to join.
    builder.devices = Some(DevicesFacts { now: now(), join_offered: true, ..Default::default() });
    let unnamed = szfriends_core::presentation::ProfileFacts { name: None, ..profile_raph() };
    let mut empty = builder.list(&[], &HashMap::new(), &unnamed, "", now());
    empty["join_requests"] = serde_json::json!([]);
    let built = builder.list_with_devices(empty, &[], "", now());
    expect_fixture(&built, "devices-list-new-computer.json", "list");
}

#[test]
fn conversations_on_several_computers() {
    if presentation::tree_missing() {
        return;
    }
    let mut builder = builder(audience());
    let mut facts = four_computers();
    let you = you("2026-10-12 15:02");
    facts.you = Some(you.clone());
    let message = message("m_0c7d31e8", true, "2026-10-12 14:58", "Pages to check: 3–5 and 9.", None);
    let file = transfer(
        "t_6a2e9f14",
        true,
        "2026-10-12 15:02",
        "Bracket drawing rev C.pdf",
        41_203_776,
        TransferState::Queued,
    );
    facts.you_items_everywhere = BTreeSet::from(["m_0c7d31e8".to_owned()]);
    facts.you_copying = BTreeMap::from([("t_6a2e9f14".to_owned(), 0.4)]);
    builder.devices = Some(facts);
    let items = [message, file];
    let built = builder.conversation(&you, &items, false, None, 2, now());
    expect_fixture(&built, "devices-conversation-you.json", "conversation");
    // Once everything is everywhere, the composer says nothing more.
    let devices = builder.devices.as_mut().unwrap();
    devices.you_copying.clear();
    devices.you_items_everywhere.insert("t_6a2e9f14".into());
    let done = builder.conversation(&you, &items, false, None, 2, now());
    assert!(done["composer"]["note"].is_null(), "no note once on every computer");
    assert_eq!(done["items"].as_array().unwrap().last().unwrap()["status_label"], "On all your computers");

    // Files on another computer.
    let received =
        |id: &str, at: &str, name: &str, size: u64| transfer(id, false, at, name, size, TransferState::Received);
    let items = [
        received("t_c81f04d2", "2026-10-12 10:05", "Factory audit photos.pdf", 312_475_648),
        received("t_4d9b7a35", "2026-10-12 10:07", "Line 2 layout.pdf", 58_402_113),
        received("t_e27c6b90", "2026-10-12 10:12", "Supplier quote.pdf", 96_110_592),
    ];
    let on_mini = DeviceFileFacts { device_name: "Raph’s Mac mini".into(), ..Default::default() };
    let copying = DeviceFileFacts {
        device_name: "Raph’s Mac mini".into(),
        fetching: true,
        holder_connected: true,
        fraction: 0.25,
    };
    let away = DeviceFileFacts { device_name: "Studio workstation".into(), fetching: true, ..Default::default() };
    builder.devices.as_mut().unwrap().files = BTreeMap::from([
        ("t_c81f04d2".to_owned(), on_mini),
        ("t_4d9b7a35".to_owned(), copying),
        ("t_e27c6b90".to_owned(), away),
    ]);
    let people = presentation::world::people();
    let built = builder.conversation(&people["c_mei"], &items, false, None, 2, now());
    expect_fixture(&built, "devices-conversation-mei-files.json", "conversation");
}

#[test]
fn history_words_on_several_computers() {
    if presentation::tree_missing() {
        return;
    }
    let mut builder = builder(audience());
    let people = through_store(&presentation::world::people());
    builder.devices = Some(four_computers());
    expect_fixture(&builder.settings(&profile_raph(), &everyone(&people)), "devices-settings.json", "settings");
    expect_fixture(&builder.details(&people["c_mei"], 2, now()), "devices-details-mei.json", "details");
    // One computer: the words of one computer.
    builder.devices.as_mut().unwrap().computers.truncate(1);
    expect_fixture(&builder.settings(&profile_raph(), &everyone(&people)), "settings.json", "settings");
}

/// On a phone or tablet (`files.share`) Settings says "this device" and "all your devices", never "computer": the
/// history note, both confirmations, and the list's Reset banner, with and without AI chat and several devices. The
/// folder has no Change… there, and the automatic-acceptance button says what it shows.
#[test]
fn settings_words_on_a_phone() {
    if presentation::tree_missing() {
        return;
    }
    let people = through_store(&presentation::world::people());
    let profile = ProfileFacts {
        received: ReceivedFolderFacts { phone: Some(PhoneFolder::Downloads), ..ReceivedFolderFacts::default() },
        identity_state: IdentityState::Unavailable,
        ..profile_raph()
    };
    let mut phone = audience();
    phone.app_name = "Shenzhen 3D".into();
    phone.capabilities.insert("files.share".into());
    let mut assistant = phone.clone();
    assistant.capabilities.insert("assistant.chats".into());
    for audience in [phone, assistant] {
        for devices in [None, Some(four_computers())] {
            let mut builder = builder(audience.clone());
            let several = devices.is_some();
            builder.devices = devices;
            let settings = builder.settings(&profile, &everyone(&people));
            validate_snapshot(&settings, "settings", "settings on a phone");
            let note = settings["history"]["note"].as_str().unwrap();
            let body = settings["history"]["confirm"]["body"].as_str().unwrap();
            if several {
                assert!(note.starts_with("Stored on all your devices."), "{note}");
                assert!(body.contains("deleted from this device, and from your other devices"), "{body}");
            } else {
                assert!(note.starts_with("Stored on this device."), "{note}");
                assert!(body.contains("deleted from this device, and anything"), "{body}");
            }
            let reset = settings["reset"]["confirm"]["body"].as_str().unwrap();
            assert!(reset.starts_with("This deletes your friends and conversations from this device "), "{reset}");
            let banner = &builder.list(&everyone(&people), &HashMap::new(), &profile, "", now())["banner"];
            assert_eq!(banner["action"]["confirm"]["body"], settings["reset"]["confirm"]["body"]);
            let assistant = audience.capabilities.contains("assistant.chats");
            assert_eq!(body.contains("AI chat answers"), assistant, "{body}");
            assert_eq!(reset.contains("AI chat answers"), assistant, "{reset}");
            let text = settings.to_string();
            assert!(!text.contains("computer") && !text.contains("Mac"), "{text}");
            assert!(settings["received"]["change"].is_null(), "{settings}");
            assert_eq!(settings["auto_accept"]["action_label"], "Choose friends…");
        }
    }
    // No friends: no switch to show, so views hide the button, and the note says where to turn it on.
    let automatic = &builder(audience()).settings(&profile_raph(), &[])["auto_accept"];
    assert_eq!(automatic["friends"], serde_json::json!([]));
    assert_eq!(automatic["note"], "Turn it on for a friend in their details.");
}

fn online_audience() -> Audience {
    let mut audience = audience();
    audience.helper_capabilities = ["nearby.network", "host.checkin", "online"].iter().map(|s| s.to_string()).collect();
    audience
}

/// The list's people with online routes: Mei direct, Daniel through the relay, Priya while an attempt runs.
fn online_people() -> HashMap<String, PersonFacts> {
    let mut people = through_store(&presentation::world::people());
    people.get_mut("c_mei").unwrap().route_method = RouteMethod::Internet; // kind Local, as the nearby service says
    let daniel = people.get_mut("c_daniel").unwrap();
    daniel.route_kind = RouteKind::Online;
    daniel.route_method = RouteMethod::Relay;
    people.get_mut("c_priya").unwrap().online_reach = OnlineReach::Connecting;
    people
}

fn priya(reach: OnlineReach) -> PersonFacts {
    PersonFacts { online_reach: reach, ..presentation::world::people()["c_priya"].clone() }
}

#[test]
fn online_fixtures() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(online_audience());
    let people = online_people();
    expect_fixture(
        &builder.list(&everyone(&people), &preview_items(), &profile_raph(), "", now()),
        "online-list.json",
        "list",
    );
    let mut kenji = presentation::world::people()["c_kenji"].clone();
    kenji.route_kind = RouteKind::Online;
    kenji.route_method = RouteMethod::Relay;
    let mut items: Vec<ItemFacts> = items_for("c_kenji");
    // Offered over the relay before any rate was measured: the estimate assumes what the relay allows.
    let offer = items.last_mut().unwrap();
    offer.transfer_route = RouteMethod::Relay;
    offer.bytes_per_second = 0.0;
    let built = builder.conversation(&kenji, &items, true, None, 1, now());
    expect_fixture(&built, "online-conversation-kenji-relay.json", "conversation");
    let built = builder.conversation(&priya(OnlineReach::Unreachable), &items_for("c_priya"), false, None, 2, now());
    expect_fixture(&built, "online-conversation-priya-unreachable.json", "conversation");
    let built = builder.conversation(&priya(OnlineReach::Connecting), &items_for("c_priya"), false, None, 2, now());
    expect_fixture(&built, "online-conversation-priya-connecting.json", "conversation");
}

#[test]
fn nothing_online_without_the_capability() {
    if presentation::tree_missing() {
        return;
    }
    // The facts may say Online or Connecting; an M1 helper's words still never do.
    let builder = builder(audience());
    let conversation =
        builder.conversation(&priya(OnlineReach::Connecting), &items_for("c_priya"), false, None, 2, now());
    validate_snapshot(&conversation, "conversation", "m1 connecting");
    let text = conversation.to_string();
    for word in ["Online", "online", "Connecting", "connecting"] {
        assert!(!text.contains(word), "an M1 snapshot says {word}");
    }
    assert_eq!(conversation["header"]["route"]["kind"], "offline");
    let queued = message("m_q", true, "2026-10-12 14:00", "Hi", Some(OutboxState::Queued));
    let online =
        builder_with(online_audience()).conversation(&priya(OnlineReach::Unknown), &[queued], false, None, 0, now());
    assert_eq!(online["items"][1]["status"]["label"], "Sends when Priya is online or nearby");
    assert_eq!(online["header"]["subtitle"], "Not connected right now");
}

fn builder_with(audience: Audience) -> szfriends_core::presentation::SnapshotBuilder {
    builder(audience)
}

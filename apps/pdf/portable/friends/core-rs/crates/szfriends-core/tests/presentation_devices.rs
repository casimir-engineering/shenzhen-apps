//! One profile on several computers and online friends, built from facts (`SZFriendsPresentationDevicesBuildTests.m`,
//! `SZFriendsPresentationOnlineTests.m`): every devices-* and online-* fixture rebuilt as the same JSON value, each
//! validated against PROTOCOL.md, and the states around them. Without devices facts every view stays the one-computer
//! view; a helper that does not announce `online` says nothing of the Internet, whatever the facts hold.

mod presentation;

use std::collections::{BTreeMap, BTreeSet, HashMap};

use presentation::world::*;
use presentation::{expect_fixture, through_store, validate_snapshot};
use serde_json::json;
use szfriends_core::presentation::{
    AgainState, Audience, DeviceFacts, DeviceFileFacts, DevicesFacts, IdentityState, ItemFacts, JoinRequestFacts,
    JoiningFacts, JoiningState, OnlineReach, OutboxState, PersonFacts, ProfileFacts, ReceivedFolderFacts, Relation,
    RouteKind, RouteMethod, TransferState,
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
        friends_id: Some("cottage-violet".into()),
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
    assert!(builder.profile(&profile_raph(), 2)["devices"]["add"].is_null(), "a removed computer adds nothing");
    // A phone among them: the heading says so, and its row reads as a phone.
    let devices = builder.devices.as_mut().unwrap();
    devices.removed = false;
    devices.computers.truncate(1);
    devices.computers.push(computer("d_3", "POCO F7", "Android", false, true, None));
    let section = builder.profile(&profile_raph(), 2)["devices"].clone();
    assert_eq!(section["title"], "Your computers and phones");
    assert_eq!(section["rows"][1]["detail"], "Android phone · Now");
    assert_eq!(section["rows"][1]["accessibility_label"], "POCO F7, Android phone, connected now");
    let asking = JoinRequestFacts {
        join_id: "5f2d".into(),
        device_name: "POCO F7".into(),
        system: "Android".into(),
        ..Default::default()
    };
    let row = builder.join_request_rows(std::slice::from_ref(&asking), now())[0].clone();
    assert_eq!(row["subtitle"], "Android phone · Approve only if you’re setting it up now");
    assert_eq!(row["accessibility_label"], "POCO F7 wants to join your profile, Android phone");
    let approved = JoinRequestFacts {
        approved: true,
        code: Some("48312207".into()),
        code_expires_at: Some(now() + 300.0),
        ..asking
    };
    let row = builder.join_request_rows(&[approved], now())[0].clone();
    assert_eq!(
        (&row["title"], &row["subtitle"]),
        (&json!("Type this code on POCO F7"), &json!("Android phone · Waiting for the code"))
    );
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
    // Named, still nobody: the list keeps offering it.
    let named = builder.list(&[], &HashMap::new(), &profile_raph(), "", now());
    let named = builder.list_with_devices(named, &[], "", now());
    assert_eq!(named["join"]["action"]["action"], "open_join", "offered once named");

    // Friends here already, no name yet: joining replaces them, so it asks first and opens the join view after.
    builder.devices = Some(DevicesFacts {
        now: now(),
        join_replaces: true,
        friends_id: Some("cottage-violet".into()),
        computers: vec![computer("d_1e9c4a70", "Raph’s MacBook Pro", "macOS 26.1", true, true, None)],
        ..Default::default()
    });
    let mut with_mei = builder.list(&mei_only, &preview_items(), &unnamed, "", now());
    with_mei["join_requests"] = serde_json::json!([]);
    let built = builder.list_with_devices(with_mei.clone(), &mei_only, "", now());
    expect_fixture(&built, "devices-list-join-reset.json", "list");
    // Named: only Settings offers it then, so friends' rows are not crowded by it.
    let named = builder.list(&mei_only, &preview_items(), &profile_raph(), "", now());
    assert!(builder.list_with_devices(named, &mei_only, "", now())["join"].is_null(), "not on a named list");
    builder.devices.as_mut().unwrap().removed = true;
    let built = builder.list_with_devices(with_mei, &mei_only, "", now());
    assert!(built["join"].is_null(), "a removed computer starts over first");
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
        route: RouteMethod::Lan,
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

fn moved(id: &str, outgoing: bool, at: &str, name: &str, size: u64, again: AgainState) -> ItemFacts {
    let state = if outgoing { TransferState::Delivered } else { TransferState::Received };
    ItemFacts { file_missing: true, again, ..transfer(id, outgoing, at, name, size, state) }
}

/// Files the person moved or deleted (PROTOCOL.md § Getting a file again): Get again from Mei, copying from her,
/// waiting for her, her answer that she no longer has one, one still on another computer (Get), and one this person
/// sent from another computer, which only says where it went.
#[test]
fn files_moved_or_deleted() {
    if presentation::tree_missing() {
        return;
    }
    let mut again_audience = audience();
    again_audience.capabilities.insert("files.again".into());
    let mut builder = builder(again_audience);
    let mut devices = four_computers();
    let on_mini = DeviceFileFacts { device_name: "Raph’s Mac mini".into(), ..Default::default() };
    devices.files = BTreeMap::from([("t_c4e19b05".to_owned(), on_mini)]);
    builder.devices = Some(devices.clone());
    let mut copying = moved("t_7b3e0f42", false, "2026-10-12 09:20", "Shift rota.pdf", 1_203_456, AgainState::Asked);
    copying.again_connected = true;
    copying.again_fraction = 0.4;
    let items = [
        moved("t_5a90c3e1", false, "2026-10-12 09:12", "Site photos.pdf", 48_231_004, AgainState::None),
        copying,
        moved("t_91c6d2a8", false, "2026-10-12 09:31", "Supplier quote.pdf", 3_604_480, AgainState::Asked),
        moved("t_2f8a4c17", false, "2026-10-12 09:44", "Old floor plan.pdf", 5_100_000, AgainState::Gone),
        moved("t_c4e19b05", false, "2026-10-12 09:50", "Audit checklist.pdf", 860_160, AgainState::None),
        moved("t_e83d5a6c", true, "2026-10-12 10:02", "Quote reply.pdf", 2_200_000, AgainState::None),
    ];
    let mut mei = presentation::world::people()["c_mei"].clone();
    let built = builder.conversation(&mei, &items, false, None, 2, now());
    expect_fixture(&built, "devices-conversation-mei-again.json", "conversation");
    // A host that cannot send Get again is told where the file is, and offered nothing.
    let mut older = builder_with(audience());
    older.devices = Some(devices);
    let plain = &older.conversation(&mei, &items[..1], false, None, 2, now())["items"][1];
    assert_eq!(plain["state"], "missing", "no Get again: {plain}");
    assert_eq!(plain["actions"], serde_json::json!([]), "no Get again: {plain}");
    // Nor is anyone who is not a friend now: their file stays moved or deleted.
    mei.relation = Relation::Removed;
    let removed = &builder.conversation(&mei, &items[..1], false, None, 2, now())["items"][1];
    assert_eq!(removed["state"], "missing", "removed: {removed}");
    assert_eq!(removed["actions"], serde_json::json!([]), "removed: {removed}");
}

/// A file copying here from another of the person's computers shows the route it comes by, the conversation header's
/// route object (same words, same icon); a slow route with a time to tell adds it as any transfer's route_note.
#[test]
fn copying_routes() {
    if presentation::tree_missing() {
        return;
    }
    let mut builder = builder(audience());
    let item =
        transfer("t_4d9b7a35", false, "2026-10-12 10:07", "Line 2 layout.pdf", 58_402_113, TransferState::Received);
    let mei = presentation::world::people()["c_mei"].clone();
    let mut built = |connected: bool, route: RouteMethod| {
        let copying = DeviceFileFacts {
            device_name: "Raph’s Mac mini".into(),
            fetching: true,
            holder_connected: connected,
            fraction: 0.25,
            route,
        };
        let mut devices = four_computers();
        devices.files = BTreeMap::from([("t_4d9b7a35".to_owned(), copying)]);
        builder.devices = Some(devices);
        let conversation = builder.conversation(&mei, std::slice::from_ref(&item), false, None, 2, now());
        validate_snapshot(&conversation, "conversation", "a file copying from another computer");
        conversation["items"].as_array().unwrap().last().unwrap().clone()
    };
    let bluetooth = built(true, RouteMethod::Bluetooth);
    assert_eq!(bluetooth["route"], json!({"kind": "local", "method": "bluetooth", "label": "Nearby, over Bluetooth"}));
    assert_eq!(bluetooth["status_label"], "Copying from Raph’s Mac mini · 25%");
    assert!(bluetooth["route_note"].is_null(), "no time to tell over Bluetooth: {bluetooth}");
    let relay = built(true, RouteMethod::Relay);
    let label = "Online, through the Friends relay";
    assert_eq!(relay["route"], json!({"kind": "online", "method": "relay", "label": label}));
    assert!(relay["route_note"].as_str().unwrap().starts_with("Through the Friends relay, about "), "{relay}");
    let direct = built(true, RouteMethod::Internet);
    assert_eq!(direct["route"]["label"], "Online, direct");
    assert!(direct["route_note"].is_null(), "{direct}");
    let away = built(false, RouteMethod::None);
    assert!(away.get("route").is_none() && away["route_note"].is_null(), "no route while away: {away}");
    // A file coming again from a friend: the friend's route is the header's; a slow one adds its note.
    let mut again_audience = audience();
    again_audience.capabilities.insert("files.again".into());
    let mut again = builder_with(again_audience);
    again.devices = Some(four_computers());
    let mut coming = moved("t_7b3e0f42", false, "2026-10-12 09:20", "Shift rota.pdf", 1_203_456, AgainState::Asked);
    coming.again_connected = true;
    coming.again_fraction = 0.4;
    coming.transfer_route = RouteMethod::Bluetooth;
    let slow =
        again.conversation(&mei, &[coming], false, None, 2, now())["items"].as_array().unwrap().last().unwrap().clone();
    assert_eq!(slow["route_note"], "Over Bluetooth");
    assert!(slow.get("route").is_none(), "{slow}");
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
    assert!(builder.settings(&profile_raph(), &everyone(&people)).get("join").is_none(), "no other profile");
    // One computer: the words of one computer.
    builder.devices.as_mut().unwrap().computers.truncate(1);
    expect_fixture(&builder.settings(&profile_raph(), &everyone(&people)), "settings.json", "settings");
    // One computer with friends: Settings offers the person's existing profile, after Reset.
    builder.devices.as_mut().unwrap().join_replaces = true;
    let built = builder.settings(&profile_raph(), &everyone(&people));
    expect_fixture(&built, "devices-settings-join.json", "settings");
    let mut chats = audience();
    chats.capabilities.insert("assistant.chats".into());
    let mut assistant = builder_with(chats);
    assistant.devices = builder.devices.clone();
    let body = assistant.settings(&profile_raph(), &everyone(&people))["join"]["action"]["confirm"]["body"].clone();
    assert!(body.as_str().unwrap().contains("AI chat answers"), "{body}");
}

/// On a phone the offer and Your computers say "this device" where a computer says "this computer".
#[test]
fn joining_words_on_a_phone() {
    if presentation::tree_missing() {
        return;
    }
    let people = through_store(&presentation::world::people());
    let mut builder = builder(phone_audience());
    let mut facts = four_computers();
    facts.computers.truncate(1);
    facts.join_replaces = true;
    builder.devices = Some(facts);
    let profile = ProfileFacts {
        received: ReceivedFolderFacts { phone: Some(PhoneFolder::Downloads), ..ReceivedFolderFacts::default() },
        ..profile_raph()
    };
    expect_fixture(&builder.settings(&profile, &everyone(&people)), "phone-settings-join.json", "settings");
    let devices = builder.profile(&profile, 0)["devices"].clone();
    assert_eq!(devices["title"], "Your devices");
    assert_eq!(devices["rows"][0]["last_connected"], "This device");
    let approve = devices["add"]["steps"][2].as_str().unwrap();
    assert!(approve.contains("the code this device shows"), "{approve}");
    let join = builder.join(&JoiningFacts { state: JoiningState::Idle, friends_id: None, ..Default::default() });
    assert!(join["message"].as_str().unwrap().ends_with("You’ll approve this device there."), "{join}");
    let joined = builder.join(&JoiningFacts { state: JoiningState::Joined, friends_id: None, ..Default::default() });
    assert_eq!(joined["title"], "This device now uses your profile");
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
    let phone = phone_audience();
    // The golden phone Settings: Android's Downloads, friends to choose from, one device.
    let built = builder(phone.clone())
        .settings(&ProfileFacts { received: profile.received.clone(), ..profile_raph() }, &everyone(&people));
    expect_fixture(&built, "phone-settings.json", "settings");
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

/// Shenzhen 3D on a phone: the Tauri host adds `files.share` there.
fn phone_audience() -> Audience {
    let mut phone = audience();
    phone.app_name = "Shenzhen 3D".into();
    phone.capabilities.insert("files.share".into());
    phone
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

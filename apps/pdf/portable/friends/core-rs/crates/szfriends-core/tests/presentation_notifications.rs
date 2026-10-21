//! System notifications' words (ADR 0017, `SZFriendsCatalogNotifications.m`): a request's title and body for each
//! kind, previews off, bursts and batches; Settings' Notifications block for each permission and host; the list's ask
//! card. Every snapshot is validated against PROTOCOL.md's schema blocks.

mod presentation;

use std::collections::HashMap;

use presentation::world::*;
use presentation::items::preview_items;
use presentation::{expect_fixture, expect_no_missing_keys, through_store, validate_snapshot};
use serde_json::json;
use szfriends_core::presentation::{NotificationFacts, NotifyPermission, PeopleNotice, ProfileFacts};

fn with_notifications(facts: NotificationFacts) -> ProfileFacts {
    ProfileFacts { notifications: Some(facts), ..profile_raph() }
}

fn notifying(extra: &[&str]) -> szfriends_core::presentation::Audience {
    let mut audience = audience();
    audience.helper_capabilities.insert("notifications".into());
    audience.capabilities.extend(extra.iter().map(|c| c.to_string()));
    audience
}

#[test]
fn every_kind_is_worded_from_the_catalog() {
    if presentation::tree_missing() {
        return;
    }
    let people = people();
    let mei = &people["c_mei"];
    let b = builder(notifying(&[]));
    let words = b.notify_messages(mei, &["Can you check the bracket?"], true);
    assert_eq!((words.title.as_str(), words.body.as_str()), ("Mei Lin", "Can you check the bracket?"));
    assert_eq!(b.notify_messages(mei, &["one", "two", "three"], true).body, "three", "the newest of a burst");
    assert_eq!(b.notify_messages(mei, &["secret"], false).body, "New message");
    assert_eq!(b.notify_messages(mei, &["a", "b", "c"], false).body, "3 new messages");
    assert_eq!(b.notify_files(mei, &["Bracket.step"], false, true).body, "Mei Lin wants to send you Bracket.step");
    assert_eq!(
        b.notify_files(mei, &["Bracket.step", "b", "c"], true, true).body,
        "Mei Lin sent Bracket.step and 2 more files"
    );
    assert_eq!(
        b.notify_files(mei, &["Bracket.step", "b"], false, true).body,
        "Mei Lin wants to send you Bracket.step and 1 more file"
    );
    assert_eq!(b.notify_files(mei, &["Bracket.step"], true, false).body, "Mei Lin sent a file");
    assert_eq!(b.notify_files(mei, &["a", "b"], false, false).body, "Mei Lin wants to send you 2 files");
    assert_eq!(b.notify_people(mei, PeopleNotice::Request).body, "Wants to be friends");
    assert_eq!(b.notify_people(mei, PeopleNotice::Accepted).body, "Accepted your friend request");
    assert_eq!(b.notify_people(mei, PeopleNotice::LinkUsed).body, "Used your friend link, so you’re now friends");
    assert_eq!(b.notify_people(mei, PeopleNotice::LinkAdded).body, "You’re now friends");
    let join = b.notify_join("Pixel 8");
    assert_eq!(join.title, "Pixel 8 wants to join your profile");
    assert_eq!(join.body, "Approve it in Friends only if you’re setting it up now.");
    let reply = b.notify_reply(mei);
    assert_eq!(
        (reply.label.as_str(), reply.placeholder.as_str(), reply.send.as_str()),
        ("Reply", "Message Mei Lin", "Send")
    );
    let long = "word ".repeat(200);
    assert!(b.notify_messages(mei, &[&long], true).body.ends_with('…'), "long text is cut");
    expect_no_missing_keys("notifications");
}

#[test]
fn settings_say_what_the_system_allows_on_this_device() {
    if presentation::tree_missing() {
        return;
    }
    let people = everyone(&people());
    let settings = |audience, facts: NotificationFacts| {
        let data = builder(audience).settings(&with_notifications(facts), &people);
        validate_snapshot(&data, "settings", "settings with notifications");
        data["notifications"].clone()
    };
    let granted = settings(notifying(&[]), NotificationFacts::default());
    assert_eq!(
        granted,
        json!({
            "label": "Notifications",
            "enabled": {"label": "Show notifications", "value": true},
            "preview": {"label": "Show message text", "value": true,
                        "note": "When this is off, notifications say who sent something, not what it says."},
            "note": "",
            "action": null,
        })
    );
    let asked =
        settings(notifying(&[]), NotificationFacts { permission: NotifyPermission::NotAsked, ..Default::default() });
    assert_eq!(asked["action"], json!({"action": "allow_notifications", "label": "Allow", "style": "secondary"}));
    let mac =
        settings(notifying(&[]), NotificationFacts { permission: NotifyPermission::Denied, ..Default::default() });
    assert_eq!(mac["note"], "Notifications from Shenzhen Friends are off in System Settings.");
    assert_eq!(
        mac["action"],
        json!({"action": "open_settings", "label": "Open System Settings", "style": "secondary",
               "settings_target": "notifications"})
    );
    let phone = settings(
        notifying(&["files.share", "background.reachable"]),
        NotificationFacts { permission: NotifyPermission::Denied, background: true, ..Default::default() },
    );
    assert_eq!(phone["note"], "Notifications from ShenzhenPDF are off in Settings.");
    assert_eq!(phone["action"]["label"], "Open Settings");
    assert_eq!(phone["background"]["value"], true);
    assert_eq!(phone["background"]["label"], "Stay reachable in the background");
    let windows = settings(
        notifying(&[]),
        NotificationFacts { permission: NotifyPermission::Denied, windows: true, ..Default::default() },
    );
    assert_eq!(windows["note"], "Notifications from Shenzhen Friends are off in Windows Settings.");
    assert_eq!(windows["action"]["label"], "Open Settings");
    let linux =
        settings(notifying(&[]), NotificationFacts { permission: NotifyPermission::Unavailable, ..Default::default() });
    assert!(linux["note"].as_str().unwrap().starts_with("This computer has no notification service"));
    let iphone = settings(
        notifying(&["files.share"]),
        NotificationFacts { permission: NotifyPermission::Granted, ios: true, ..Default::default() },
    );
    assert!(iphone["note"]
        .as_str()
        .unwrap()
        .starts_with("An iPhone gets messages and files only while ShenzhenPDF is open"));
    // A helper that does not post shows no block.
    let quiet = builder(audience()).settings(&with_notifications(NotificationFacts::default()), &people);
    assert!(quiet.get("notifications").is_none());
    expect_no_missing_keys("notification settings");
}

#[test]
fn the_ask_card_shows_once_friends_was_used_until_not_now() {
    if presentation::tree_missing() {
        return;
    }
    let people = everyone(&people());
    let not_asked = NotificationFacts { permission: NotifyPermission::NotAsked, activated: true, ..Default::default() };
    let banner = |audience, facts| {
        let data = builder(audience).list(&people, &HashMap::new(), &with_notifications(facts), "", now());
        validate_snapshot(&data, "list", "list with the ask card");
        data["banner"].clone()
    };
    let card = banner(notifying(&["notifications.ask"]), not_asked);
    assert_eq!(card["kind"], "notifications");
    assert_eq!(card["dismiss"]["kind"], "notifications");
    assert!(banner(notifying(&[]), not_asked).is_null(), "only hosts that show the card");
    assert!(banner(notifying(&["notifications.ask"]), NotificationFacts { activated: false, ..not_asked }).is_null());
    assert!(banner(notifying(&["notifications.ask"]), NotificationFacts { ask_dismissed: true, ..not_asked }).is_null());
    assert!(banner(notifying(&["notifications.ask"]), NotificationFacts { enabled: false, ..not_asked }).is_null());
    let granted = NotificationFacts { permission: NotifyPermission::Granted, ..not_asked };
    assert!(banner(notifying(&["notifications.ask"]), granted).is_null());
}

/// The shared goldens the views render (and SZFriendsPresentationNotificationsTests.m rebuilds): the list with the ask
/// card, and Settings on a Mac whose system settings turned Friends' notifications off, message text hidden.
#[test]
fn the_shared_fixtures() {
    if presentation::tree_missing() {
        return;
    }
    let people = through_store(&presentation::world::people());
    let all = everyone(&people);
    let not_asked = NotificationFacts { permission: NotifyPermission::NotAsked, activated: true, ..Default::default() };
    let b = builder(notifying(&["notifications.focus", "notifications.ask"]));
    let list = b.list(&all, &preview_items(), &with_notifications(not_asked), "", now());
    expect_fixture(&list, "views-notifications-list.json", "list");
    let denied =
        NotificationFacts { permission: NotifyPermission::Denied, preview: false, activated: true, ..Default::default() };
    expect_fixture(&b.settings(&with_notifications(denied), &all), "views-notifications-settings.json", "settings");
}

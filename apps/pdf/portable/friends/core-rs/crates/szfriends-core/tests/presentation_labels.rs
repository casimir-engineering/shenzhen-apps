//! The catalog and the words built from it (`SZFriendsPresentationLabelTests.m`): the Rust catalog is the helper's own
//! entry for entry (read from the Objective-C sources), times around midnight and across years in Hong Kong's clock,
//! sizes at unit boundaries, estimates, countdowns, badges, routes, spoken fragments, names, every reply error message,
//! and the welcome's static strings.

mod presentation;

use std::collections::BTreeMap;

use presentation::world::{audience, hk, now};
use serde_json::{json, Map, Value};
use szfriends_core::presentation::catalog;
use szfriends_core::presentation::time::TimeZone;
use szfriends_core::presentation::{RouteKind, RouteMethod, Strings};

fn strings() -> Strings {
    Strings::new(audience())
}

/// The `@"key" : @"value" @"more"` entries of an Objective-C dictionary literal, comments skipped.
fn objc_entries(source: &str) -> Vec<(String, String)> {
    let mut entries = Vec::new();
    let mut strings: Vec<String> = Vec::new();
    let mut key: Option<String> = None;
    let mut chars = source.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '/' if chars.peek() == Some(&'/') => {
                for c in chars.by_ref() {
                    if c == '\n' {
                        break;
                    }
                }
            }
            '@' if chars.peek() == Some(&'"') => {
                chars.next();
                let mut text = String::new();
                while let Some(c) = chars.next() {
                    match c {
                        '"' => break,
                        '\\' => match chars.next() {
                            Some('u') => {
                                let hex: String = chars.by_ref().take(4).collect();
                                text.push(char::from_u32(u32::from_str_radix(&hex, 16).unwrap()).unwrap());
                            }
                            Some('n') => text.push('\n'),
                            Some(other) => text.push(other),
                            None => {}
                        },
                        _ => text.push(c),
                    }
                }
                strings.push(text);
            }
            ':' if !strings.is_empty() => key = Some(strings.drain(..).collect()),
            ',' | '}' => {
                if let Some(k) = key.take() {
                    entries.push((k, strings.drain(..).collect()));
                }
                strings.clear();
            }
            _ => {}
        }
    }
    entries
}

#[test]
fn the_catalog_is_the_helpers() {
    if presentation::tree_missing() {
        return;
    }
    let directory = presentation::friends_dir().join("service/presentation");
    let mut objc: BTreeMap<String, String> = BTreeMap::new();
    for file in [
        "SZFriendsCatalog.m",
        "SZFriendsCatalogViews.m",
        "SZFriendsCatalogMentions.m",
        "SZFriendsCatalogLinks.m",
        "SZFriendsCatalogJoin.m",
        "SZFriendsCatalogDevices.m",
    ] {
        let source = std::fs::read_to_string(directory.join(file)).unwrap();
        // Only the dictionary literals: from the first "return @{" on.
        let body = &source[source.find("return @{").unwrap()..];
        for (key, value) in objc_entries(body) {
            assert!(objc.insert(key.clone(), value).is_none(), "{key} twice in the helper's catalog");
        }
    }
    let rust: BTreeMap<String, String> = catalog::entries().map(|(k, v)| (k.to_owned(), v.to_owned())).collect();
    assert_eq!(rust.len(), catalog::entries().count(), "a key twice in the Rust catalog");
    // Every difference at once, so a change to the helper's catalog is ported in one pass.
    let mut differences = Vec::new();
    for (key, value) in &objc {
        match rust.get(key) {
            Some(ours) if ours == value => {}
            Some(ours) => differences.push(format!("{key}\n  helper: {value}\n  rust:   {ours}")),
            None => differences.push(format!("{key}\n  helper: {value}\n  rust:   (missing)")),
        }
    }
    // Words only the portable helper says: no Mac has a Windows firewall (ADR 0015 § 15).
    const PORTABLE_ONLY: &[&str] = &[
        "nearby_inbound_blocked",
        "visibility.unavailable.firewall",
        "visibility.unavailable.access.phone",
        "alert.network_denied.body.phone",
        "id.nearby",
    ];
    for key in rust.keys().filter(|key| !objc.contains_key(*key) && !PORTABLE_ONLY.contains(&key.as_str())) {
        differences.push(format!("{key} is not in the helper's catalog"));
    }
    assert!(differences.is_empty(), "{} differences:\n{}", differences.len(), differences.join("\n"));
    assert!(objc.len() > 600, "the helper's catalog did not parse: {} entries", objc.len());
}

#[test]
fn times() {
    let s = strings();
    let now = now(); // Monday 12 October 2026, 14:47:48 in Hong Kong
    let cases = [
        ("2026-10-12 00:05", "00:05"),
        ("2026-10-11 23:59", "Yesterday"),
        ("2026-10-10 09:00", "Saturday"),
        ("2026-10-06 09:00", "Tuesday"),
        ("2026-10-05 09:00", "5 Oct"),
        ("2025-12-31 23:00", "31 Dec 2025"),
        ("2026-10-13 09:00", "13 Oct"),
    ];
    for (at, expected) in cases {
        assert_eq!(s.time_label(hk(at), now), expected, "{at}");
    }
    // 16:30 UTC on the 11th is 00:30 on the 12th in Hong Kong: today there, yesterday in UTC.
    let utc = hk("2026-10-12 00:30");
    assert_eq!(s.time_label(utc, now), "00:30");
    let in_utc = Strings::new(szfriends_core::presentation::Audience { time_zone: TimeZone::utc(), ..audience() });
    assert_eq!(in_utc.time_label(utc, now), "Yesterday");
    assert_eq!(s.day_item_id(utc), "d_20261012");
    assert_eq!(s.time_accessibility_label(hk("2026-10-12 14:40"), now), "14:40");
    assert_eq!(s.time_accessibility_label(hk("2026-10-11 09:00"), now), "yesterday");
    assert_eq!(s.time_accessibility_label(hk("2026-10-03 09:00"), now), "3 October");
    assert_eq!(s.time_accessibility_label(hk("2025-12-31 09:00"), now), "31 December 2025");
    assert_eq!(s.day_label(hk("2026-10-12 01:00"), now), "Today");
    assert_eq!(s.day_accessibility_label(hk("2026-09-30 01:00"), now), "30 September");
    assert_eq!(s.moment_phrase(hk("2026-10-12 14:40"), now), "today at 14:40");
    assert_eq!(s.moment_phrase(hk("2026-10-11 09:05"), now), "yesterday at 09:05");
    assert_eq!(s.moment_phrase(hk("2026-10-10 10:00"), now), "Saturday at 10:00");
    assert_eq!(s.moment_phrase(hk("2026-10-02 08:00"), now), "2 Oct at 08:00");
    assert_eq!(s.moment_accessibility_phrase(hk("2026-10-02 16:20"), now), "2 October at 16:20");
    assert_eq!(s.day_phrase(hk("2026-10-12 08:00"), now), "today");
    assert_eq!(s.day_phrase(hk("2026-10-10 08:00"), now), "on Saturday");
    assert_eq!(s.day_phrase(hk("2026-10-03 08:00"), now), "on 3 Oct");
}

#[test]
fn sizes_durations_and_estimates() {
    let s = strings();
    let sizes: [(u64, &str); 17] = [
        (0, "0 bytes"),
        (1, "1 byte"),
        (999, "999 bytes"),
        (1000, "1 KB"),
        (1499, "1 KB"),
        (999_499, "999 KB"),
        (999_500, "1 MB"),
        (2_000_000, "2 MB"),
        (2_431_029, "2.4 MB"),
        (18_604_277, "18.6 MB"),
        (99_940_000, "99.9 MB"),
        (99_960_000, "100 MB"),
        (120_000_000, "120 MB"),
        (999_600_000, "1 GB"),
        (1_210_000_000, "1.2 GB"),
        (5_000_000_000_000, "5 TB"),
        (5_000_000_000_000_000, "5000 TB"),
    ];
    for (bytes, expected) in sizes {
        assert_eq!(s.size_label(bytes), expected, "{bytes}");
    }
    let durations = [
        (0.0, "about 5 s", "about 5 seconds"),
        (20.2, "about 20 s", "about 20 seconds"),
        (57.0, "about 55 s", "about 55 seconds"),
        (58.0, "about 1 min", "about 1 minute"),
        (361.7, "about 6 min", "about 6 minutes"),
        (3599.0, "about 1 h", "about 1 hour"),
        (4800.0, "about 1 h 20 min", "about 1 hour 20 minutes"),
        (7200.0, "about 2 h", "about 2 hours"),
    ];
    for (seconds, shown, spoken) in durations {
        assert_eq!(s.duration_label(seconds), shown);
        assert_eq!(s.duration_accessibility_label(seconds), spoken);
    }
    assert_eq!(s.countdown_label(252.0), "4:12");
    assert_eq!(s.countdown_accessibility_label(252.0), "4 minutes 12 seconds left");
    assert_eq!(s.countdown_label(251.2), "4:12"); // rounds up: never 0:00 while still visible
    assert_eq!(s.countdown_accessibility_label(60.0), "1 minute left");
    assert_eq!(s.countdown_accessibility_label(61.0), "1 minute 1 second left");
    assert_eq!(s.countdown_label(1.0), "0:01");
    assert_eq!(s.countdown_accessibility_label(1.0), "1 second left");
    assert_eq!(s.countdown_label(-5.0), "0:00");
    assert_eq!(s.transfer_estimate(42_318_806, 117_000.0, RouteMethod::Lan), None, "no estimate on a fast route");
    assert_eq!(s.transfer_estimate(1, 1.0, RouteMethod::PeerToPeerWifi), None);
    assert_eq!(
        s.transfer_estimate(42_318_806, 117_000.0, RouteMethod::Bluetooth).unwrap(),
        "Over Bluetooth, about 6 min"
    );
    assert_eq!(s.transfer_estimate(42_318_806, 0.0, RouteMethod::Bluetooth).unwrap(), "Over Bluetooth");
    assert_eq!(
        s.transfer_estimate(18_000_000, 100_000.0, RouteMethod::Relay).unwrap(),
        "Through the Friends relay, about 3 min"
    );
    assert_eq!(
        s.transfer_estimate_accessibility(18_000_000, 100_000.0, RouteMethod::Relay).unwrap(),
        "through the Friends relay, about 3 minutes"
    );
}

#[test]
fn small_words() {
    let s = strings();
    assert_eq!([s.badge_label(0), s.badge_label(1), s.badge_label(99), s.badge_label(100)], ["", "1", "99", "99+"]);
    let routes = [
        (RouteKind::Local, RouteMethod::Lan, "Nearby, on your network"),
        (RouteKind::Local, RouteMethod::PeerToPeerWifi, "Nearby, over direct Wi-Fi"),
        (RouteKind::Local, RouteMethod::Bluetooth, "Nearby, over Bluetooth"),
        (RouteKind::Local, RouteMethod::None, "Nearby"),
        (RouteKind::Online, RouteMethod::Internet, "Online, direct"),
        (RouteKind::Online, RouteMethod::None, "Online"),
        (RouteKind::Online, RouteMethod::Relay, "Online, through the Friends relay"),
        (RouteKind::Offline, RouteMethod::None, "Not nearby right now"),
        (RouteKind::None, RouteMethod::None, ""),
    ];
    for (kind, method, expected) in routes {
        assert_eq!(s.route_label(kind, method), expected);
    }
    assert_eq!(s.spoken_fragment("Nearby, over direct Wi-Fi"), "nearby, over direct Wi-Fi");
    assert_eq!(s.spoken_fragment("ID cottage-violet"), "ID cottage-violet");
    assert_eq!(s.spoken_fragment("PDF"), "PDF");
    let chinese = Strings::new(szfriends_core::presentation::Audience { locale: "zh-Hans".into(), ..audience() });
    assert_eq!(chinese.spoken_fragment("Nearby"), "Nearby"); // no case outside English
    assert_eq!(s.first_name(Some("Mei Lin"), Some("jasmine-street")), "Mei");
    assert_eq!(s.first_name(Some("  Tomás  Rivera "), None), "Tomás");
    assert_eq!(s.first_name(Some("李美"), None), "李美");
    assert_eq!(s.first_name(Some("   "), Some("tulip-canyon")), "tulip\u{2011}canyon"); // never split
    assert_eq!(s.display_id(Some("cedar-amber-falcon")), "cedar\u{2011}amber\u{2011}falcon");
    assert_eq!(s.display_id(None), "");
    assert_eq!(s.first_name(None, None), "Someone");
    let list = |items: &[&str]| s.joined_list(&items.iter().map(|i| i.to_string()).collect::<Vec<_>>());
    assert_eq!(
        [list(&[]), list(&["A"]), list(&["A", "B"]), list(&["A", "B", "C"])],
        ["", "A", "A and B", "A, B and C"]
    );
    assert_eq!(s.kind_label("a.pdf", None), "PDF");
    assert_eq!(s.kind_label("notes.MD", None), "Markdown");
    assert_eq!(s.kind_label("x.weird", None), "WEIRD");
    assert_eq!(s.kind_label("noextension", None), "File");
    assert_eq!(s.grouped_comparison_code("418270"), "418 270");
    assert_eq!(s.spoken_comparison_code("418270"), "Comparison code 4 1 8, 2 7 0");
    assert_eq!(s.grouped_comparison_code("12345"), "12345");
}

#[test]
fn static_strings() {
    let s = strings();
    let strings = s.static_strings();
    assert_eq!(strings.len(), 31);
    let welcome = presentation::fixture("frames/welcome.json");
    let built: Map<String, Value> = strings.iter().map(|(k, v)| (k.clone(), json!(v))).collect();
    assert_eq!(Value::Object(built), welcome["strings"], "welcome.strings");
    // The views fill only the drag strings and the link warning, and hosts the queued note; {apps} reaches nobody.
    let filled: BTreeMap<&str, &[&str]> = BTreeMap::from([
        ("drop_send_many", &["{count}"][..]),
        ("drop_send_file", &["{name}"][..]),
        ("drop_send_file_and_more", &["{name}", "{count}"][..]),
        ("link_elsewhere", &["{host}", "{shown}"][..]),
        ("queued_note", &["{first}"][..]),
    ]);
    for (key, text) in &strings {
        let mut rest = text.clone();
        for placeholder in filled.get(key.as_str()).copied().unwrap_or(&[]) {
            assert!(rest.contains(placeholder), "static {key} lacks {placeholder}");
            rest = rest.replace(placeholder, "");
        }
        assert!(!rest.contains('{'), "static {key} has a placeholder the views do not fill");
    }
    let files =
        Strings::new(szfriends_core::presentation::Audience { app_name: "Shenzhen Files".into(), ..audience() });
    assert_eq!(
        files.static_strings()["queued_note"],
        "Messages and files send when {first} is nearby with ShenzhenPDF, Shenzhen Files or Shenzhen 3D open."
    );
}

#[test]
fn error_messages() {
    let s = strings();
    for code in [
        "bad_frame",
        "frame_too_large",
        "hello_required",
        "protocol_unsupported",
        "unknown_intent",
        "too_many_subscriptions",
        "not_ready",
        "connection_lost",
    ] {
        assert_eq!(s.error_message(code, &Map::new()), None, "{code} is silent");
    }
    let details = json!({"path": "/Users/raph/Desktop/Report.pdf", "name": "Mei Lin", "max": 100,
                         "retry_after_seconds": 30, "needed_bytes": 5_000_000});
    let details = details.as_object().unwrap();
    for code in [
        "not_found",
        "not_allowed",
        "rate_limited",
        "identity_unavailable",
        "name_invalid",
        "id_invalid",
        "id_is_yours",
        "already_friends",
        "blocked",
        "not_friends",
        "file_missing",
        "folder_not_supported",
        "too_many_files",
        "source_changed",
        "disk_full",
        "picture_invalid",
        "scope_invalid",
        "stale",
        "internal",
    ] {
        for d in [&Map::new(), details] {
            let message = s.error_message(code, d).unwrap();
            assert!(!message.is_empty() && !message.contains('{'), "{code}: {message}");
        }
    }
    let message = |code: &str| s.error_message(code, details).unwrap();
    assert_eq!(message("folder_not_supported"), "Folders can’t be sent yet.");
    assert_eq!(message("rate_limited"), "Too many at once. Try again in 30 seconds.");
    assert_eq!(message("too_many_files"), "You can send up to 100 files at once. Nothing was sent.");
    assert_eq!(message("file_missing"), "Report.pdf can’t be found or opened. Nothing was sent.");
    assert_eq!(
        message("disk_full"),
        "There isn’t enough space on this computer to send Report.pdf. Free up some space, then try again."
    );
    assert_eq!(message("already_friends"), "Mei Lin is already your friend.");
    let field = |name: &str| json!({"field": name}).as_object().unwrap().clone();
    assert_eq!(
        s.error_message("invalid_field", &field("text")).unwrap(),
        "This message is too long. Split it into shorter messages."
    );
    assert_eq!(s.error_message("invalid_field", &field("subscription")), None, "a view's own bad field");
    assert_eq!(
        s.error_message("a_code_from_the_future", &Map::new()).unwrap(),
        "Something went wrong in Friends. Try again."
    );
    // The reply fixture's disk_full, with the offer the helper names for the sentence.
    let error = &presentation::fixture("frames/reply-error.json")["error"];
    let mut details = error["details"].as_object().unwrap().clone();
    details.insert("file_name".into(), json!("Site photos.pdf"));
    assert_eq!(json!(s.error_message("disk_full", &details)), error["message"]);
}

#[test]
fn catalog_lookup() {
    let s = strings();
    assert_eq!(s.text("test.no_such_key"), "test.no_such_key"); // shown as itself, and recorded
    assert!(catalog::missing_keys().contains("test.no_such_key"));
    assert_eq!(s.text_with("id.label", &[("id", "a-b")]), "ID a-b");
    assert_eq!(s.text_count("size.bytes", 1, &[]), "1 byte");
    assert_eq!(s.text_count("size.bytes", 2, &[]), "2 bytes");
}

/// A friend may have any app that runs Friends open, Shenzhen 3D among them, so a string that says which apps names
/// them through {apps}, never by hand: a list written into one string falls behind when another app starts hosting.
#[test]
fn apps_with_friends() {
    let s = strings();
    assert_eq!(s.text("apps.with_friends"), "ShenzhenPDF, Shenzhen Files or Shenzhen 3D");
    for (key, value) in catalog::entries().filter(|(key, _)| *key != "apps.with_friends") {
        for name in ["ShenzhenPDF", "Shenzhen Files", "Shenzhen 3D"] {
            assert!(!value.contains(name), "{key} names {name} itself instead of saying {{apps}}");
        }
    }
    // Filled without the caller passing it, wherever a string says it.
    assert_eq!(
        s.text_with("join.waiting.message", &[("id", "cottage-violet")]),
        "On a computer that uses cottage-violet, open Friends in ShenzhenPDF, Shenzhen Files or Shenzhen 3D and \
         choose Approve. Then type the code it shows."
    );
    assert_eq!(
        s.text("join.not_reached"),
        "Your other computer didn’t answer. Open ShenzhenPDF, Shenzhen Files or Shenzhen 3D there, and type the code \
         again."
    );
    assert_eq!(
        s.text("error.link_offline"),
        "The computer this file comes from isn’t online right now. It can send the file while ShenzhenPDF, Shenzhen \
         Files or Shenzhen 3D is open there."
    );
    assert_eq!(
        s.text_with("link.made", &[("date", "19 October")]),
        "Download link copied. It works until 19 October, whenever this computer is on with ShenzhenPDF, Shenzhen \
         Files or Shenzhen 3D open."
    );
}

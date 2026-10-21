//! Linux notifications against a real notification daemon (dunst) on a private session bus: a friend's message
//! reaches the daemon through the helper's `Notify`, a click (`dunstctl action`, the daemon's `ActionInvoked`) opens
//! the conversation with the app last used, and reading the conversation closes what is shown. Run inside
//! `dbus-run-session` and a display with dunst started, and SZFRIENDS_TEST_NOTIFICATION_DAEMON=1:
//!
//!   dbus-run-session -- xvfb-run -a sh -c 'dunst & sleep 1; SZFRIENDS_TEST_NOTIFICATION_DAEMON=1 \
//!       cargo test -p szfriends-helper --test linux_daemon'
#![cfg(target_os = "linux")]

mod clients;
mod support;

use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use clients::{Client, Temp};
use serde_json::json;
use szfriends_helper::notify::freedesktop::FreedesktopNotifier;
use szfriends_helper::notify::{Notifier, Permission, Responder};
use szfriends_helper::presentation::Presentation;
use szfriends_helper::service::{seed, Service, ENV_TEST_LOOPBACK};
use szfriends_helper::state::ENV_STATE_DIR;

fn dunstctl(arguments: &[&str]) -> String {
    let output = std::process::Command::new("dunstctl").args(arguments).output().expect("dunstctl");
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

fn until(what: &str, check: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(30);
    while !check() {
        assert!(Instant::now() < deadline, "no {what}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn send_text(client: &mut Client, conversation: &str, text: &str, token: &str) {
    client.send("send_message", json!({"conversation_id": conversation, "text": text, "client_token": token}));
}

fn displayed() -> usize {
    dunstctl(&["count", "displayed"]).parse().unwrap_or(0)
}

#[test]
fn a_message_reaches_the_daemon_and_a_click_opens_the_conversation() {
    if std::env::var_os("SZFRIENDS_TEST_NOTIFICATION_DAEMON").is_none() {
        eprintln!("skipped: needs a notification daemon on the session bus");
        return;
    }
    let (a, b, net) = (Temp::new("da"), Temp::new("db"), Temp::new("dnet"));
    std::env::set_var(ENV_STATE_DIR, &a.0);
    std::env::set_var(ENV_TEST_LOOPBACK, &net.0);
    let (bo_in_a, ada_in_b) = seed::befriend(&a.0, &b.0, ("Ada", "Bo")).expect("befriended");
    // The app last used: a script standing in for Shenzhen 3D, which writes down the URL it is opened with.
    let opened = b.0.join("opened.txt");
    let app = b.0.join("open-app.sh");
    std::fs::write(&app, format!("#!/bin/sh\necho \"$1\" > '{}'\n", opened.display())).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&app, std::fs::Permissions::from_mode(0o755)).unwrap();
    let target = json!({"url_scheme": "shenzhen3d", "app_id": "com.shenzhen3d.viewer", "app_name": "Shenzhen 3D",
                        "app_path": app});
    std::fs::write(b.0.join("notify-target"), target.to_string()).unwrap();

    let mut ada = Client::connect(&a.0);
    let service = Service::start(&b.0, seed::test_key_store(&b.0)).expect("Bo's service");
    let feed = service.clone();
    let responder: Responder = Arc::new(move |response| feed.notification_response(response));
    let notifier = Arc::new(FreedesktopNotifier::start(&b.0, responder));
    service.install_notifier(notifier.clone());
    let presentation: Arc<dyn Presentation> = service.clone();
    let server = Client::server(presentation.clone());
    let mut bo = Client::join(&server, presentation, &["notifications.focus"]);
    for client in [&mut ada, &mut bo] {
        client.send("activate", json!({}));
    }
    until("the daemon on the bus", || notifier.permission() == Permission::NotNeeded);
    let settings = bo.subscribe("settings", json!({}));
    bo.snapshot(&settings, "nothing to say about the daemon", |d| d["notifications"]["note"] == "");

    // Ada's message reaches the daemon as Bo's notification.
    send_text(&mut ada, &bo_in_a, "Can you check the bracket?", "0123456789abcdef0123456789abcdef");
    until("the notification shown", || displayed() == 1);
    // A click: the daemon's ActionInvoked comes back, and the app last used opens on the conversation.
    dunstctl(&["action", "0"]);
    until("the app opened", || std::fs::read_to_string(&opened).is_ok_and(|t| !t.is_empty()));
    let url = std::fs::read_to_string(&opened).unwrap();
    assert_eq!(url.trim(), format!("shenzhen3d://friends/conversation/{ada_in_b}"));

    // Read in an app: what is shown goes.
    send_text(&mut ada, &bo_in_a, "One more thing", "fedcba9876543210fedcba9876543210");
    until("the second notification shown", || displayed() == 1);
    bo.send("open_conversation", json!({"conversation_id": ada_in_b}));
    until("the notification closed after reading", || displayed() == 0);
    assert!(!Path::new(&b.0.join("notifications.jsonl")).exists(), "the daemon, not the sink, had them");
}

//! The Friends service end to end: two helpers' services in test homes, made friends, reaching each other over the
//! test network on 127.0.0.1, each driven by a client through the protocol server. A message both ways with the
//! outbox's states, and a file offered, accepted, received whole and acknowledged; then each deletes history.

mod clients;
mod support;

use std::path::Path;

use clients::{exchange, texts, Client, Temp};
use serde_json::{json, Value};
use szfriends_core::store::ENV_DOWNLOADS_DIR;
use szfriends_helper::service::{seed, ENV_TEST_LOOPBACK};
use szfriends_helper::state::{StateDir, ENV_STATE_DIR};

/// The environment is the process's: each test's services start with its own test network, one test at a time.
static START: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[test]
fn two_helpers_exchange_messages_and_a_file_over_the_test_network() {
    let (a, b, routes) = (Temp::new("a"), Temp::new("b"), Temp::new("routes"));
    let guard = START.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var(ENV_STATE_DIR, &a.0);
    std::env::set_var(ENV_TEST_LOOPBACK, &routes.0);
    let (bo_in_a, ada_in_b) = seed::befriend(&a.0, &b.0, ("Ada", "Bo")).expect("befriended");
    let mut ada = Client::connect(&a.0);
    let mut bo = Client::connect(&b.0);
    drop(guard);
    // Opening Friends starts Nearby (in a test home: the test network only).
    ada.send("activate", json!({}));
    bo.send("activate", json!({}));
    exchange(&a.0, &b.0, &mut ada, &mut bo, (&bo_in_a, &ada_in_b), 300_000);

    // Delete chat history on a computer of its own: gone there, kept by the friend, who stays a friend.
    let kept = found(&b.0, "Gearbox.stl").expect("the received file in Bo's home");
    assert_eq!(kept.parent(), Some(b.0.join("Downloads").as_path()), "Downloads inside a test home");
    bo.send("delete_history", json!({"conversation_id": ada_in_b}));
    let chat = bo.send("open_conversation", json!({"conversation_id": ada_in_b}))["subscription"].clone();
    bo.snapshot(chat.as_str().unwrap(), "Bo's chat with Ada emptied", |d| {
        d["items"].as_array().is_some_and(|items| items.is_empty())
    });
    assert!(kept.exists(), "received files stay");
    let chat = ada.send("open_conversation", json!({"conversation_id": bo_in_a}))["subscription"].clone();
    ada.snapshot(chat.as_str().unwrap(), "Ada keeps hers", |d| texts(d).contains("Hi Ada, Bo here"));
    // Every chat at once.
    ada.send("delete_history", json!({}));
    ada.snapshot(chat.as_str().unwrap(), "Ada's chat emptied", |d| d["items"].as_array().is_some_and(Vec::is_empty));
    assert_eq!(bo.refused("delete_history", json!({"conversation_id": "c_unknown"})), "not_found");
}

#[test]
fn your_computers_and_joining_show_this_computers_real_state() {
    let (home, routes) = (Temp::new("devices"), Temp::new("devices-routes"));
    let guard = START.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var(ENV_STATE_DIR, &home.0);
    std::env::set_var(ENV_TEST_LOOPBACK, &routes.0);
    let mut client = Client::connect(&home.0);
    drop(guard);
    let list = client.send("subscribe", json!({"view": "list"}))["subscription"].as_str().unwrap().to_owned();
    let shown = client.snapshot(&list, "the list with devices", |d| d["state"] == "normal");
    assert_eq!(shown["data"]["join_requests"], json!([]), "no computer asked to join");
    let join = client.send("subscribe", json!({"view": "join"}))["subscription"].as_str().unwrap().to_owned();
    client.snapshot(&join, "the join view", |d| d.is_object());
    client.send("rename_device", json!({"name": "Workshop PC"}));
    let profile = client.send("subscribe", json!({"view": "profile"}))["subscription"].as_str().unwrap().to_owned();
    client
        .snapshot(&profile, "this computer named in Your computers", |d| texts(&d["devices"]).contains("Workshop PC"));
    client.send("join_profile", json!({"friends_id": "amber-falcon"}));
    client.snapshot(&join, "joining waits for the code", |d| d["state"] == "waiting");
    client.send("cancel_join", json!({}));
    client.snapshot(&join, "joining cancelled", |d| d["state"] != "waiting");
}

/// Ada sends Bo `name` holding `content`; Bo accepts; the path it was published at.
fn send_file(a: &Path, ada: &mut Client, bo: &mut Client, chats: (&str, &str), name: &str, content: &[u8]) -> String {
    let (bo_in_a, bo_chat) = chats;
    let source = a.join("outgoing").join(name);
    std::fs::create_dir_all(source.parent().unwrap()).unwrap();
    std::fs::write(&source, content).unwrap();
    let mut token = [0u8; 16];
    szfriends_crypto::random_bytes(&mut token);
    let token: String = token.iter().map(|b| format!("{b:02x}")).collect();
    let files = json!({"conversation_id": bo_in_a, "files": [{"path": source}], "client_token": token});
    let transfer = ada.send("send_files", files)["transfer_ids"][0].as_str().unwrap().to_owned();
    let offered = |d: &Value| {
        d["items"].as_array().is_some_and(|items| {
            items.iter().any(|i| i["transfer_id"] == transfer.as_str() && texts(i).contains("accept_offer"))
        })
    };
    bo.snapshot(bo_chat, "the offer at Bo", offered);
    bo.send("accept_offer", json!({"transfer_id": transfer}));
    let received = |d: &Value| {
        d["items"].as_array().and_then(|items| {
            let item = items.iter().find(|i| i["transfer_id"] == transfer.as_str())?;
            open_or_show(item)
        })
    };
    let shown = bo.snapshot(bo_chat, "the file received", |d| received(d).is_some());
    received(&shown["data"]).unwrap()
}

/// The path a received item's Open or Share/Show action names.
fn open_or_show(value: &Value) -> Option<String> {
    match value {
        Value::Object(map) if matches!(map.get("action").and_then(Value::as_str), Some("open_file" | "show_file")) => {
            map.get("path").and_then(Value::as_str).map(str::to_owned)
        }
        Value::Object(map) => map.values().find_map(open_or_show),
        Value::Array(list) => list.iter().find_map(open_or_show),
        _ => None,
    }
}

/// The status a received item at `path` shows in the chat `chat`, once it shows `status`.
fn expect_status(bo: &mut Client, chat: &str, path: &str, status: &str) {
    let saved = |d: &Value| {
        d["items"].as_array().is_some_and(|items| {
            items.iter().any(|i| open_or_show(i).as_deref() == Some(path) && i["status_label"] == status)
        })
    };
    bo.snapshot(chat, &format!("{path} saying {status}"), saved);
}

/// Received files go to Downloads (here the test's, `$SZFRIENDS_DOWNLOADS_DIR`), never replace one another, are
/// listed in the `received` view, and go to the folder the person chooses in Settings once they choose one. Each says
/// where it was saved; when the folder cannot take one, Downloads does and Settings says so until the next good save.
#[test]
fn received_files_go_to_downloads_or_the_folder_the_person_chose() {
    let (a, b, routes, chosen) = (Temp::new("ra"), Temp::new("rb"), Temp::new("rroutes"), Temp::new("chosen"));
    let downloads = b.0.join("Test Downloads");
    let guard = START.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var(ENV_STATE_DIR, &a.0);
    std::env::set_var(ENV_TEST_LOOPBACK, &routes.0);
    // Without $SZFRIENDS_DOWNLOADS_DIR a test home keeps received files inside itself.
    let defaults = StateDir::new(a.0.clone()).received_defaults();
    assert_eq!(defaults.folder, Some(a.0.join("Downloads")));
    std::env::set_var(ENV_DOWNLOADS_DIR, &downloads);
    let (bo_in_a, ada_in_b) = seed::befriend(&a.0, &b.0, ("Ada", "Bo")).expect("befriended");
    let mut ada = Client::connect(&a.0);
    let mut bo = Client::connect(&b.0);
    assert_eq!(StateDir::new(b.0.clone()).received_defaults().folder, Some(downloads.clone()));
    std::env::remove_var(ENV_DOWNLOADS_DIR);
    drop(guard);
    assert!(bo.welcome["capabilities"].as_array().unwrap().iter().any(|c| c == "received.folder"));
    ada.send("activate", json!({}));
    bo.send("activate", json!({}));

    let settings = bo.subscribe("settings", json!({}));
    let shown = bo.snapshot(&settings, "Downloads in Settings", |d| d["received"]["value"] == "Downloads");
    let row = &shown["data"]["received"];
    assert_eq!(row["label"], "Save received files to");
    assert_eq!(row["path"], downloads.to_string_lossy().as_ref());
    assert_eq!(row["change"]["action"], "choose_received_folder");
    let received = bo.subscribe("received", json!({}));
    bo.snapshot(&received, "nothing received yet", |d| d["files"] == json!([]));

    let bo_chat =
        bo.send("open_conversation", json!({"conversation_id": ada_in_b}))["subscription"].as_str().unwrap().to_owned();
    let chats = (bo_in_a.as_str(), bo_chat.as_str());
    let first = send_file(&a.0, &mut ada, &mut bo, chats, "Bracket.step", b"solid one");
    assert_eq!(Path::new(&first), downloads.join("Bracket.step"));
    assert_eq!(std::fs::read(&first).unwrap(), b"solid one");
    expect_status(&mut bo, &bo_chat, &first, "Saved to Downloads");
    let second = send_file(&a.0, &mut ada, &mut bo, chats, "Bracket.step", b"solid two");
    assert_eq!(Path::new(&second), downloads.join("Bracket (2).step"));
    assert_eq!(std::fs::read(&first).unwrap(), b"solid one", "never replaced");
    let listed = bo.snapshot(&received, "both files listed", |d| d["files"].as_array().is_some_and(|f| f.len() == 2));
    let files = listed["data"]["files"].as_array().unwrap();
    let names: Vec<&str> = files.iter().map(|f| f["file_name"].as_str().unwrap()).collect();
    assert!(names.contains(&"Bracket.step") && names.contains(&"Bracket (2).step"), "{names:?}");
    assert!(files.iter().all(|f| f["source"] == "friend" && f["received_at"].as_i64().is_some()));
    assert!(files[0]["received_at"].as_i64() >= files[1]["received_at"].as_i64(), "newest first");

    // Settings ▸ Change…: refused for what is not a usable folder, then the folder chosen.
    assert_eq!(bo.refused("set_received_folder", json!({"path": "relative"})), "invalid_field");
    let missing = chosen.0.join("missing");
    assert_eq!(bo.refused("set_received_folder", json!({"path": missing})), "file_missing");
    assert_eq!(bo.refused("set_received_folder", json!({"path": b.0})), "not_allowed", "the Friends home");
    bo.send("set_received_folder", json!({"path": chosen.0}));
    let real = std::fs::canonicalize(&chosen.0).unwrap();
    let name = real.file_name().unwrap().to_string_lossy().into_owned();
    let shown = bo.snapshot(&settings, "the chosen folder in Settings", |d| d["received"]["value"] == name.as_str());
    assert_eq!(shown["data"]["received"]["path"], real.to_string_lossy().as_ref());
    let third = send_file(&a.0, &mut ada, &mut bo, chats, "Bracket.step", b"solid three");
    assert_eq!(Path::new(&third), real.join("Bracket.step"));
    expect_status(&mut bo, &bo_chat, &third, &format!("Saved to {name}"));
    bo.snapshot(&received, "three files listed", |d| d["files"].as_array().is_some_and(|f| f.len() == 3));
    assert_eq!(bo.snapshot(&settings, "no note", |_| true)["data"]["received"]["note"], "");

    // The chosen folder cannot take the next file (read-only, as a refusal by the system would be): Downloads does,
    // the item says so, and Settings says why until a file is saved in the chosen folder again.
    let note = "The last file couldn’t be saved here, so it went to Downloads.";
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o500)).unwrap();
        let fourth = send_file(&a.0, &mut ada, &mut bo, chats, "Fallback.pdf", b"one");
        std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(Path::new(&fourth), downloads.join("Fallback.pdf"));
        expect_status(&mut bo, &bo_chat, &fourth, "Saved to Downloads");
        bo.snapshot(&settings, "the fallback note", |d| d["received"]["note"] == note);
        let fifth = send_file(&a.0, &mut ada, &mut bo, chats, "Back.pdf", b"two");
        assert_eq!(Path::new(&fifth), real.join("Back.pdf"));
        bo.snapshot(&settings, "the note cleared by a good save", |d| d["received"]["note"] == "");
    }
    // The folder is gone: Downloads again, and the note until the folder is changed.
    std::fs::remove_dir_all(&real).unwrap();
    let sixth = send_file(&a.0, &mut ada, &mut bo, chats, "Gone.pdf", b"three");
    assert_eq!(Path::new(&sixth), downloads.join("Gone.pdf"));
    expect_status(&mut bo, &bo_chat, &sixth, "Saved to Downloads");
    bo.snapshot(&settings, "the fallback note again", |d| d["received"]["note"] == note);

    // Choosing Downloads again is the default again, and clears the note.
    bo.send("set_received_folder", json!({"path": downloads}));
    bo.snapshot(&settings, "Downloads again", |d| d["received"]["value"] == "Downloads" && d["received"]["note"] == "");
}

/// The first file named `name` under `dir`.
fn found(dir: &std::path::Path, name: &str) -> Option<std::path::PathBuf> {
    for entry in std::fs::read_dir(dir).ok()?.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if let Some(hit) = found(&path, name) {
                return Some(hit);
            }
        } else if path.file_name().is_some_and(|n| n == name) {
            return Some(path);
        }
    }
    None
}

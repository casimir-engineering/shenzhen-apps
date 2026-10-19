//! The Friends service online: two helpers' services in test homes, made friends, with no route but the local Node
//! host and its coturn at the 5 Mbit/s cap (`szfriends_interop::host`), all on loopback. Each checks in, publishes
//! where it can be found, and reaches the other when it has something to send: first directly, then with direct
//! candidates refused in both homes so only the relay carries them. A message both ways and a file each time. Then
//! one person's two computers, joined nearby, started again with no nearby route: names given on one reach the
//! other over the session online carries between them. And a download link the Rust helper serves, opened by the
//! Objective-C helper's own opener (`$SZFRIENDS_OBJC_PEER`): downloaded whole, refused as changed once the file
//! changed, and as ended once revoked. And Add by ID with no nearby route: the request reaches the ID's holder through
//! the host, and the holder's acceptance calls the requester back online with its token. And a new computer joining a
//! profile with no nearby route: its request and its code through the host (`to.join`), a wrong code first. And
//! links between two Rust helpers (`online_links/mod.rs`): a friend link opened and added, accepted at once by its
//! maker, then reset; a download link received into the opener's chat.
//! `make friends-core-rs-online-check` sets `SZFRIENDS_HOST_SERVER_DIR` and `FRIENDS_TEST_COTURN`; without them the
//! test says what is missing and passes.
#![cfg(feature = "online")]

mod clients;
mod online_links;
mod support;

use clients::{exchange, join_profile, texts, Client, Temp};
use serde_json::json;
use szfriends_helper::service::{seed, BLOCK_DIRECT_FILE, ENV_TEST_HOST_KEYS, ENV_TEST_HOST_LIST, ENV_TEST_LOOPBACK};
use szfriends_helper::state::ENV_STATE_DIR;
use szfriends_interop::host::{self, LocalHost};
use szfriends_interop::{wait_for, ObjcPeer, Peer};

fn pair(label: &str, relayed: bool) {
    let (a, b) = (Temp::new(&format!("{label}-a")), Temp::new(&format!("{label}-b")));
    std::env::set_var(ENV_STATE_DIR, &a.0);
    let (bo_in_a, ada_in_b) = seed::befriend(&a.0, &b.0, ("Ada", "Bo")).expect("befriended");
    if relayed {
        std::fs::write(a.0.join(BLOCK_DIRECT_FILE), b"").unwrap();
        std::fs::write(b.0.join(BLOCK_DIRECT_FILE), b"").unwrap();
    }
    let mut ada = Client::connect(&a.0);
    let mut bo = Client::connect(&b.0);
    exchange(&a.0, &b.0, &mut ada, &mut bo, (&bo_in_a, &ada_in_b), 400_000);
}

/// The environment is the process's: one test's helpers at a time.
static ONLINE: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// The local host and its coturn, named to the helpers started from now on; None (with why) when it cannot run.
fn local_host() -> Option<(LocalHost, Temp)> {
    let Some(server) = host::server_dir() else {
        eprintln!("SZFRIENDS_HOST_SERVER_DIR is not set: make friends-core-rs-online-check sets it");
        return None;
    };
    if let Some(why) = host::unavailable(&server, true) {
        eprintln!("skipped: {why}");
        return None;
    }
    let dir = Temp::new("online-host");
    let host = LocalHost::start(&server, &dir.0, true);
    std::env::set_var(ENV_TEST_HOST_LIST, &host.list_path);
    std::env::set_var(ENV_TEST_HOST_KEYS, &host.keys_path);
    std::env::remove_var(ENV_TEST_LOOPBACK);
    Some((host, dir))
}

#[test]
fn links_between_two_rust_helpers() {
    let _guard = ONLINE.lock().unwrap_or_else(|e| e.into_inner());
    let Some((host, _dir)) = local_host() else { return };
    online_links::friend_link();
    online_links::receive_link();
    drop(host);
}

#[test]
fn two_helpers_reach_each_other_online_directly_and_through_the_relay() {
    let _guard = ONLINE.lock().unwrap_or_else(|e| e.into_inner());
    let Some((host, dir)) = local_host() else { return };
    pair("direct", false);
    pair("relayed", true);
    own_devices();
    removed_while_away();
    add_by_id();
    join_through_the_host(&dir.0);
    download_link(&host);
    drop(host);
}

/// Joined over a test network, then started again without one: only online carries their sync.
fn own_devices() {
    let (a, b, network) = (Temp::new("own-a"), Temp::new("own-b"), Temp::new("own-net"));
    std::env::set_var(ENV_STATE_DIR, &a.0);
    std::env::set_var(ENV_TEST_LOOPBACK, &network.0);
    {
        let mut ada = Client::connect(&a.0);
        let mut bo = Client::connect(&b.0);
        ada.send("set_name", json!({"name": "Ada"}));
        for client in [&mut ada, &mut bo] {
            client.send("activate", json!({}));
        }
        let profile = ada.subscribe("profile", json!({}));
        let id = ada.snapshot(&profile, "the profile", |d| d["id"]["friends_id"].is_string())["data"]["id"]
            ["friends_id"]
            .as_str()
            .unwrap()
            .to_owned();
        join_profile(&mut ada, &id, &mut bo);
    }
    std::env::remove_var(ENV_TEST_LOOPBACK);
    let mut ada = Client::connect(&a.0);
    let mut bo = Client::connect(&b.0);
    bo.send("rename_device", json!({"name": "Workshop PC"}));
    let profile_a = ada.subscribe("profile", json!({}));
    // A reach made before the other computer checked in waits out its backoff (30 seconds) before the next.
    let wait = std::time::Duration::from_secs(75);
    ada.snapshot_within(&profile_a, "the other computer's name, online", wait, |d| texts(d).contains("Workshop PC"));
    ada.send("set_name", json!({"name": "Ada Lovelace"}));
    let profile_b = bo.subscribe("profile", json!({}));
    bo.snapshot(&profile_b, "the new name on the other computer, online", |d| texts(d).contains("Ada Lovelace"));
}

/// Joined through the host, the second computer away while the first removes it: the first checks in again with the
/// chain that removed it, and when the removed one comes back the host turns it away, so it knows.
fn removed_while_away() {
    let (a, b) = (Temp::new("gone-a"), Temp::new("gone-b"));
    std::env::set_var(ENV_STATE_DIR, &a.0);
    std::env::remove_var(ENV_TEST_LOOPBACK);
    let mut ada = Client::connect(&a.0);
    {
        let mut bo = Client::connect(&b.0);
        ada.send("set_name", json!({"name": "Ada"}));
        let profile = ada.subscribe("profile", json!({}));
        let data = ada.snapshot(&profile, "a reserved Friends ID", |d| d["id"]["state"] == "reserved");
        let id = data["data"]["id"]["friends_id"].as_str().unwrap().to_owned();
        let bo_profile = bo.subscribe("profile", json!({}));
        bo.snapshot(&bo_profile, "the new computer online", |d| d["id"]["state"] == "reserved");
        join_profile(&mut ada, &id, &mut bo);
    }
    let profile = ada.subscribe("profile", json!({}));
    let other = |d: &serde_json::Value| {
        d["devices"]["rows"].as_array().and_then(|rows| rows.iter().find(|r| r["this_computer"] == false).cloned())
    };
    let listed = ada.snapshot(&profile, "the second computer listed", |d| other(d).is_some());
    let device = other(&listed["data"]).unwrap()["device_id"].clone();
    ada.send("revoke_device", json!({"device_id": device}));
    // The first computer's new check-in brings the chain that removed the second one to the host.
    std::thread::sleep(std::time::Duration::from_secs(3));
    let mut bo = Client::connect(&b.0);
    let list = bo.subscribe("list", json!({}));
    let wait = std::time::Duration::from_secs(60);
    bo.snapshot_within(&list, "told by the host it was removed", wait, |d| d["state"] == "device_removed");
}

/// make_download_link once the helper is online, a download, a changed file, a revoked link.
fn download_link(host: &LocalHost) {
    let Some(binary) = ObjcPeer::binary() else {
        eprintln!("SZFRIENDS_OBJC_PEER is not set: the download link check needs the helper's opener");
        return;
    };
    let (home, opener_home, files) = (Temp::new("link-a"), Temp::new("link-o"), Temp::new("link-files"));
    std::env::set_var(ENV_STATE_DIR, &home.0);
    let path = files.0.join("Site photos.pdf");
    let content: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
    std::fs::write(&path, &content).unwrap();
    let mut ada = Client::connect(&home.0);
    let file = json!({"file": {"path": path.to_string_lossy()}, "expires_days": 7});
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    let made = loop {
        let reply = ada.request("make_download_link", file.clone());
        if reply["ok"] == true {
            break reply["result"].clone();
        }
        assert!(std::time::Instant::now() < deadline, "never online: {reply}");
        std::thread::sleep(std::time::Duration::from_millis(300));
    };
    let url = made["url"].as_str().unwrap();
    assert!(url.starts_with("http://127.0.0.1:") && url.contains("/d#"), "{url}");
    assert!(made["message"].as_str().unwrap().starts_with("Download link copied."), "{made}");
    let fragment = url.split_once("/d#").unwrap().1;
    let payload = szfriends_online::b64::decode_url(fragment, 49).unwrap();
    let (link_id, secret) = (hex::encode(&payload[1..17]), hex::encode(&payload[17..49]));
    let mut opener = ObjcPeer::start(&binary, &opener_home.0, "Opener");
    let reply = opener.command(json!({
        "cmd": "online", "list": host.list_path, "keys": host.keys_path, "friends": [],
        "presence_secret": hex::encode([7u8; 32]), "block_direct": false, "home": opener_home.0,
    }));
    assert!(reply.get("error").is_none(), "online: {reply}");
    let mut seen = Vec::new();
    let step = std::time::Duration::from_secs(60);
    wait_for(&mut opener, &mut seen, step, "the opener online", |e| e["event"] == "online" && e["available"] == true);
    let open = |opener: &mut ObjcPeer, seen: &mut Vec<serde_json::Value>| {
        let opened = opener.command(json!({ "cmd": "open_link", "link_id": link_id, "secret": secret }));
        assert!(opened.get("error").is_none(), "open_link: {opened}");
        wait_for(opener, seen, step, "the link's outcome", |e| e["event"] == "link_downloaded")
    };
    let done = open(&mut opener, &mut seen);
    assert_eq!(done["outcome"], 0, "downloaded whole: {done}");
    assert_eq!(done["size"], content.len());
    let profile = ada.subscribe("profile", json!({}));
    drop(profile);
    // Changed after the link was made: refused before any connection.
    std::fs::write(&path, b"another file").unwrap();
    assert_eq!(open(&mut opener, &mut seen)["outcome"], 3, "changed");
    std::fs::write(&path, &content).unwrap();
    ada.send("revoke_link", json!({ "link_id": made["link_id"] }));
    // The tombstone travels on the sender's connection, the open on the opener's: let it arrive first.
    std::thread::sleep(std::time::Duration::from_secs(1));
    let ended = open(&mut opener, &mut seen);
    assert_eq!(ended["outcome"], 2, "revoked: {ended}");
    let again = ada.request("revoke_link", json!({ "link_id": made["link_id"] }));
    assert_eq!(again["error"]["code"], "not_found");
}

/// Two strangers, no test network: Friends IDs reserved by the host, a request by ID through it, the callback online.
fn add_by_id() {
    let (a, b) = (Temp::new("byid-a"), Temp::new("byid-b"));
    std::env::set_var(ENV_STATE_DIR, &a.0);
    let mut cleo = Client::connect(&a.0);
    let mut dan = Client::connect(&b.0);
    cleo.send("set_name", json!({"name": "Cleo"}));
    dan.send("set_name", json!({"name": "Dan"}));
    let reserved = |client: &mut Client| {
        let profile = client.subscribe("profile", json!({}));
        let data = client.snapshot(&profile, "a reserved Friends ID", |d| d["id"]["state"] == "reserved");
        data["data"]["id"]["friends_id"].as_str().unwrap().to_owned()
    };
    let (cleo_id, dan_id) = (reserved(&mut cleo), reserved(&mut dan));
    assert_ne!(cleo_id, dan_id);
    let sent = cleo.send("add_by_id", json!({"friends_id": dan_id}));
    let dan_in_c = sent["conversation_id"].as_str().unwrap().to_owned();
    let list_d = dan.subscribe("list", json!({}));
    let rows = |d: &serde_json::Value| d["rows"].as_array().cloned().unwrap_or_default();
    let waiting = |d: &serde_json::Value| rows(d).into_iter().find(|r| r["waiting"]["kind"] == "request");
    let asked = dan.snapshot(&list_d, "Cleo's request by ID, through the host", |d| waiting(d).is_some());
    let cleo_in_d = waiting(&asked["data"]).unwrap()["conversation_id"].as_str().unwrap().to_owned();
    dan.send("accept_request", json!({"conversation_id": cleo_in_d}));
    // Dan's helper calls Cleo back online with her token and shows the host's attestation of his ID: a friend at once.
    let list_c = cleo.subscribe("list", json!({}));
    let wait = std::time::Duration::from_secs(75);
    let answered = cleo.snapshot_within(&list_c, "Dan a friend at Cleo, online", wait, |d| {
        rows(d)
            .iter()
            .any(|r| r["conversation_id"] == dan_in_c.as_str() && r["waiting"].is_null() && r["title"] == "Dan")
    });
    let row = rows(&answered["data"]).into_iter().find(|r| r["conversation_id"] == dan_in_c.as_str()).unwrap();
    assert!(!row["actions"].to_string().contains("accept"), "no request to accept: {row}");
    exchange_texts(&mut cleo, &dan_in_c, &mut dan, &cleo_in_d);
}

fn exchange_texts(a: &mut Client, a_conversation: &str, b: &mut Client, b_conversation: &str) {
    let chat_b = b.send("open_conversation", json!({"conversation_id": b_conversation}))["subscription"].to_string();
    let token = "0123456789abcdef0123456789abcdef";
    a.send("send_message", json!({"conversation_id": a_conversation, "text": "Hello by ID", "client_token": token}));
    let wait = std::time::Duration::from_secs(75);
    b.snapshot_within(chat_b.trim_matches('"'), "the message, online", wait, |d| d.to_string().contains("Hello by ID"));
}

/// A new computer joins a profile through the host alone, then the two sync over online.
fn join_through_the_host(host_dir: &std::path::Path) {
    let before = host::events(host_dir, "release").iter().filter(|e| e["result"] == "released").count();
    let (a, b) = (Temp::new("join-a"), Temp::new("join-b"));
    std::env::set_var(ENV_STATE_DIR, &a.0);
    std::env::remove_var(ENV_TEST_LOOPBACK);
    let mut ada = Client::connect(&a.0);
    let mut bo = Client::connect(&b.0);
    ada.send("set_name", json!({"name": "Ada"}));
    let profile = ada.subscribe("profile", json!({}));
    let data = ada.snapshot(&profile, "a reserved Friends ID", |d| d["id"]["state"] == "reserved");
    let id = data["data"]["id"]["friends_id"].as_str().unwrap().to_owned();
    let bo_profile = bo.subscribe("profile", json!({}));
    bo.snapshot(&bo_profile, "the new computer online", |d| d["id"]["state"] == "reserved");
    join_profile(&mut ada, &id, &mut bo);
    let joined = bo.snapshot(&bo_profile, "the profile's ID", |d| d["id"]["friends_id"] == id.as_str());
    assert_eq!(joined["data"]["id"]["friends_id"], id.as_str());
    // The ID the new computer reserved for itself before joining: released, which the host confirmed.
    let owed = || {
        let flags = rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY;
        let store = rusqlite::Connection::open_with_flags(b.0.join(szfriends_core::store::DATABASE_NAME), flags);
        let value = szfriends_core::store::sync_log::state(&store.unwrap(), "checkin_release_pre_join").unwrap();
        value != rusqlite::types::Value::Null
    };
    let released = || host::events(host_dir, "release").iter().filter(|e| e["result"] == "released").count() > before;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while (owed() || !released()) && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
    assert!(released(), "the host released an ID");
    assert!(!owed(), "the new computer knows its ID from before joining was released");
}

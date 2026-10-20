//! Reset Friends at the Friends host, with the local Node host (`szfriends_interop::host`, no relay) on loopback:
//! the old identity is released there before the store goes, so its Friends ID is free for someone else at once; and
//! with the host gone, the reset goes ahead anyway, within the release's time limit. `SZFRIENDS_HOST_SERVER_DIR`
//! names `server/friends` (with its node_modules); without it the test says what is missing and passes.
#![cfg(feature = "online")]

mod clients;
mod support;

use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use clients::{Client, Temp};
use serde_json::json;
use szfriends_core::store::{ReceivedDefaults, Store};
use szfriends_helper::service::reset::{KeyStores, Resettable};
use szfriends_helper::service::{seed, ENV_TEST_HOST_KEYS, ENV_TEST_HOST_LIST, ENV_TEST_LOOPBACK};
use szfriends_helper::state::ENV_STATE_DIR;
use szfriends_interop::host::{self, LocalHost};

/// A helper for `home` that Reset Friends can replace, and a page connected to it.
fn helper(home: &Path) -> (Arc<Resettable>, szfriends_helper::server::Server, Client) {
    let key_home = home.to_path_buf();
    let keys: KeyStores = Arc::new(move || seed::test_key_store(&key_home));
    let helper = Resettable::start(home.to_path_buf(), keys, ReceivedDefaults::contained(home));
    let server = Client::server(helper.clone());
    let client = Client::join(&server, helper.clone(), &[]);
    (helper, server, client)
}

/// The Friends ID the profile shows once `state` (reserved or not) and `matches`.
fn shown_id(client: &mut Client, what: &str, matches: impl Fn(&serde_json::Value) -> bool) -> String {
    let profile = client.subscribe("profile", json!({}));
    let wait = Duration::from_secs(30);
    let data = client.snapshot_within(&profile, what, wait, |d| d["id"]["friends_id"].is_string() && matches(d));
    data["data"]["id"]["friends_id"].as_str().unwrap().to_owned()
}

/// Reset Friends on `client`'s page: the reply, then goodbye `reset`; how long it took.
fn reset(client: &mut Client) -> Duration {
    let begun = Instant::now();
    client.send("reset_friends", json!({"confirm": "reset"}));
    let goodbye = client.wait("goodbye", |f| f["type"] == "goodbye");
    assert_eq!(goodbye["reason"], "reset");
    begun.elapsed()
}

#[test]
fn reset_friends_frees_the_old_id_at_the_host_and_goes_ahead_offline() {
    let Some(server) = host::server_dir() else {
        eprintln!("SZFRIENDS_HOST_SERVER_DIR is not set: it names server/friends with its node_modules");
        return;
    };
    if let Some(why) = host::unavailable(&server, false) {
        eprintln!("skipped: {why}");
        return;
    }
    let dir = Temp::new("reset-host");
    let local = LocalHost::start(&server, &dir.0, false);
    std::env::set_var(ENV_TEST_HOST_LIST, &local.list_path);
    std::env::set_var(ENV_TEST_HOST_KEYS, &local.keys_path);
    std::env::remove_var(ENV_TEST_LOOPBACK);
    let (a, c, b) = (Temp::new("reset-ada"), Temp::new("reset-cleo"), Temp::new("reset-bo"));
    std::env::set_var(ENV_STATE_DIR, &a.0);

    // Ada's ID, reserved at the host, then Reset Friends: the host confirms the release.
    let (ada_helper, ada_server, mut ada) = helper(&a.0);
    let old = shown_id(&mut ada, "Ada's ID reserved", |d| d["id"]["state"] == "reserved");
    reset(&mut ada);
    let released = host::events(&dir.0, "release");
    assert!(released.iter().any(|e| e["result"] == "released"), "the host released it: {released:?}");
    let mut again = Client::join(&ada_server, ada_helper.clone(), &[]);
    let new = shown_id(&mut again, "Ada's new ID", |_| true);
    assert_ne!(new, old);

    // Someone else asks the host for Ada's old ID: it is free, so it is theirs. Their home is made offline first,
    // so their key holds no ID of its own at the host.
    std::env::remove_var(ENV_TEST_HOST_LIST);
    drop(Client::connect(&c.0));
    std::env::set_var(ENV_TEST_HOST_LIST, &local.list_path);
    let store = Store::open(&c.0).unwrap();
    let asked = "INSERT INTO profile (id, friends_id, friends_id_state) VALUES (1, ?1, 0) \
                 ON CONFLICT(id) DO UPDATE SET friends_id = ?1, friends_id_state = 0";
    store.connection().execute(asked, [&old]).unwrap();
    drop(store);
    let mut cleo = Client::connect(&c.0);
    let theirs = shown_id(&mut cleo, "Cleo's ID reserved", |d| d["id"]["state"] == "reserved");
    assert_eq!(theirs, old, "Ada's old ID went to Cleo");
    drop((cleo, again, ada));

    // Offline: Bo's host is gone. The reset goes ahead within the release's time limit, unconfirmed.
    let (bo_helper, bo_server, mut bo) = helper(&b.0);
    let before = shown_id(&mut bo, "Bo's ID reserved", |d| d["id"]["state"] == "reserved");
    drop(local);
    let took = reset(&mut bo);
    assert!(took < Duration::from_secs(8), "the reset waited {took:?} for a host that is gone");
    let mut back = Client::join(&bo_server, bo_helper.clone(), &[]);
    let after = shown_id(&mut back, "Bo's new ID", |_| true);
    assert_ne!(after, before, "a new identity all the same");
    std::mem::forget((ada_server, bo_server));
}

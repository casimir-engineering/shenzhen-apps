//! A download link served by the Rust core, for a browser to open (the links half of wave 5's checks): the local Node
//! host with coturn at the cap (`szfriends_interop::host`), the core online with one live link to a file of
//! `--size` bytes, and the page's own address printed for a browser on this computer. Prints one JSON line when the
//! page is ready, then one per link event (a channel opened, a download completed); ends after `--seconds`.
//!
//! `SZFRIENDS_HOST_SERVER_DIR` and `FRIENDS_TEST_COTURN` as for the online suite. Everything on loopback.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::json;
use sha2::{Digest, Sha256};
use szfriends_core::identity::Identity;
use szfriends_core::wire::RouteMethod;
use szfriends_interop::host::{self, LocalHost};
use szfriends_interop::{write_content, TempHome};
use szfriends_online::driver::{Friends, OnlineFriend};
use szfriends_online::host::list::{pinned_keys, HostList};
use szfriends_online::links::{DownloadLink, LinkFiles};
use szfriends_online::{Online, OnlineConfig, OnlineEvent};

struct Nobody;

impl Friends for Nobody {
    fn friend(&self, _: &[u8; 32]) -> Option<OnlineFriend> {
        None
    }

    fn nearby_route(&self, _: &[u8; 32]) -> RouteMethod {
        RouteMethod::None
    }

    fn own_presence_secret(&self) -> Option<[u8; 32]> {
        None
    }
}

struct OneLink(Arc<Mutex<Vec<DownloadLink>>>);

impl LinkFiles for OneLink {
    fn links(&self) -> Vec<DownloadLink> {
        self.0.lock().unwrap().clone()
    }
}

fn main() {
    let size: u64 =
        std::env::args().skip_while(|a| a != "--size").nth(1).and_then(|s| s.parse().ok()).unwrap_or(3 << 20);
    let server = host::server_dir().expect("SZFRIENDS_HOST_SERVER_DIR names server/friends");
    if let Some(why) = host::unavailable(&server, true) {
        eprintln!("link_page: {why}");
        std::process::exit(2);
    }
    let dir = TempHome::new("link-page");
    let host = LocalHost::start(&server, dir.path(), true);
    let path = dir.path().join("Site photos.pdf");
    let blake2b = write_content(&path, "link page content", size);
    let sha256: [u8; 32] = Sha256::digest(std::fs::read(&path).expect("the content reads")).into();
    let (mut link_id, mut secret) = ([0u8; 16], [0u8; 32]);
    szfriends_core::crypto::random_bytes(&mut link_id);
    szfriends_core::crypto::random_bytes(&mut secret);
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64();
    let link = DownloadLink {
        link_id,
        secret,
        path,
        name: "Site photos.pdf".into(),
        size,
        sha256,
        blake2b,
        media_type: "application/pdf".into(),
        expires: now + 3600.0,
        sender_name: "Mei".into(),
        sender_friends_id: "brave-otter".into(),
        thumbnail: None,
    };
    let (pinned, _) = pinned_keys(&std::fs::read(&host.keys_path).unwrap()).unwrap();
    let list = HostList::from_signed(&host.list, &pinned).unwrap();
    let identity = Identity::generate();
    let config = OnlineConfig {
        identity: Arc::new(identity),
        app_version: "26.10.17-1".into(),
        list,
        pinned,
        loopback_only: true,
        direct_blocked: None,
        friends: Box::new(Nobody),
        id_provider: Box::new(|_| "mellow-heron".into()),
        technique_log: None,
        links: Some(Box::new(OneLink(Arc::new(Mutex::new(vec![link]))))),
        host_roots: None,
        membership: None,
        release_owed: None,
    };
    let (online, events) = Online::start(config);
    let payload = [&[1u8][..], &link_id, &secret].concat();
    let page = host.url.replacen("ws://", "http://", 1).replacen("/v1", "", 1);
    let page = format!("{page}/d#{}", szfriends_online::b64::encode_url(&payload));
    std::thread::spawn(move || {
        for event in events {
            match event {
                OnlineEvent::Available(true) => {
                    println!(
                        "{}",
                        json!({ "event": "ready", "page": page, "sha256": hex::encode(sha256), "size": size })
                    );
                }
                OnlineEvent::Link(event) => println!("{}", json!({ "event": format!("{event:?}") })),
                _ => {}
            }
        }
    });
    let seconds: u64 =
        std::env::args().skip_while(|a| a != "--seconds").nth(1).and_then(|s| s.parse().ok()).unwrap_or(300);
    std::thread::sleep(Duration::from_secs(seconds));
    online.stop();
    std::thread::sleep(Duration::from_millis(200));
    drop(host);
}

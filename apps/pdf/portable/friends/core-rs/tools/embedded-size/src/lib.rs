//! Not shipped. The Friends service as a phone app embeds it, so `tools/embedded-size.sh` can measure the whole thing
//! against ADR 0015 § 12 (5 MB per Android ABI and iOS architecture, 3 MB in a compressed APK split).
//!
//! It exports one function that does what the Tauri plugin's embedded mode does (`../tauri/src/phone/`): starts the
//! helper's service in a home of its own behind the protocol server, says hello as an app does, and sends one intent
//! and one subscription picked at run time, so the linker keeps every intent and every view. With the `online`
//! feature the service checks in with the bundled host list and keeps the data-channel stack, the host client, NAT
//! traversal and download links; without it, the service is nearby only, as phones ship it today. Linked into an
//! Android `.so` or an iOS executable, dead stripping then keeps what a phone app calling the core would keep.

use std::hint::black_box;
use std::sync::mpsc::channel;

use serde_json::json;
use szfriends_contract::handshake::HelperFacts;
use szfriends_helper::presentation::Presentation;
use szfriends_helper::server::Server;
use szfriends_helper::service::Service;
use szfriends_helper::transport::{memory_pair, Duplex, PeerInfo};

/// Every intent an app sends (PROTOCOL.md § Intents), and every view it subscribes to.
const INTENTS: [&str; 24] = [
    "activate",
    "set_name",
    "start_visibility",
    "send_request",
    "accept_request",
    "decline_request",
    "add_by_id",
    "send_message",
    "send_files",
    "accept_offer",
    "open_conversation",
    "mark_verified",
    "remove_friend",
    "block",
    "join_profile",
    "approve_join",
    "enter_join_code",
    "revoke_device",
    "rename_device",
    "make_download_link",
    "revoke_link",
    "search",
    "reset_friends",
    "fetch_from_device",
];
const VIEWS: [&str; 7] = ["list", "nearby", "profile", "conversation", "details", "join", "badge"];

/// Runs the service for one intent and one subscription picked by `seed`. Returns a number derived from what came
/// back, so nothing is optimised away.
#[allow(unsafe_code)] // `#[no_mangle]`: the host app's only way in.
#[no_mangle]
pub extern "C" fn szfriends_embedded_probe(seed: u64) -> u64 {
    let seed = black_box(seed);
    let home = std::env::temp_dir().join(format!("szfriends-embedded-size-{seed:016x}"));
    // A file of the key on phones, as a test home keeps it: the platform key stores are a few kilobytes.
    let keys = szfriends_helper::service::seed::test_key_store(&home);
    let Ok(service) = Service::start(&home, keys) else { return 0 };
    let (sender, _events) = channel();
    let facts = HelperFacts {
        version: "1".into(),
        build_number: 1,
        protocol: szfriends_contract::lifecycle::PROTOCOL,
        pid: std::process::id(),
    };
    let server = Server::new(service.clone(), facts, sender, Box::new(|_, _| false));
    let (ours, theirs) = memory_pair();
    server.add(theirs, PeerInfo::default());
    let text = format!("{seed:x}");
    let frames = [
        json!({"type": "hello", "id": "1", "protocol": {"major": 1, "minor": 0, "min_major": 1},
            "client": {"app_id": text, "app_name": text, "app_version": "1", "toolkit": "tauri", "pid": seed},
            "capabilities": ["drop.files", "mentions"], "open_formats": ["stl"], "locale": "en"}),
        json!({"type": INTENTS[seed as usize % INTENTS.len()], "id": "2", "conversation_id": text, "name": text,
            "friends_id": text, "text": text, "code": text, "device_id": text, "join_id": text, "query": text}),
        json!({"type": "subscribe", "id": "3", "view": VIEWS[seed as usize % VIEWS.len()],
            "params": {"conversation_id": text}}),
    ];
    let mut out = 0u64;
    for frame in &frames {
        let bytes = szfriends_contract::framing::encode(frame).unwrap_or_default();
        out += ours.write_all(&bytes).is_ok() as u64;
    }
    let mut buffer = vec![0u8; 65_536];
    out += ours.read(&mut buffer).unwrap_or(0) as u64;
    Presentation::shutdown(&*service);
    drop(server);
    let _ = std::fs::remove_dir_all(home);
    out
}

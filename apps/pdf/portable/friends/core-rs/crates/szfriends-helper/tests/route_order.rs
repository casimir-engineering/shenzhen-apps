//! The owner's route order where nearby and online meet: direct on the same network, then peer to peer (a direct
//! Internet connection here), then Bluetooth, then the relay. Two helpers' services in test homes, made friends,
//! first reach each other online through the local Node host and its coturn; then their test networks (or test airs)
//! are joined, as two people walking into the same room. A better nearby route takes over from online; a worse one
//! never does. `make friends-core-rs-online-check` sets `SZFRIENDS_HOST_SERVER_DIR` and `FRIENDS_TEST_COTURN`;
//! without them the test says what is missing and passes.
#![cfg(feature = "online")]

mod clients;
mod routes;
mod support;

use clients::{Client, Temp};
use routes::{Joined, RoutePair};
use serde_json::json;
use szfriends_helper::service::{seed, BLOCK_DIRECT_FILE, ENV_TEST_HOST_KEYS, ENV_TEST_HOST_LIST};
use szfriends_helper::state::ENV_STATE_DIR;
use szfriends_interop::host::{self, LocalHost};

struct Pair {
    ada: Client,
    bo: Client,
    chats: (String, String),
    conversations: (String, String),
    sent: u32,
    /// Last, so the homes outlive the services using them.
    _homes: (Temp, Temp, Temp, Temp),
}

impl RoutePair for Pair {
    /// Ada and Bo, friends, each on a nearby test network (`variable`) of their own until joined.
    fn start(label: &str, variable: &str, relayed: bool) -> Self {
        let homes = (
            Temp::new(&format!("{label}-a")),
            Temp::new(&format!("{label}-b")),
            Temp::new(&format!("{label}-near-a")),
            Temp::new(&format!("{label}-near-b")),
        );
        std::env::set_var(ENV_STATE_DIR, &homes.0 .0);
        let (bo_in_a, ada_in_b) = seed::befriend(&homes.0 .0, &homes.1 .0, ("Ada", "Bo")).expect("befriended");
        if relayed {
            std::fs::write(homes.0 .0.join(BLOCK_DIRECT_FILE), b"").unwrap();
            std::fs::write(homes.1 .0.join(BLOCK_DIRECT_FILE), b"").unwrap();
        }
        std::env::set_var(variable, &homes.2 .0);
        let mut ada = Client::connect(&homes.0 .0);
        std::env::set_var(variable, &homes.3 .0);
        let mut bo = Client::connect(&homes.1 .0);
        std::env::remove_var(variable);
        ada.send("activate", json!({}));
        bo.send("activate", json!({}));
        let open = |client: &mut Client, id: &str| {
            let reply = client.send("open_conversation", json!({"conversation_id": id}));
            reply["subscription"].as_str().unwrap().to_owned()
        };
        let chats = (open(&mut ada, &bo_in_a), open(&mut bo, &ada_in_b));
        Self { ada, bo, chats, conversations: (bo_in_a, ada_in_b), sent: 0, _homes: homes }
    }

    fn join(&self) -> Joined {
        Joined::new(self._homes.2 .0.clone(), self._homes.3 .0.clone())
    }

    /// A message from Ada, delivered; then Ada's conversation shows `route`.
    fn carry_over(&mut self, route: &str) {
        self.sent += 1;
        let text = format!("Message {} from Ada", self.sent);
        let token = format!("{:032x}", self.sent);
        let fields = json!({"conversation_id": self.conversations.0, "text": text, "client_token": token});
        self.ada.send("send_message", fields);
        self.bo.snapshot(&self.chats.1, "the message at Bo", |d| d.to_string().contains(&text));
        self.shows(route);
    }

    fn shows(&mut self, route: &str) {
        let what = format!("Ada's conversation showing {route}");
        self.ada.snapshot(&self.chats.0, &what, |d| d.to_string().contains(route));
    }

    fn shown(&mut self) -> String {
        self.ada.snapshot(&self.chats.0, "Ada's conversation", |_| true)["data"].to_string()
    }
}

#[test]
fn nearby_and_online_keep_the_owners_route_order() {
    let Some(server) = host::server_dir() else {
        eprintln!("SZFRIENDS_HOST_SERVER_DIR is not set: make friends-core-rs-online-check sets it");
        return;
    };
    if let Some(why) = host::unavailable(&server, true) {
        eprintln!("skipped: {why}");
        return;
    }
    let dir = Temp::new("order-host");
    let host = LocalHost::start(&server, &dir.0, true);
    std::env::set_var(ENV_TEST_HOST_LIST, &host.list_path);
    std::env::set_var(ENV_TEST_HOST_KEYS, &host.keys_path);
    routes::owners_route_order::<Pair>("friends");
    drop(host);
}

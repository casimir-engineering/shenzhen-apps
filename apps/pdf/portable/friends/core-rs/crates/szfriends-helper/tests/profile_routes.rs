//! A profile moves between one person's computers in the owner's route order, exactly as a friend's files do
//! (`routes/mod.rs`, the scenarios `route_order.rs` runs for friends): a new computer joins, the sync that follows
//! shows its route on the join page, and a better route takes over while a worse one never does. Two more: a join
//! made over Bluetooth alone moves to the network once both computers are on it; one made where only the relay works
//! moves off it once a direct connection works. `make friends-core-rs-online-check` sets `SZFRIENDS_HOST_SERVER_DIR`
//! and `FRIENDS_TEST_COTURN` for the online ones; without them those say what is missing and pass.

mod clients;
mod routes;
mod support;

use std::sync::Mutex;

use clients::{join_profile, texts, Client, Temp};
use routes::{Joined, RoutePair, BLUETOOTH, DIRECT, LAN, RELAY};
use serde_json::json;
use szfriends_helper::nearby::test_air::ENV_TEST_BLUETOOTH;
use szfriends_helper::service::{BLOCK_DIRECT_FILE, ENV_TEST_HOST_KEYS, ENV_TEST_HOST_LIST, ENV_TEST_LOOPBACK};
use szfriends_helper::state::ENV_STATE_DIR;

/// Services read the environment as they start: one pair at a time.
static START: Mutex<()> = Mutex::new(());

/// Ada's computer and the one joining her profile, each on nearby test media of its own until joined.
struct DevicePair {
    ada: Client,
    new: Client,
    join_view: String,
    profile_view: String,
    renamed: u32,
    /// Ada's, the new computer's, then each one's nearby medium (`variable`) and, when asked, a second medium.
    homes: Vec<Temp>,
}

impl DevicePair {
    /// `media`: the test variables each computer gets a directory of its own for; `shared`: one both use from the
    /// start. Joins through whatever those allow (and the host, when one is set).
    fn begin(label: &str, media: &[&str], shared: Option<&str>, relayed: bool) -> Self {
        let mut homes = vec![Temp::new(&format!("{label}-a")), Temp::new(&format!("{label}-b"))];
        for (index, _) in media.iter().enumerate() {
            homes.push(Temp::new(&format!("{label}-near{index}-a")));
            homes.push(Temp::new(&format!("{label}-near{index}-b")));
        }
        let together = Temp::new(&format!("{label}-shared"));
        if relayed {
            std::fs::write(homes[0].0.join(BLOCK_DIRECT_FILE), b"").unwrap();
            std::fs::write(homes[1].0.join(BLOCK_DIRECT_FILE), b"").unwrap();
        }
        let (mut ada, mut new) = {
            let _guard = START.lock().unwrap_or_else(|e| e.into_inner());
            std::env::set_var(ENV_STATE_DIR, &homes[0].0);
            let start = |side: usize, homes: &[Temp]| {
                for (index, variable) in media.iter().enumerate() {
                    std::env::set_var(variable, &homes[2 + index * 2 + side].0);
                }
                if let Some(variable) = shared {
                    std::env::set_var(variable, &together.0);
                }
                let client = Client::connect(&homes[side].0);
                for variable in media.iter().chain(shared.iter()) {
                    std::env::remove_var(variable);
                }
                client
            };
            (start(0, &homes), start(1, &homes))
        };
        homes.push(together);
        ada.send("set_name", json!({"name": "Ada"}));
        for client in [&mut ada, &mut new] {
            client.send("activate", json!({}));
        }
        let profile = ada.subscribe("profile", json!({}));
        let data = ada.snapshot(&profile, "Ada's Friends ID", |d| d["id"]["friends_id"].is_string());
        let id = data["data"]["id"]["friends_id"].as_str().unwrap().to_owned();
        join_profile(&mut ada, &id, &mut new);
        let join_view = new.subscribe("join", json!({}));
        let profile_view = new.subscribe("profile", json!({}));
        Self { ada, new, join_view, profile_view, renamed: 0, homes }
    }

    /// The nearby media of kind `index` become one.
    fn join_medium(&self, index: usize) -> Joined {
        Joined::new(self.homes[2 + index * 2].0.clone(), self.homes[3 + index * 2].0.clone())
    }

    fn unblock_direct(&self) {
        for home in &self.homes[..2] {
            let _ = std::fs::remove_file(home.0.join(BLOCK_DIRECT_FILE));
        }
    }
}

impl RoutePair for DevicePair {
    fn start(label: &str, variable: &str, relayed: bool) -> Self {
        Self::begin(label, &[variable], None, relayed)
    }

    fn join(&self) -> Joined {
        self.join_medium(0)
    }

    /// The join page shows `route`; then a new name for the profile on Ada's computer reaches the new one over it.
    /// (Named once the sync runs: a name given while the new computer's first capture is on its way can lose to the
    /// copy that computer took when it joined.)
    fn carry_over(&mut self, route: &str) {
        self.shows(route);
        self.renamed += 1;
        let name = format!("Ada {}", self.renamed);
        self.ada.send("set_name", json!({"name": name}));
        let what = format!("{name} on the new computer");
        self.new.snapshot(&self.profile_view, &what, |d| texts(d).contains(&name));
        self.shows(route);
    }

    fn shows(&mut self, route: &str) {
        let what = format!("the join page showing {route}");
        self.new.snapshot(&self.join_view, &what, |d| d["route"]["label"] == route);
    }

    fn shown(&mut self) -> String {
        self.new.snapshot(&self.join_view, "the join page", |_| true)["data"].to_string()
    }
}

/// A join over Bluetooth alone (each computer on a network of its own); once they share the network, the sync moves
/// to it and keeps working there.
fn a_join_over_bluetooth_moves_to_the_network() {
    let mut pair = DevicePair::begin("bt-join", &[ENV_TEST_LOOPBACK], Some(ENV_TEST_BLUETOOTH), false);
    pair.carry_over(BLUETOOTH);
    let _joined = pair.join_medium(0);
    pair.shows(LAN);
    pair.carry_over(LAN);
}

fn with_host(run: impl FnOnce()) {
    #[cfg(feature = "online")]
    {
        use szfriends_interop::host::{self, LocalHost};
        let Some(server) = host::server_dir() else {
            eprintln!("SZFRIENDS_HOST_SERVER_DIR is not set: make friends-core-rs-online-check sets it");
            return;
        };
        if let Some(why) = host::unavailable(&server, true) {
            eprintln!("skipped: {why}");
            return;
        }
        let dir = Temp::new("profile-host");
        let host = LocalHost::start(&server, &dir.0, true);
        std::env::set_var(ENV_TEST_HOST_LIST, &host.list_path);
        std::env::set_var(ENV_TEST_HOST_KEYS, &host.keys_path);
        run();
        std::env::remove_var(ENV_TEST_HOST_LIST);
        std::env::remove_var(ENV_TEST_HOST_KEYS);
        drop(host);
    }
    #[cfg(not(feature = "online"))]
    {
        let _ = run;
        eprintln!("built without online: nothing to run");
    }
}

/// Where only the relay works, the join and its sync use it; once a direct connection works, the sync moves to it;
/// once both computers share a network, to that.
fn a_join_through_the_relay_moves_off_it() {
    let mut pair = DevicePair::begin("relay-join", &[ENV_TEST_LOOPBACK], None, true);
    pair.carry_over(RELAY);
    pair.unblock_direct();
    pair.shows(DIRECT);
    pair.carry_over(DIRECT);
    let _joined = pair.join_medium(0);
    pair.shows(LAN);
    pair.carry_over(LAN);
}

/// Nearby only first (no host is set, so nothing goes online); then online through the local host: the order every
/// friend's conversation keeps (`route_order.rs`), then the relay. One test, so no host is set while the first runs.
#[test]
fn a_profile_keeps_the_owners_route_order() {
    a_join_over_bluetooth_moves_to_the_network();
    with_host(|| {
        routes::owners_route_order::<DevicePair>("profile");
        a_join_through_the_relay_moves_off_it();
    });
}

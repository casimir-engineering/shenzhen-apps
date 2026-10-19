//! Links between a Rust helper and the Objective-C helper, both in test homes on a Mac, online only through the local
//! Node host on loopback: each one's friend link added from by the other and accepted at once by its maker, and each
//! one's download link received by the other into its chat with the maker; and each one's plain Add by ID reaching
//! the other through the host, whose answer shows the host's attestation and so makes a friend at once. The
//! Objective-C helper is the links e2e helper (`build/friends/links/szfriends-links-e2e-helper`: the shipped helper's
//! objects, with its links and online connections allowed on loopback, as the Rust helper allows them in a test
//! home). `make friends-core-rs-online-check`
//! sets `SZFRIENDS_OBJC_LINKS_HELPER` and `SZFRIENDS_HOST_SERVER_DIR`; without them (or anywhere but a Mac) each test
//! says so and passes.

#[cfg(target_os = "macos")]
mod mac {
    use std::path::PathBuf;
    use std::sync::Mutex;

    use szfriends_interop::helpers::{objc_helper_online, objc_wait_online, rust_helper, Client};
    use szfriends_interop::host::{self, LocalHost};
    use szfriends_interop::{link_scenarios, TempHome};

    /// The environment is the process's: one pair's helpers at a time.
    static START: Mutex<()> = Mutex::new(());

    pub struct Pair {
        pub rust: Client,
        pub objc: Client,
        _homes: [TempHome; 3],
        _host: LocalHost,
    }

    pub fn pair(rust_name: &str, objc_name: &str) -> Option<Pair> {
        let Some(binary) = std::env::var_os("SZFRIENDS_OBJC_LINKS_HELPER").map(PathBuf::from) else {
            eprintln!("SZFRIENDS_OBJC_LINKS_HELPER is not set: make friends-core-rs-online-check builds the helper");
            return None;
        };
        let Some(server) = host::server_dir() else {
            eprintln!("SZFRIENDS_HOST_SERVER_DIR is not set: make friends-core-rs-online-check sets it");
            return None;
        };
        if let Some(why) = host::unavailable(&server, false) {
            eprintln!("skipped: {why}");
            return None;
        }
        let homes = [TempHome::new("links-host"), TempHome::new(rust_name), TempHome::new(objc_name)];
        let local = LocalHost::start(&server, homes[0].path(), false);
        let _guard = START.lock().unwrap_or_else(|e| e.into_inner());
        let mut rust = {
            std::env::set_var("SZFRIENDS_STATE_DIR", homes[1].path());
            std::env::set_var("SZFRIENDS_TEST_HOST_LIST", &local.list_path);
            std::env::set_var("SZFRIENDS_TEST_HOST_KEYS", &local.keys_path);
            std::env::remove_var("SZFRIENDS_TEST_LOOPBACK");
            std::env::remove_var("SZFRIENDS_TEST_SERVICE_TYPE");
            rust_helper(rust_name, &homes[1].path().join("state"))
        };
        let state = homes[2].path().join("state");
        let mut objc = objc_helper_online(objc_name, &binary, &state, &local.list_path, &local.keys_path);
        assert!(objc_wait_online(&state, std::time::Duration::from_secs(40)), "the Objective-C helper online");
        rust.send("set_name", serde_json::json!({"name": rust_name}));
        objc.send("set_name", serde_json::json!({"name": objc_name}));
        // Friends opened in each app: what the person does before adding anyone.
        rust.send("activate", serde_json::json!({}));
        objc.send("activate", serde_json::json!({}));
        Some(Pair { rust, objc, _homes: homes, _host: local })
    }

    pub fn friend_link(rust_makes: bool) {
        let Some(mut p) = pair("Rina", "Omar") else { return };
        if rust_makes {
            link_scenarios::friend_link(&mut p.rust, "Rina", &mut p.objc, "Omar");
        } else {
            link_scenarios::friend_link(&mut p.objc, "Omar", &mut p.rust, "Rina");
        }
    }

    /// Plain Add by ID through the host, the holder accepting: a friend at once on the asker's side.
    pub fn add_by_id(rust_asks: bool) {
        let Some(mut p) = pair("Rhea", "Odin") else { return };
        if rust_asks {
            link_scenarios::add_by_id(&mut p.rust, &mut p.objc, "Odin");
        } else {
            link_scenarios::add_by_id(&mut p.objc, &mut p.rust, "Rhea");
        }
    }

    pub fn download_link(rust_makes: bool) {
        let Some(mut p) = pair("Rubi", "Olga") else { return };
        if rust_makes {
            link_scenarios::download_link(&mut p.rust, &mut p.objc);
        } else {
            link_scenarios::download_link(&mut p.objc, &mut p.rust);
        }
    }
}

#[test]
fn a_rust_friend_link_added_from_by_the_objective_c_helper() {
    #[cfg(target_os = "macos")]
    mac::friend_link(true);
}

#[test]
fn an_objective_c_friend_link_added_from_by_a_rust_helper() {
    #[cfg(target_os = "macos")]
    mac::friend_link(false);
}

#[test]
fn a_rust_download_link_received_by_the_objective_c_helper() {
    #[cfg(target_os = "macos")]
    mac::download_link(true);
}

#[test]
fn an_objective_c_download_link_received_by_a_rust_helper() {
    #[cfg(target_os = "macos")]
    mac::download_link(false);
}

#[test]
fn an_objective_c_add_by_id_answered_by_a_rust_helper_makes_a_friend() {
    #[cfg(target_os = "macos")]
    mac::add_by_id(false);
}

#[test]
fn a_rust_add_by_id_answered_by_the_objective_c_helper_makes_a_friend() {
    #[cfg(target_os = "macos")]
    mac::add_by_id(true);
}

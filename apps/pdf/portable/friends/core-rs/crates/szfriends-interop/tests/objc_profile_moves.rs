//! What joining brings, between Rust helpers and the Objective-C helper (`build/friends/helper/szfriends-helper`), all
//! in test homes on a Mac, meeting on Bonjour over loopback under a test service type: the person's first computer
//! has a friend, a chat with them and notes in You; a new computer joins; then the friend, the chat and You are on
//! both, and a message, the friend's reply and a note in You reach the other each way (`profile_moves.rs`), with the
//! first computer on either implementation. `make friends-core-rs-interop-check` sets `SZFRIENDS_OBJC_HELPER`;
//! without it each test says so and passes.

#[cfg(target_os = "macos")]
mod mac {
    use std::path::PathBuf;
    use std::sync::Mutex;
    use std::time::Duration;

    use szfriends_interop::helpers::{objc_helper, rust_helper, test_service_type, Client};
    use szfriends_interop::{nearby, profile_moves, TempHome};

    static START: Mutex<()> = Mutex::new(());

    /// One helper per name, Rust where the flag says so, on one test service type, each named and with Friends open.
    fn helpers(names: &[(&str, bool)]) -> Option<(Vec<Client>, Vec<TempHome>)> {
        let Some(binary) = std::env::var_os("SZFRIENDS_OBJC_HELPER").map(PathBuf::from) else {
            eprintln!("SZFRIENDS_OBJC_HELPER is not set: make friends-core-rs-interop-check builds the helper");
            return None;
        };
        let service_type = test_service_type();
        let (mut clients, mut homes) = (Vec::new(), Vec::new());
        for (name, rust) in names {
            let home = TempHome::new(name);
            let mut client = if *rust {
                let _guard = START.lock().unwrap_or_else(|e| e.into_inner());
                std::env::set_var("SZFRIENDS_STATE_DIR", home.path());
                std::env::remove_var("SZFRIENDS_TEST_LOOPBACK");
                std::env::set_var("SZFRIENDS_TEST_SERVICE_TYPE", &service_type);
                rust_helper(name, &home.path().join("state"))
            } else {
                objc_helper(name, &binary, &home.path().join("state"), &service_type)
            };
            client.send("set_name", serde_json::json!({"name": name}));
            client.send("activate", serde_json::json!({}));
            clients.push(client);
            homes.push(home);
        }
        Some((clients, homes))
    }

    /// The first computer (Objective-C when `objc_holds`) befriends Fay nearby; the other implementation joins it.
    pub fn moves(objc_holds: bool, friend_rust: bool) {
        let holder = if objc_holds { "Otto" } else { "Rosa" };
        let Some((mut clients, _homes)) = helpers(&[(holder, !objc_holds), ("New", objc_holds), ("Fay", friend_rust)])
        else {
            return;
        };
        let (h, rest) = clients.split_at_mut(1);
        let (j, f) = rest.split_at_mut(1);
        nearby::visible_request(&mut f[0], "Fay", &mut h[0], holder);
        profile_moves::friends_chats_and_you_move(
            &mut h[0],
            holder,
            &mut j[0],
            &mut f[0],
            "Fay",
            Duration::from_secs(60),
        );
    }
}

#[test]
fn rust_joins_an_objc_profile_and_gets_its_friend_chat_and_you() {
    #[cfg(target_os = "macos")]
    mac::moves(true, true);
}

#[test]
fn objc_helper_joins_a_rust_profile_and_gets_its_friend_chat_and_you() {
    #[cfg(target_os = "macos")]
    mac::moves(false, false);
}

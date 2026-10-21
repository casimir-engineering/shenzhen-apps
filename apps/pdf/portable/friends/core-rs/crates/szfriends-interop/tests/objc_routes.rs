//! Routes between a Rust helper and the Objective-C helper (`build/friends/helper/szfriends-helper`), both in test
//! homes on a Mac, sharing one test air and one network hold (`helpers::Room`): with the network held they meet over
//! the test air, become friends and talk over Bluetooth; once the network comes up (loopback Bonjour under a test
//! service type) their conversation moves to it. Each direction. `make friends-core-rs-interop-check` sets
//! `SZFRIENDS_OBJC_HELPER`; without it (any platform but a Mac with the helper built) each test says so and passes.

#[cfg(target_os = "macos")]
mod mac {
    use std::path::PathBuf;
    use std::sync::Mutex;

    use szfriends_interop::helpers::{objc_helper_with, rust_helper_with, test_service_type, Room};
    use szfriends_interop::{nearby, routes, TempHome};

    static START: Mutex<()> = Mutex::new(());

    pub fn bluetooth_then_network(rust_asks: bool) {
        let Some(binary) = std::env::var_os("SZFRIENDS_OBJC_HELPER").map(PathBuf::from) else {
            eprintln!("SZFRIENDS_OBJC_HELPER is not set: make friends-core-rs-interop-check builds the helper");
            return;
        };
        let (rust_name, objc_name) = ("Rina", "Olaf");
        let homes = [TempHome::new(rust_name), TempHome::new(objc_name), TempHome::new("room")];
        let room = Room::new(homes[2].path(), true);
        let service_type = test_service_type();
        let mut env: Vec<(&str, String)> = room.env();
        env.push(("SZFRIENDS_TEST_SERVICE_TYPE", service_type));
        let env: Vec<(&str, &str)> = env.iter().map(|(k, v)| (*k, v.as_str())).collect();
        let mut rust = {
            let _guard = START.lock().unwrap_or_else(|e| e.into_inner());
            std::env::set_var("SZFRIENDS_STATE_DIR", homes[0].path());
            std::env::remove_var("SZFRIENDS_TEST_LOOPBACK");
            rust_helper_with(rust_name, &homes[0].path().join("state"), &env)
        };
        let mut objc = objc_helper_with(objc_name, &binary, &homes[1].path().join("state"), &env);
        nearby::start(&mut rust, rust_name, &mut objc, objc_name);
        if rust_asks {
            routes::bluetooth_then_network(&mut rust, rust_name, &mut objc, objc_name, &room);
        } else {
            routes::bluetooth_then_network(&mut objc, objc_name, &mut rust, rust_name, &room);
        }
    }
}

#[test]
fn rust_meets_the_objc_helper_over_bluetooth_then_the_network() {
    #[cfg(target_os = "macos")]
    mac::bluetooth_then_network(true);
}

#[test]
fn objc_helper_meets_rust_over_bluetooth_then_the_network() {
    #[cfg(target_os = "macos")]
    mac::bluetooth_then_network(false);
}

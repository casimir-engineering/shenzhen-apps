//! Nearby between a Rust helper and the Objective-C helper (`build/friends/helper/szfriends-helper`), both in test
//! homes on a Mac, meeting on Bonjour over loopback under a test service type (the Rust side through `dns-sd -i lo0`):
//! someone visible found and asked, codes compared, accepted, then messages and a file; Add by ID answered by its
//! holder's callback; a declined request; a new computer joining the other's profile and syncing with it; each in
//! both directions. `make friends-core-rs-interop-check` sets `SZFRIENDS_OBJC_HELPER`; without it (any platform but
//! a Mac with the helper built) each test says so and passes.

#[cfg(target_os = "macos")]
mod mac {
    use std::path::PathBuf;
    use std::sync::Mutex;

    use szfriends_interop::helpers::{objc_helper, rust_helper, test_service_type, Client};
    use szfriends_interop::{nearby, nearby_devices, TempHome};

    static START: Mutex<()> = Mutex::new(());

    pub struct Pair {
        pub rust: Client,
        pub objc: Client,
        _homes: [TempHome; 2],
    }

    pub fn pair(rust_name: &str, objc_name: &str) -> Option<Pair> {
        let Some(binary) = std::env::var_os("SZFRIENDS_OBJC_HELPER").map(PathBuf::from) else {
            eprintln!("SZFRIENDS_OBJC_HELPER is not set: make friends-core-rs-interop-check builds the helper");
            return None;
        };
        let homes = [TempHome::new(rust_name), TempHome::new(objc_name)];
        let service_type = test_service_type();
        let mut rust = {
            let _guard = START.lock().unwrap_or_else(|e| e.into_inner());
            std::env::set_var("SZFRIENDS_STATE_DIR", homes[0].path());
            std::env::remove_var("SZFRIENDS_TEST_LOOPBACK");
            std::env::set_var("SZFRIENDS_TEST_SERVICE_TYPE", &service_type);
            rust_helper(rust_name, &homes[0].path().join("state"))
        };
        let mut objc = objc_helper(objc_name, &binary, &homes[1].path().join("state"), &service_type);
        nearby::start(&mut rust, rust_name, &mut objc, objc_name);
        Some(Pair { rust, objc, _homes: homes })
    }

    pub fn visible(rust_asks: bool) {
        let Some(mut p) = pair("Rosa", "Otto") else { return };
        if rust_asks {
            nearby::visible_request(&mut p.rust, "Rosa", &mut p.objc, "Otto");
        } else {
            nearby::visible_request(&mut p.objc, "Otto", &mut p.rust, "Rosa");
        }
    }

    pub fn by_id(rust_asks: bool) {
        let Some(mut p) = pair("Rhea", "Odin") else { return };
        if rust_asks {
            nearby::add_by_id(&mut p.rust, &mut p.objc);
        } else {
            nearby::add_by_id(&mut p.objc, &mut p.rust);
        }
    }

    pub fn joined(rust_joins: bool) {
        let Some(mut p) = pair("Ruth", "Oleg") else { return };
        if rust_joins {
            nearby_devices::join_and_sync(&mut p.objc, "Oleg", &mut p.rust);
        } else {
            nearby_devices::join_and_sync(&mut p.rust, "Ruth", &mut p.objc);
        }
    }

    pub fn renamed_after_joining(rust_joins: bool) {
        let Some(mut p) = pair("Rena", "Omar") else { return };
        if rust_joins {
            nearby_devices::rename_right_after_join(&mut p.objc, "Omar", &mut p.rust);
        } else {
            nearby_devices::rename_right_after_join(&mut p.rust, "Rena", &mut p.objc);
        }
    }

    pub fn declined(rust_asks: bool) {
        let Some(mut p) = pair("Remy", "Olga") else { return };
        if rust_asks {
            nearby::declined(&mut p.rust, "Remy", &mut p.objc, "Olga");
        } else {
            nearby::declined(&mut p.objc, "Olga", &mut p.rust, "Remy");
        }
    }
}

#[test]
fn rust_asks_a_visible_objc_helper() {
    #[cfg(target_os = "macos")]
    mac::visible(true);
}

#[test]
fn objc_helper_asks_a_visible_rust_helper() {
    #[cfg(target_os = "macos")]
    mac::visible(false);
}

#[test]
fn rust_adds_the_objc_helper_by_id() {
    #[cfg(target_os = "macos")]
    mac::by_id(true);
}

#[test]
fn objc_helper_adds_the_rust_helper_by_id() {
    #[cfg(target_os = "macos")]
    mac::by_id(false);
}

#[test]
fn objc_helper_declines_rust() {
    #[cfg(target_os = "macos")]
    mac::declined(true);
}

#[test]
fn rust_declines_the_objc_helper() {
    #[cfg(target_os = "macos")]
    mac::declined(false);
}

#[test]
fn rust_joins_an_objc_profile_and_syncs() {
    #[cfg(target_os = "macos")]
    mac::joined(true);
}

#[test]
fn objc_helper_joins_a_rust_profile_and_syncs() {
    #[cfg(target_os = "macos")]
    mac::joined(false);
}

#[test]
fn a_name_given_on_the_objc_helper_right_after_a_rust_helper_joins_stays() {
    #[cfg(target_os = "macos")]
    mac::renamed_after_joining(true);
}

#[test]
fn a_name_given_on_the_rust_helper_right_after_the_objc_helper_joins_stays() {
    #[cfg(target_os = "macos")]
    mac::renamed_after_joining(false);
}

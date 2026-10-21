//! Getting a file again (ADR 0016) between Rust helpers and the Objective-C helper (`build/friends/helper/
//! szfriends-helper`), all in test homes on a Mac, meeting on Bonjour over loopback under a test service type: Get
//! again from the friend who sent a file, each way, and "Otto doesn’t have this file anymore." once they changed it;
//! on one profile, a copy deleted on one computer comes back with Get from the other, each way; and a friend's file
//! received on one computer comes back from the other computer each way and, deleted on both, from the friend.
//! `make friends-core-rs-interop-check` sets `SZFRIENDS_OBJC_HELPER`; without it each test says so and passes.

#[cfg(target_os = "macos")]
mod mac {
    use std::path::PathBuf;
    use std::sync::Mutex;

    use szfriends_interop::helpers::{objc_helper, rust_helper, test_service_type, Client};
    use szfriends_interop::{again, nearby, nearby_devices, TempHome};

    static START: Mutex<()> = Mutex::new(());

    pub struct Helpers {
        pub clients: Vec<Client>,
        _homes: Vec<TempHome>,
    }

    /// One helper per name, Rust where `rust` says so, on one test service type, each named and with Friends open.
    fn helpers(names: &[(&str, bool)]) -> Option<Helpers> {
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
        Some(Helpers { clients, _homes: homes })
    }

    /// `receiver` asks `sender` to be friends nearby; then Get again on a file `sender` sent.
    pub fn get_again(rust_receives: bool) {
        let (receiver_name, sender_name) = if rust_receives { ("Rosa", "Otto") } else { ("Olga", "Remy") };
        let Some(mut h) = helpers(&[(receiver_name, rust_receives), (sender_name, !rust_receives)]) else { return };
        let (receiver, sender) = h.clients.split_at_mut(1);
        let (receiver, sender) = (&mut receiver[0], &mut sender[0]);
        nearby::visible_request(receiver, receiver_name, sender, sender_name);
        let sender_in_receiver = again::conversation_titled(receiver, sender_name);
        let receiver_in_sender = again::conversation_titled(sender, receiver_name);
        again::get_again(sender, sender_name, &receiver_in_sender, receiver, &sender_in_receiver);
    }

    /// One profile on a Rust and an Objective-C helper: a You file deleted on one comes back from the other, each way.
    pub fn own_computers(rust_holds: bool) {
        let Some(mut h) = helpers(&[("Ruth", rust_holds), ("Oleg", !rust_holds)]) else { return };
        let (holder, joiner) = h.clients.split_at_mut(1);
        let (holder, joiner) = (&mut holder[0], &mut joiner[0]);
        nearby_devices::join(holder, joiner);
        again::get_from_own_computer(holder, joiner);
        again::get_from_own_computer(joiner, holder);
    }

    /// One profile on the Objective-C helper and a Rust one, and a Rust friend of the profile's.
    pub fn received_everywhere(rust_holds: bool, friend_rust: bool) {
        let Some(mut h) = helpers(&[("Ada", rust_holds), ("Bea", !rust_holds), ("Fay", friend_rust)]) else { return };
        let (a, rest) = h.clients.split_at_mut(1);
        let (b, f) = rest.split_at_mut(1);
        let (a, b, f) = (&mut a[0], &mut b[0], &mut f[0]);
        nearby_devices::join(a, b);
        nearby::visible_request(f, "Fay", a, "Ada");
        again::received_everywhere(a, b, f, "Fay", "Ada");
    }
}

#[test]
fn rust_gets_a_file_again_from_the_objc_helper() {
    #[cfg(target_os = "macos")]
    mac::get_again(true);
}

#[test]
fn objc_helper_gets_a_file_again_from_rust() {
    #[cfg(target_os = "macos")]
    mac::get_again(false);
}

#[test]
fn a_deleted_copy_comes_back_from_the_other_computer_rust_holds() {
    #[cfg(target_os = "macos")]
    mac::own_computers(true);
}

#[test]
fn a_deleted_copy_comes_back_from_the_other_computer_objc_holds() {
    #[cfg(target_os = "macos")]
    mac::own_computers(false);
}

#[test]
fn a_friends_file_comes_back_from_either_computer_then_from_a_rust_friend() {
    #[cfg(target_os = "macos")]
    mac::received_everywhere(false, true);
}

#[test]
fn a_friends_file_comes_back_from_either_computer_then_from_an_objc_friend() {
    #[cfg(target_os = "macos")]
    mac::received_everywhere(false, false);
}

#[test]
fn a_friends_file_on_a_rust_profile_comes_back_from_an_objc_friend() {
    #[cfg(target_os = "macos")]
    mac::received_everywhere(true, false);
}

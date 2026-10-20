//! The test network's directory joined to Bonjour on lo0 (`szfriends-testnet dir`, `bridge::dir`): a Rust helper on
//! a loopback test network and the Objective-C helper on its Bonjour test type find each other through the bridge, ask
//! and accept, then talk — what the phone tests rely on to join an emulator's helper to a Mac's. Set
//! `SZFRIENDS_OBJC_HELPER` (make friends-core-rs-interop-check does); without it the test says so and passes.

#[cfg(target_os = "macos")]
#[test]
fn a_loopback_helper_and_the_objc_helper_meet_through_the_bridge() {
    use std::path::PathBuf;
    use std::process::{Command, Stdio};

    use szfriends_interop::helpers::{objc_helper, rust_helper, test_service_type};
    use szfriends_interop::{nearby, TempHome};

    let Some(binary) = std::env::var_os("SZFRIENDS_OBJC_HELPER").map(PathBuf::from) else {
        eprintln!("SZFRIENDS_OBJC_HELPER is not set: make friends-core-rs-interop-check builds the helper");
        return;
    };
    let homes = [TempHome::new("Lou"), TempHome::new("Oda"), TempHome::new("routes")];
    let service_type = test_service_type();
    let routes = homes[2].path().join("net");
    std::fs::create_dir_all(&routes).expect("the routes");
    let mut bridge = Command::new(env!("CARGO_BIN_EXE_szfriends-testnet"))
        .arg("dir")
        .arg(&routes)
        .arg(&service_type)
        .stdin(Stdio::piped())
        .spawn()
        .expect("the bridge starts");
    std::env::set_var("SZFRIENDS_STATE_DIR", homes[0].path());
    std::env::set_var("SZFRIENDS_TEST_LOOPBACK", &routes);
    let mut rust = rust_helper("Lou", &homes[0].path().join("state"));
    let mut objc = objc_helper("Oda", &binary, &homes[1].path().join("state"), &service_type);
    nearby::start(&mut rust, "Lou", &mut objc, "Oda");
    nearby::visible_request(&mut rust, "Lou", &mut objc, "Oda");
    drop(bridge.stdin.take());
    let _ = bridge.wait();
}

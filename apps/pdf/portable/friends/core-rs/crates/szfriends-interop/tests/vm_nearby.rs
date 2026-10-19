//! Nearby between the Objective-C helper on this Mac and a Rust helper inside a VM (Windows 11, Ubuntu), meeting
//! through the test network's bridge (`szfriends_interop::bridge`) with every socket on loopback on both sides: found
//! while visible, asked, accepted, Add by ID, a decline, messages and a file, each in both directions.
//!
//! `tools/run-vm-nearby.sh` builds `szfriends-testnet` in a VM and sets `SZFRIENDS_VM_GUEST` to
//! `<vm>|<current user: 1 or 0>|<binary in the VM>|<a directory in the VM>`; `local` runs the guest on this Mac
//! instead, which checks the bridge alone. `SZFRIENDS_OBJC_HELPER` names the Objective-C helper. Without both, each
//! test says so and passes.

#[cfg(target_os = "macos")]
mod mac {
    use std::path::PathBuf;

    use szfriends_interop::bridge::host::{start, Guest};
    use szfriends_interop::helpers::{objc_helper, test_service_type, Client};
    use szfriends_interop::{nearby, TempHome};

    pub struct Pair {
        pub vm: Client,
        pub objc: Client,
        _homes: Vec<TempHome>,
    }

    fn guest(label: &str) -> Option<(Guest, Vec<TempHome>)> {
        let spec = std::env::var("SZFRIENDS_VM_GUEST").ok()?;
        let mut random = [0u8; 6];
        szfriends_core::crypto::random_bytes(&mut random);
        let name = format!("szf-vm-{label}-{}", hex::encode(random));
        if spec == "local" {
            let home = TempHome::new("guest");
            let binary = env!("CARGO_BIN_EXE_szfriends-testnet").to_owned();
            let path = home.path().join(name).to_string_lossy().into_owned();
            let guest = Guest { vm: String::new(), current_user: true, binary, home: path, inbound: None };
            return Some((guest, vec![home]));
        }
        let parts: Vec<&str> = spec.split('|').collect();
        let [vm, user, binary, base] = parts[..] else { return None };
        let separator = if base.contains('\\') { "\\" } else { "/" };
        let home = format!("{base}{separator}{name}");
        let guest = Guest { vm: vm.into(), current_user: user == "1", binary: binary.into(), home, inbound: None };
        Some((guest, Vec::new()))
    }

    pub fn pair(vm_name: &str, objc_name: &str) -> Option<Pair> {
        pair_inbound(vm_name, objc_name, None)
    }

    /// `inbound`: the VM helper as a computer whose firewall admits nothing (`blocked`), or as its own decides.
    pub fn pair_inbound(vm_name: &str, objc_name: &str, inbound: Option<&str>) -> Option<Pair> {
        let (Some(binary), Some((mut guest, mut homes))) =
            (std::env::var_os("SZFRIENDS_OBJC_HELPER").map(PathBuf::from), guest(vm_name))
        else {
            eprintln!("SZFRIENDS_OBJC_HELPER and SZFRIENDS_VM_GUEST are not set: tools/run-vm-nearby.sh sets them");
            return None;
        };
        guest.inbound = inbound.map(str::to_owned);
        let service_type = test_service_type();
        let objc_home = TempHome::new(objc_name);
        let mut objc = objc_helper(objc_name, &binary, &objc_home.path().join("state"), &service_type);
        homes.push(objc_home);
        let mut vm = start(vm_name, &guest, &service_type);
        nearby::start(&mut vm, vm_name, &mut objc, objc_name);
        Some(Pair { vm, objc, _homes: homes })
    }
}

#[cfg(target_os = "macos")]
use szfriends_interop::nearby;

/// A computer that accepts no connections nearby (Windows' firewall without a rule for Friends, or `blocked`
/// elsewhere) still reaches a visible Mac and talks with it, through its own dials; its Nearby says why nobody can
/// see it; and no firewall rule appears.
#[test]
fn a_computer_that_cannot_listen_reaches_the_mac() {
    #[cfg(target_os = "macos")]
    if let Some(mut p) = mac::pair_inbound("Vesna", "Moss", Some(if windows_guest() { "firewall" } else { "blocked" }))
    {
        let before = szfriends_interop::bridge::host::guest_firewall_rules(&p.vm);
        let view = p.vm.subscribe("nearby", serde_json::json!({}));
        let data = p.vm.snapshot(&view, "Nearby saying why", |d| d["note"]["text"].is_string());
        if before.is_some() || !windows_guest() {
            let blocked = data["note"]["text"].as_str().unwrap_or_default().contains("connects to friends nearby");
            assert!(blocked, "the line under the visibility setting: {data}");
            assert_eq!(data["visibility"]["state"], "unavailable");
        }
        nearby::visible_request(&mut p.vm, "Vesna", &mut p.objc, "Moss");
        let after = szfriends_interop::bridge::host::guest_firewall_rules(&p.vm);
        assert_eq!(before, after, "no firewall rule was added");
        eprintln!("inbound firewall rules in the guest: {before:?} before, {after:?} after");
    }
}

#[cfg(target_os = "macos")]
fn windows_guest() -> bool {
    std::env::var("SZFRIENDS_VM_GUEST").is_ok_and(|g| g.contains(".exe"))
}

#[test]
fn the_vm_asks_a_visible_mac() {
    #[cfg(target_os = "macos")]
    if let Some(mut p) = mac::pair("Vera", "Mona") {
        nearby::visible_request(&mut p.vm, "Vera", &mut p.objc, "Mona");
    }
}

#[test]
fn the_mac_asks_a_visible_vm() {
    #[cfg(target_os = "macos")]
    if let Some(mut p) = mac::pair("Vito", "Milo") {
        nearby::visible_request(&mut p.objc, "Milo", &mut p.vm, "Vito");
    }
}

#[test]
fn the_vm_adds_the_mac_by_id() {
    #[cfg(target_os = "macos")]
    if let Some(mut p) = mac::pair("Vida", "Maya") {
        nearby::add_by_id(&mut p.vm, &mut p.objc);
    }
}

#[test]
fn the_mac_adds_the_vm_by_id() {
    #[cfg(target_os = "macos")]
    if let Some(mut p) = mac::pair("Vlad", "Mira") {
        nearby::add_by_id(&mut p.objc, &mut p.vm);
    }
}

#[test]
fn the_mac_declines_the_vm() {
    #[cfg(target_os = "macos")]
    if let Some(mut p) = mac::pair("Vic", "Max") {
        nearby::declined(&mut p.vm, "Vic", &mut p.objc, "Max");
    }
}

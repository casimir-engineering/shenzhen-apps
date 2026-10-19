//! Real mDNS on Linux (`mdns-sd`, the backend a person's Linux helper uses), between two Rust helpers, on a network
//! of their own: the test runs itself again inside a new network namespace (`unshare --net`) whose only interface is
//! loopback with multicast turned on, so nothing reaches any real network. Then the nearby scenarios run as they do
//! on the test network of entries: someone visible found and asked, accepted, messages and a file; Add by ID.
//!
//! Needs root (a namespace and its routes); the Linux VM runs as root (`run-device-tests.sh linux-vm` with
//! `SZFRIENDS_VM_AS_ROOT=1`). Elsewhere the test says why it skips, and fails instead when
//! `SZFRIENDS_REQUIRE_SYSTEM_TESTS=1`.

#[cfg(target_os = "linux")]
mod linux {
    use std::process::Command;

    use szfriends_interop::helpers::{rust_helper, test_service_type};
    use szfriends_interop::{nearby, TempHome};

    const INSIDE: &str = "SZFRIENDS_IN_TEST_NETNS";

    fn skip(why: &str) {
        assert!(std::env::var_os("SZFRIENDS_REQUIRE_SYSTEM_TESTS").is_none(), "required, but {why}");
        eprintln!("skipped: {why}");
    }

    /// Runs `test` again in a fresh network namespace; `true` when this process is the one inside.
    pub fn in_namespace(test: &str) -> bool {
        if std::env::var_os(INSIDE).is_some() {
            return true;
        }
        if !is_root() {
            skip("a network namespace needs root");
            return false;
        }
        let exe = std::env::current_exe().expect("the test binary");
        let script = format!(
            "ip link set lo up && ip link set lo multicast on && ip route add 224.0.0.0/4 dev lo && \
             exec '{}' --exact {test} --nocapture --test-threads=1",
            exe.display()
        );
        let status = Command::new("unshare").args(["--net", "--", "sh", "-c", &script]).env(INSIDE, "1").status();
        match status {
            Ok(status) => assert!(status.success(), "the test inside the namespace failed: {status}"),
            Err(error) => skip(&format!("unshare: {error}")),
        }
        false
    }

    fn is_root() -> bool {
        Command::new("id").arg("-u").output().is_ok_and(|o| o.stdout.starts_with(b"0"))
    }

    fn pair(
        names: (&str, &str),
    ) -> (Vec<TempHome>, szfriends_interop::helpers::Client, szfriends_interop::helpers::Client) {
        let homes = vec![TempHome::new(names.0), TempHome::new(names.1)];
        std::env::set_var("SZFRIENDS_STATE_DIR", homes[0].path());
        std::env::remove_var("SZFRIENDS_TEST_LOOPBACK");
        std::env::set_var("SZFRIENDS_TEST_SERVICE_TYPE", test_service_type());
        let mut a = rust_helper(names.0, &homes[0].path().join("state"));
        let mut b = rust_helper(names.1, &homes[1].path().join("state"));
        nearby::start(&mut a, names.0, &mut b, names.1);
        (homes, a, b)
    }

    pub fn visible() {
        let (_homes, mut lin, mut lou) = pair(("Lin", "Lou"));
        nearby::visible_request(&mut lin, "Lin", &mut lou, "Lou");
    }

    pub fn by_id() {
        let (_homes, mut lea, mut leo) = pair(("Lea", "Leo"));
        nearby::add_by_id(&mut lea, &mut leo);
    }
}

#[test]
fn mdns_visible_request() {
    #[cfg(target_os = "linux")]
    if linux::in_namespace("mdns_visible_request") {
        linux::visible();
    }
}

#[test]
fn mdns_add_by_id() {
    #[cfg(target_os = "linux")]
    if linux::in_namespace("mdns_add_by_id") {
        linux::by_id();
    }
}

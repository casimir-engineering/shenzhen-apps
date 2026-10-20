//! Linux: the socket's peer checks between two real users, a helper that outlives the AppImage-style mount its app
//! ran from, and the system services the helper uses (logind's sleep signal, the Secret Service, rtnetlink), each
//! against a private instance: a private D-Bus daemon, a throwaway keyring, a network namespace of the test's own.
//! A test that needs what this machine lacks (root, `setpriv`, `dbus-daemon`, `gnome-keyring-daemon`, `unshare`)
//! says so and passes without checking, unless `SZFRIENDS_REQUIRE_SYSTEM_TESTS=1`: then a skip fails. The VM run
//! (`tools/run-device-tests.sh linux-vm`, as root) sets it, so none of these passes there without checking.

#![cfg(target_os = "linux")]

mod desktop;

use std::io::{Read, Write};
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

use desktop::{eventually, hello, helper_binary, lock_is_free, process_image, wait_exit, Scratch};
use szfriends_helper::client::{connect_or_spawn, ConnectError};
use szfriends_helper::copy::EmbeddedHelper;
use szfriends_helper::linux::dbus::Bus;
use szfriends_helper::linux::ipc::{checked, helper_socket};
use szfriends_helper::linux::keystore::{Backend, LinuxKeyStore};
use szfriends_helper::linux::marshal::Value;
use szfriends_helper::linux::secret_service::SecretService;
use szfriends_helper::linux::{file_manager, logind, netlink};
use szfriends_identity::keystore::{IdentityManager, KeyStore, StoreIdentity};
use szfriends_identity::IdentityError;

const NOBODY: u32 = 65534;

fn is_root() -> bool {
    rustix::process::geteuid().is_root()
}

fn have(tool: &str) -> bool {
    Command::new("sh")
        .args(["-c", &format!("command -v {tool}")])
        .stdout(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

fn skip(why: &str) {
    if std::env::var_os("SZFRIENDS_REQUIRE_SYSTEM_TESTS").is_some_and(|v| v == "1") {
        panic!("SZFRIENDS_REQUIRE_SYSTEM_TESTS=1, but this test {why}");
    }
    eprintln!("skipped: {why}");
}

#[test]
fn another_users_helper_and_another_users_client_are_refused() {
    if !is_root() || !have("setpriv") {
        return skip("needs root and setpriv to run a helper as another user");
    }
    let scratch = Scratch::new("peers");
    std::fs::set_permissions(&scratch.0, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let state = scratch.state();
    std::fs::create_dir(&state.path).unwrap();
    rustix::fs::chown(&state.path, Some(rustix::process::Uid::from_raw(NOBODY)), None).unwrap();
    let mut helper: Child = Command::new("setpriv")
        .args(["--reuid", &NOBODY.to_string(), "--regid", &NOBODY.to_string(), "--clear-groups", "--"])
        .arg(helper_binary())
        .env("SZFRIENDS_STATE_DIR", &state.path)
        .env("SZFRIENDS_DOWNLOADS_DIR", state.path.join("Downloads"))
        .env("SZFRIENDS_HELPER_TIME_SCALE", "0.2")
        .stdin(Stdio::null())
        .spawn()
        .unwrap();
    let socket = helper_socket(&state).unwrap();
    assert!(eventually(Duration::from_secs(10), || socket.exists()), "the other user's helper listens");

    // Root can open any directory, so it reaches the socket; the helper, running as someone else, sees uid 0 and
    // closes the connection without a word.
    let mut stranger = UnixStream::connect(&socket).unwrap();
    stranger.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let _ = stranger.write_all(b"{\"type\":\"hello\",\"id\":\"1\"}\n");
    let mut answer = Vec::new();
    let _ = stranger.read_to_end(&mut answer);
    assert!(answer.is_empty(), "not a byte back: {:?}", String::from_utf8_lossy(&answer));

    // And root's client refuses that helper before sending anything: the directory is not root's, and the peer
    // check alone refuses it too.
    assert!(matches!(szfriends_helper::client::connect(&state), Err(ConnectError::Refused("unsafe_directory"))));
    let raw = UnixStream::connect(&socket).unwrap();
    assert!(matches!(checked(raw), Err(ConnectError::Refused("peer_uid"))));
    assert!(wait_exit(&mut helper, Duration::from_secs(20)).expect("it leaves (nobody of its own came)").success());
}

#[test]
fn a_helper_outlives_the_appimage_mount_it_came_from() {
    if !is_root() || !have("mount") {
        return skip("needs root to mount a filesystem standing in for an AppImage's");
    }
    desktop::init();
    let scratch = Scratch::new("appimage");
    let state = scratch.state();
    let mount = scratch.0.join("mount");
    std::fs::create_dir(&mount).unwrap();
    // Room for the helper as built (a debug build with every feature is larger than a release).
    let megabytes = std::fs::metadata(helper_binary()).unwrap().len() / (1 << 20) + 16;
    let size = format!("size={}m", megabytes.max(64));
    let mounted = Command::new("mount").args(["-t", "tmpfs", "-o", &size, "szfriends-app"]).arg(&mount).status();
    assert!(mounted.unwrap().success(), "tmpfs mounted");
    let inside = mount.join("szfriends-helper");
    std::fs::copy(helper_binary(), &inside).unwrap();
    let embedded = EmbeddedHelper::inspect(&inside).unwrap();
    let mut app = connect_or_spawn(&state, &embedded, Duration::from_secs(15)).expect("spawned from the mount");
    let pid = hello(&mut app, Some(&embedded.stamp))["helper"]["pid"].as_u64().unwrap() as u32;
    let image = process_image(pid).unwrap();
    assert!(image.starts_with(state.path.join("helper")), "runs from the per-user copy: {}", image.display());

    // The app quits and its mount goes away, as an AppImage's does.
    drop(app);
    let unmounted = Command::new("umount").arg(&mount).status().unwrap();
    assert!(unmounted.success(), "nothing of the helper's kept the mount busy");
    assert!(!inside.exists());
    let mut later = desktop::wait_connect(&state, Duration::from_secs(5));
    assert_eq!(hello(&mut later, None)["helper"]["pid"], pid, "the same helper still serves");
    later.close();
    assert!(eventually(Duration::from_secs(10), || lock_is_free(&state)));
}

/// A private bus: a `dbus-daemon` of the test's own on a socket in `directory`, stopped when dropped. Its
/// configuration names no service directories, so nothing is ever started on demand: only what the test starts
/// answers.
struct PrivateBus {
    daemon: Child,
    address: String,
}

impl PrivateBus {
    fn start(directory: &Path) -> Option<Self> {
        if !have("dbus-daemon") {
            return None;
        }
        let address = format!("unix:path={}", directory.join("bus").display());
        let config = directory.join("bus.conf");
        let policy = r#"<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/>
            <allow own="*"/></policy>"#;
        let text = format!("<busconfig><type>session</type><listen>{address}</listen>{policy}</busconfig>");
        std::fs::write(&config, text).ok()?;
        let daemon = Command::new("dbus-daemon")
            .args(["--nofork", "--nopidfile", &format!("--config-file={}", config.display())])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        let up = eventually(Duration::from_secs(5), || Bus::connect(&address).is_ok());
        up.then_some(Self { daemon, address })
    }
}

impl Drop for PrivateBus {
    fn drop(&mut self) {
        // Our own child, started above.
        let _ = self.daemon.kill();
        let _ = self.daemon.wait();
    }
}

#[test]
fn sleep_and_wake_arrive_from_logind() {
    let scratch = Scratch::new("logind");
    let Some(bus) = PrivateBus::start(&scratch.0) else { return skip("needs dbus-daemon") };
    let (sender, receiver) = std::sync::mpsc::channel();
    let watcher = Bus::connect(&bus.address).unwrap();
    std::thread::spawn(move || logind::watch(watcher, None, move |sleeping| sender.send(sleeping).unwrap()));
    std::thread::sleep(Duration::from_millis(300));
    for value in ["true", "false"] {
        let sent = Command::new("dbus-send")
            .args([&format!("--bus={}", bus.address), "--type=signal", "/org/freedesktop/login1"])
            .args(["org.freedesktop.login1.Manager.PrepareForSleep", &format!("boolean:{value}")])
            .status()
            .unwrap();
        assert!(sent.success());
    }
    assert_eq!(receiver.recv_timeout(Duration::from_secs(5)), Ok(true), "before sleep");
    assert_eq!(receiver.recv_timeout(Duration::from_secs(5)), Ok(false), "after wake");
}

/// A throwaway keyring: gnome-keyring-daemon on a private bus, its files in `directory`.
fn throwaway_keyring(directory: &Path, bus: &PrivateBus) -> Option<Child> {
    if !have("gnome-keyring-daemon") {
        return None;
    }
    let home = directory.join("home");
    std::fs::create_dir_all(home.join(".local/share")).ok()?;
    let runtime = directory.join("runtime");
    std::fs::DirBuilder::new().mode(0o700).create(&runtime).ok()?;
    let mut keyring = Command::new("gnome-keyring-daemon")
        .args(["--foreground", "--unlock", "--components=secrets"])
        .env("DBUS_SESSION_BUS_ADDRESS", &bus.address)
        .env("HOME", &home)
        .env("XDG_DATA_HOME", home.join(".local/share"))
        .env("XDG_RUNTIME_DIR", &runtime)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    keyring.stdin.take()?.write_all(b"throwaway test keyring").ok()?;
    let last = std::sync::Mutex::new(String::new());
    let ready = eventually(Duration::from_secs(10), || {
        match Bus::connect(&bus.address).and_then(|b| SecretService::open_on(b, "probe")) {
            Ok(mut service) => match service.default_collection() {
                Ok(Some(_)) => true,
                other => {
                    *last.lock().unwrap() = format!("{other:?}");
                    false
                }
            },
            Err(error) => {
                *last.lock().unwrap() = error.to_string();
                false
            }
        }
    });
    if !ready {
        eprintln!("the throwaway keyring did not come up: {}", last.lock().unwrap());
    }
    if ready {
        Some(keyring)
    } else {
        let _ = keyring.kill();
        let _ = keyring.wait();
        None
    }
}

#[test]
fn the_identity_in_the_secret_service_and_the_file_fallback() {
    let scratch = Scratch::new("secrets");
    let Some(bus) = PrivateBus::start(&scratch.0) else { return skip("needs dbus-daemon") };
    let Some(mut keyring) = throwaway_keyring(&scratch.0, &bus) else { return skip("needs gnome-keyring-daemon") };
    let address = bus.address.clone();
    let connect = move || SecretService::open_on(Bus::connect(&address)?, "test-scope");
    let state = scratch.0.join("state");
    std::fs::create_dir_all(&state).unwrap();
    let store = LinuxKeyStore::with_connector(state.clone(), Box::new(connect.clone()));

    assert_eq!(store.secret("identity"), Ok(None));
    let manager = IdentityManager::new(store);
    let (identity, _) = manager.load_or_create(StoreIdentity::NoStore).expect("created in the keyring");
    let store = LinuxKeyStore::with_connector(state.clone(), Box::new(connect.clone()));
    assert_eq!(store.backend(), Ok(Some(Backend::SecretService)), "the choice is recorded");
    assert!(!state.join("keys").join("identity").exists(), "no file key beside it");
    assert_eq!(store.store("identity", b"other"), Err(IdentityError::StoreFailed), "never replaced");
    let (loaded, _) =
        IdentityManager::new(store).load_or_create(StoreIdentity::Recorded(identity.public_key())).unwrap();
    assert_eq!(loaded.public_key(), identity.public_key());

    // A locked keyring is unavailable, never absent.
    connect().unwrap().lock_default_collection().unwrap();
    let store = LinuxKeyStore::with_connector(state.clone(), Box::new(connect.clone()));
    assert_eq!(store.secret("identity"), Err(IdentityError::Unavailable));

    // The Secret Service gone later: still unavailable, so no second identity is made.
    let _ = keyring.kill();
    let _ = keyring.wait();
    let gone = LinuxKeyStore::with_connector(state.clone(), Box::new(connect));
    assert_eq!(gone.secret("identity"), Err(IdentityError::Unavailable));
    assert_eq!(
        IdentityManager::new(gone).load_or_create(StoreIdentity::NoStore).unwrap_err(),
        IdentityError::Unavailable
    );

    // Where no Secret Service ever ran: the 0600 file, recorded as such.
    let elsewhere = scratch.0.join("no-keyring");
    std::fs::create_dir_all(&elsewhere).unwrap();
    let nowhere = || SecretService::open_on(Bus::connect("unix:path=/nonexistent/bus")?, "x");
    let store = LinuxKeyStore::with_connector(elsewhere.clone(), Box::new(nowhere));
    IdentityManager::new(store).load_or_create(StoreIdentity::NoStore).expect("created in a file");
    let store = LinuxKeyStore::with_connector(elsewhere.clone(), Box::new(nowhere));
    assert_eq!(store.backend(), Ok(Some(Backend::File)));
    let mode = std::os::unix::fs::PermissionsExt::mode(
        &std::fs::metadata(elsewhere.join("keys/identity")).unwrap().permissions(),
    );
    assert_eq!(mode & 0o777, 0o600);
}

#[test]
fn network_changes_arrive_from_rtnetlink() {
    if std::env::var_os("SZFRIENDS_NETLINK_CHILD").is_some() {
        // In a network namespace of our own: bringing its loopback up is a link and an address change.
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::spawn(move || netlink::watch(move || sender.send(()).unwrap()));
        std::thread::sleep(Duration::from_millis(200));
        assert!(Command::new("ip").args(["link", "set", "lo", "up"]).status().unwrap().success());
        assert_eq!(receiver.recv_timeout(Duration::from_secs(5)), Ok(()));
        return;
    }
    if !is_root() || !have("unshare") || !have("ip") {
        return skip("needs root, unshare and ip for a network namespace of its own");
    }
    let status = Command::new("unshare")
        .arg("--net")
        .arg(std::env::current_exe().unwrap())
        .args(["--exact", "network_changes_arrive_from_rtnetlink", "--nocapture"])
        .env("SZFRIENDS_NETLINK_CHILD", "1")
        .status()
        .unwrap();
    assert!(status.success(), "the namespace's own run passed");
}

/// Show in Files: the call reaches the file manager with each URI whole, commas and spaces included.
#[test]
fn show_items_reaches_the_file_manager_with_each_name_whole() {
    let scratch = Scratch::new("file-manager");
    let Some(bus) = PrivateBus::start(&scratch.0) else { return skip("needs dbus-daemon") };
    let mut manager = Bus::connect(&bus.address).unwrap();
    let owned = manager.call(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "RequestName",
        &[Value::Str(file_manager::NAME.into()), Value::U32(4)],
    );
    assert_eq!(owned.unwrap(), vec![Value::U32(1)], "the stand-in file manager owns the name");
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        while let Ok(message) = manager.next_message() {
            if message.member.as_deref() == Some("ShowItems") {
                let _ = sender.send(message);
                return;
            }
        }
    });
    let uri = "file:///home/mei/Received/Gear,box%20(v2),final.stl".to_owned();
    let mut app = Bus::connect(&bus.address).unwrap();
    // The stand-in never answers, so the call itself times out; what arrived is what counts.
    app.set_timeout(Some(Duration::from_millis(500))).unwrap();
    let _ = file_manager::show_items(&mut app, std::slice::from_ref(&uri));
    let call = receiver.recv_timeout(Duration::from_secs(5)).expect("the file manager was asked");
    assert_eq!(call.path.as_deref(), Some(file_manager::PATH));
    assert_eq!(call.interface.as_deref(), Some(file_manager::NAME));
    assert_eq!(call.body, vec![Value::Array("s".into(), vec![Value::Str(uri)]), Value::Str(String::new())]);
}

//! Windows: ADR 0015 § 8's pipe test plan, the cases one account can stage (the other account's squatter and the
//! foreign owner need a second principal and run from `tests/vm/windows-pipe-plan.sh`): a forged advertised name, a
//! name still advertised after its helper left and squatted since, a second helper without the lock, a remote
//! client; and the DPAPI key store's rules.

#![cfg(windows)]

mod desktop;

use std::io::Read;
use std::sync::mpsc::channel;
use std::time::Duration;

use desktop::{hello, helper_binary, start, wait_connect, wait_exit, Scratch};
use szfriends_contract::pipe::{advertised_name_path, lock_owner_line, lock_path, pipe_name, Sid};
use szfriends_helper::client::{connect, ConnectError};
use szfriends_helper::windows::ipc::own_token;
use szfriends_helper::windows::keystore::DpapiKeyStore;
use szfriends_helper_sys::pipe::{PipeListener, PipeStream};
use szfriends_identity::keystore::{IdentityManager, KeyStore, StoreIdentity};
use szfriends_identity::IdentityError;

fn advertise(state: &szfriends_helper::state::StateDir, name: &str, holder: u32) {
    std::fs::create_dir_all(state.path.join("ipc")).unwrap();
    std::fs::write(advertised_name_path(&state.path), format!("{name}\n")).unwrap();
    std::fs::write(lock_path(&state.path), lock_owner_line(holder)).unwrap();
}

#[test]
fn a_forged_advertised_name_is_never_opened() {
    let scratch = Scratch::new("forged");
    let state = scratch.state();
    let own = own_token().expect("this process's token");
    let other_user = Sid::parse("S-1-5-21-1-2-3-1001").unwrap();
    let nonce = [7u8; 16];
    for name in [
        pipe_name(&other_user, &state.canonical, &nonce),
        pipe_name(&own.user, r"C:\elsewhere", &nonce),
        r"\\.\pipe\szfriends-helper".to_owned(),
        format!(r"\\otherpc\pipe\{}", &pipe_name(&own.user, &state.canonical, &nonce)[9..]),
    ] {
        advertise(&state, &name, std::process::id());
        assert!(matches!(connect(&state), Err(ConnectError::Refused("advertised_name"))), "{name}");
    }
}

#[test]
fn a_name_left_behind_and_squatted_is_refused_before_a_byte() {
    let scratch = Scratch::new("stale");
    let state = scratch.state();
    let mut helper = start(&helper_binary(), &state, &[]);
    let mut client = wait_connect(&state, Duration::from_secs(10));
    let old_pid = hello(&mut client, None)["helper"]["pid"].as_u64().unwrap() as u32;
    let name = std::fs::read_to_string(advertised_name_path(&state.path)).unwrap().trim_end().to_owned();
    client.close();
    assert!(wait_exit(&mut helper, Duration::from_secs(10)).unwrap().success());

    // Someone of the same user takes the name the helper left, and the files still point at it.
    let own = own_token().unwrap();
    let sid = own.user.as_str();
    let squatter = PipeListener::create(&name, &format!("O:{sid}D:P(A;;GA;;;{sid})")).expect("the name is free now");
    advertise(&state, &name, old_pid);
    let (sender, received) = channel();
    std::thread::spawn(move || {
        let stream = squatter.accept().unwrap().unwrap();
        let mut bytes = Vec::new();
        let mut buffer = [0u8; 256];
        while let Ok(n) = stream.read(&mut buffer) {
            if n == 0 {
                break;
            }
            bytes.extend_from_slice(&buffer[..n]);
        }
        sender.send(bytes).unwrap();
    });
    assert!(matches!(connect(&state), Err(ConnectError::Refused("not_lock_owner"))));
    assert_eq!(received.recv_timeout(Duration::from_secs(5)).unwrap(), b"", "the squatter got nothing");
}

#[test]
fn a_second_helper_without_the_lock_creates_no_pipe() {
    let scratch = Scratch::new("second");
    let state = scratch.state();
    let mut first = start(&helper_binary(), &state, &[]);
    let mut client = wait_connect(&state, Duration::from_secs(10));
    hello(&mut client, None);
    let advertised = std::fs::read_to_string(advertised_name_path(&state.path)).unwrap();
    let own = own_token().unwrap();
    // This state directory's pipes only: other tests' helpers run beside this one.
    let sample = pipe_name(&own.user, &state.canonical, &[0; 16]);
    let prefix = sample[r"\\.\pipe\".len()..sample.len() - 32].to_owned();
    let ours = |name: &str| name.starts_with(&prefix);
    let pipes = || -> Vec<String> {
        std::fs::read_dir(r"\\.\pipe\").unwrap().filter_map(|e| e.ok()?.file_name().into_string().ok()).collect()
    };
    let before: Vec<String> = pipes().into_iter().filter(|n| ours(n)).collect();

    let mut second = start(&helper_binary(), &state, &[]);
    assert!(wait_exit(&mut second, Duration::from_secs(10)).expect("leaves at once").success());
    assert_eq!(std::fs::read_to_string(advertised_name_path(&state.path)).unwrap(), advertised, "untouched");
    let after: Vec<String> = pipes().into_iter().filter(|n| ours(n)).collect();
    assert_eq!(after, before, "no pipe of its own");
    assert_eq!(before.len(), 1, "one pipe: the helper's");
    assert!(advertised.trim_end().ends_with(before[0].as_str()));

    // A remote client (the same PC through the network redirector) is rejected by the pipe itself.
    let remote = format!(r"\\127.0.0.1\pipe\{}", &advertised.trim_end()[r"\\.\pipe\".len()..]);
    assert!(PipeStream::connect(&remote, Duration::from_secs(5)).is_err(), "{remote}");
    client.close();
    assert!(wait_exit(&mut first, Duration::from_secs(10)).unwrap().success());
}

#[test]
fn the_identity_in_a_dpapi_file() {
    let scratch = Scratch::new("dpapi");
    let keys = scratch.0.join("keys");
    let manager = IdentityManager::new(DpapiKeyStore::new(&keys));
    let (identity, _) = manager.load_or_create(StoreIdentity::NoStore).expect("created");
    let store = DpapiKeyStore::new(&keys);
    let item = store.secret("identity").unwrap().expect("reads back");
    assert_eq!(item.len(), 133);
    let mut file = Vec::new();
    std::fs::File::open(keys.join("identity.dpapi")).unwrap().read_to_end(&mut file).unwrap();
    assert!(!file.windows(32).any(|w| w == &item[..32]), "the file holds no plain key bytes");
    assert_eq!(store.store("identity", b"another"), Err(IdentityError::StoreFailed), "never replaced");

    // Bound to its name: the same blob under another name does not open.
    std::fs::copy(keys.join("identity.dpapi"), keys.join("other.dpapi")).unwrap();
    assert_eq!(store.secret("other"), Err(IdentityError::Unavailable));
    // Damaged: unavailable, and the identity is not replaced.
    let mut damaged = file.clone();
    let middle = damaged.len() / 2;
    damaged[middle] ^= 1;
    std::fs::write(keys.join("identity.dpapi"), &damaged).unwrap();
    let manager = IdentityManager::new(DpapiKeyStore::new(&keys));
    assert_eq!(manager.load_or_create(StoreIdentity::NoStore).unwrap_err(), IdentityError::Unavailable);
    std::fs::write(keys.join("identity.dpapi"), &file).unwrap();
    let (loaded, _) = manager.load_or_create(StoreIdentity::Recorded(identity.public_key())).unwrap();
    assert_eq!(loaded.public_key(), identity.public_key());

    // An interrupted store's empty claim is no secret, and is taken back.
    std::fs::write(keys.join("fresh.dpapi"), b"").unwrap();
    assert_eq!(store.secret("fresh"), Ok(None));
    store.store("fresh", b"secret").unwrap();
    assert_eq!(store.secret("fresh").unwrap().unwrap().as_slice(), b"secret");
    store.delete("fresh").unwrap();
    assert_eq!(store.secret("fresh"), Ok(None));
}

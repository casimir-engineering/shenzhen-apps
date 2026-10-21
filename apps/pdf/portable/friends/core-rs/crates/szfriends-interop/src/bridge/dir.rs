//! The test network's directory joined to Bonjour on lo0 (`szfriends-testnet dir <routes> <service type>`): Rust helpers
//! and phones whose entries are files in `<routes>` (the loopback test network, `SZFRIENDS_TEST_LOOPBACK`) and the
//! Objective-C helper's test adapter, which registers and browses `<service type>` on lo0, meet as if on one network.
//! Every port involved is a loopback port on this Mac (a phone's reaches it through `adb forward`), so only the entries
//! cross: each Bonjour instance is written into the directory, and each file there not written by this bridge is
//! registered on Bonjour, both with their names, ports and TXT fields. Runs until its standard input ends.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use szfriends_helper::nearby::dns_sd_cli::DnsSdCli;
use szfriends_helper::nearby::dnssd::{BrowseEvent, DnsSd};
use szfriends_helper::nearby::registry::{read_entries, remove_entry, write_entry, Entry};

struct Shared {
    routes: PathBuf,
    /// Names this bridge wrote into the directory (from Bonjour), never registered back.
    written: HashSet<String>,
    /// Names this bridge registered on Bonjour (from the directory), never written back, with what was registered.
    registered: HashMap<String, Entry>,
}

/// Runs the bridge; returns the process's exit code.
pub fn run(routes: &Path, service_type: &str) -> i32 {
    if std::fs::create_dir_all(routes).is_err() {
        eprintln!("szfriends-testnet dir: no directory {}", routes.display());
        return 1;
    }
    let shared =
        Arc::new(Mutex::new(Shared { routes: routes.to_owned(), written: HashSet::new(), registered: HashMap::new() }));
    let bonjour = Arc::new(Mutex::new(DnsSdCli::new(service_type)));
    let browsing = shared.clone();
    let browsed = bonjour.lock().unwrap_or_else(|e| e.into_inner()).browse(Box::new(move |event| {
        let mut state = browsing.lock().unwrap_or_else(|e| e.into_inner());
        match event {
            BrowseEvent::Found { name, addresses, txt } => {
                if state.registered.contains_key(&name) {
                    return;
                }
                let Some(port) =
                    addresses.iter().find(|a| a.ip().is_loopback()).or(addresses.first()).map(|a| a.port())
                else {
                    return;
                };
                let txt = txt.into_iter().map(|(k, v)| (k, String::from_utf8_lossy(&v).into_owned())).collect();
                if write_entry(&state.routes, &Entry { name: name.clone(), port, txt }).is_ok() {
                    state.written.insert(name);
                }
            }
            BrowseEvent::Lost { name } if state.written.remove(&name) => remove_entry(&state.routes, &name),
            _ => {}
        }
    }));
    if let Err(error) = browsed {
        eprintln!("szfriends-testnet dir: browsing Bonjour on lo0: {error}");
        return 1;
    }
    let polling = shared.clone();
    let registering = bonjour.clone();
    std::thread::spawn(move || loop {
        let routes = polling.lock().unwrap_or_else(|e| e.into_inner()).routes.clone();
        let present = read_entries(&routes);
        let mut state = polling.lock().unwrap_or_else(|e| e.into_inner());
        for (name, entry) in &present {
            if state.written.contains(name) || state.registered.get(name) == Some(entry) {
                continue;
            }
            let mut bonjour = registering.lock().unwrap_or_else(|e| e.into_inner());
            if state.registered.contains_key(name) {
                bonjour.unregister(name);
            }
            if bonjour.register(name, entry.port, &entry.txt).is_ok() {
                state.registered.insert(name.clone(), entry.clone());
            }
        }
        let gone: Vec<String> = state.registered.keys().filter(|n| !present.contains_key(*n)).cloned().collect();
        for name in gone {
            registering.lock().unwrap_or_else(|e| e.into_inner()).unregister(&name);
            state.registered.remove(&name);
        }
        drop(state);
        std::thread::sleep(Duration::from_millis(200));
    });
    // Until the input ends: then everything this bridge put anywhere is taken back.
    let mut sink = String::new();
    while std::io::stdin().read_line(&mut sink).map(|n| n > 0).unwrap_or(false) {
        sink.clear();
    }
    let state = shared.lock().unwrap_or_else(|e| e.into_inner());
    for name in &state.written {
        remove_entry(&state.routes, name);
    }
    bonjour.lock().unwrap_or_else(|e| e.into_inner()).stop();
    0
}

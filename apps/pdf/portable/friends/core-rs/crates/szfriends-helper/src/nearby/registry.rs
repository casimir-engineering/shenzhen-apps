//! A test network of DNS-SD entries without DNS-SD: a directory the test made, one file per registered instance, on
//! loopback only. Several helpers (and the bridge to a VM's test network, `szfriends-testnet`) meet there exactly as
//! they would on mDNS, with the same names, ports and TXT fields, so everything above the backend runs unchanged.
//!
//! An entry is `<name>.entry`: JSON `{"name", "port", "txt": [[key, value], ...]}`, written to a temporary name and
//! renamed, so a reader never sees half of one. Browsing polls the directory.

use std::collections::HashMap;
use std::io;
use std::net::{Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Value};

use super::dnssd::{BrowseEvent, BrowseSink, DnsSd};

const POLL: Duration = Duration::from_millis(150);
const SUFFIX: &str = ".entry";

/// One instance as the directory holds it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    pub port: u16,
    pub txt: Vec<(String, String)>,
}

impl Entry {
    pub fn to_json(&self) -> Value {
        json!({"name": self.name, "port": self.port, "txt": self.txt})
    }

    pub fn from_json(value: &Value) -> Option<Self> {
        let name = value["name"].as_str()?.to_owned();
        let port = u16::try_from(value["port"].as_u64()?).ok()?;
        let mut txt = Vec::new();
        for pair in value["txt"].as_array()? {
            txt.push((pair[0].as_str()?.to_owned(), pair[1].as_str()?.to_owned()));
        }
        Some(Self { name, port, txt })
    }
}

fn valid_name(name: &str) -> bool {
    !name.is_empty() && name.len() <= 63 && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// Writes `entry` into `directory` atomically.
pub fn write_entry(directory: &Path, entry: &Entry) -> io::Result<()> {
    if !valid_name(&entry.name) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "instance name"));
    }
    write_atomically(directory, &format!("{}{SUFFIX}", entry.name), entry.to_json().to_string().as_bytes())
}

/// Writes `file` in `directory` through a temporary name, so a reader never sees half of it.
pub fn write_atomically(directory: &Path, file: &str, contents: &[u8]) -> io::Result<()> {
    static WRITES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let write = WRITES.fetch_add(1, Ordering::SeqCst);
    let temporary = directory.join(format!(".{file}.{}.{write}.tmp", std::process::id()));
    std::fs::write(&temporary, contents)?;
    let target = directory.join(file);
    // Windows refuses to replace a file someone holds open without delete sharing (a reader, the scanner looking at
    // what was just written) for a moment: try again rather than leave the old entry in place.
    let mut attempt = 0;
    loop {
        match std::fs::rename(&temporary, &target) {
            Err(_) if attempt < 40 => {
                attempt += 1;
                std::thread::sleep(std::time::Duration::from_millis(25));
            }
            Err(error) => {
                let _ = std::fs::remove_file(&temporary);
                return Err(error);
            }
            Ok(()) => return Ok(()),
        }
    }
}

pub fn remove_entry(directory: &Path, name: &str) {
    if valid_name(name) {
        let _ = std::fs::remove_file(directory.join(format!("{name}{SUFFIX}")));
    }
}

/// Every entry in `directory` now.
pub fn read_entries(directory: &Path) -> HashMap<String, Entry> {
    let mut entries = HashMap::new();
    let Ok(listing) = std::fs::read_dir(directory) else { return entries };
    for item in listing.flatten() {
        let file = item.file_name();
        let Some(name) = file.to_str().and_then(|f| f.strip_suffix(SUFFIX)) else { continue };
        if !valid_name(name) {
            continue;
        }
        let text = std::fs::read_to_string(item.path()).unwrap_or_default();
        if let Some(entry) = serde_json::from_str(&text).ok().as_ref().and_then(Entry::from_json) {
            if entry.name == name {
                entries.insert(entry.name.clone(), entry);
            }
        }
    }
    entries
}

/// See the module documentation.
#[derive(Debug)]
pub struct Registry {
    directory: PathBuf,
    registered: Vec<String>,
    browsing: Option<Arc<AtomicBool>>,
}

impl Registry {
    pub fn new(directory: PathBuf) -> Self {
        Self { directory, registered: Vec::new(), browsing: None }
    }
}

fn browse_loop(directory: PathBuf, stop: Arc<AtomicBool>, sink: BrowseSink) {
    sink(BrowseEvent::Ready);
    let mut known: HashMap<String, Entry> = HashMap::new();
    while !stop.load(Ordering::SeqCst) {
        let now = read_entries(&directory);
        for (name, entry) in &now {
            if known.get(name) == Some(entry) {
                continue;
            }
            let addresses = vec![SocketAddr::from((Ipv4Addr::LOCALHOST, entry.port))];
            let txt = entry.txt.iter().map(|(k, v)| (k.clone(), v.clone().into_bytes())).collect();
            sink(BrowseEvent::Found { name: name.clone(), addresses, txt });
        }
        for name in known.keys().filter(|name| !now.contains_key(*name)) {
            sink(BrowseEvent::Lost { name: name.clone() });
        }
        known = now;
        std::thread::sleep(POLL);
    }
}

impl DnsSd for Registry {
    fn browse(&mut self, sink: BrowseSink) -> io::Result<()> {
        if let Some(stop) = self.browsing.take() {
            stop.store(true, Ordering::SeqCst);
        }
        let stop = Arc::new(AtomicBool::new(false));
        self.browsing = Some(stop.clone());
        let directory = self.directory.clone();
        std::thread::Builder::new()
            .name("szfriends-registry".into())
            .spawn(move || browse_loop(directory, stop, sink))?;
        Ok(())
    }

    fn register(&mut self, name: &str, port: u16, txt: &[(String, String)]) -> io::Result<()> {
        write_entry(&self.directory, &Entry { name: name.to_owned(), port, txt: txt.to_vec() })?;
        if !self.registered.iter().any(|n| n == name) {
            self.registered.push(name.to_owned());
        }
        Ok(())
    }

    fn unregister(&mut self, name: &str) {
        remove_entry(&self.directory, name);
        self.registered.retain(|n| n != name);
    }

    fn stop(&mut self) {
        if let Some(stop) = self.browsing.take() {
            stop.store(true, Ordering::SeqCst);
        }
        for name in std::mem::take(&mut self.registered) {
            remove_entry(&self.directory, &name);
        }
    }
}

impl Drop for Registry {
    fn drop(&mut self) {
        self.stop();
    }
}

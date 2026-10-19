//! On a Mac, test homes only: the system's Bonjour on loopback through the `dns-sd` tool (`-i lo0`, the interface the
//! Objective-C helper's loopback test adapter registers and browses on), so a Rust helper under test meets the
//! Objective-C helper's test entries (`SZFRIENDS_TEST_SERVICE_TYPE`) without a socket of its own on any network. The
//! Rust helper never runs on a Mac otherwise (ADR 0015 § 2).
//!
//! `dns-sd -R` registers while it runs; `-B` reports instances as they come and go; one `-L` per instance reports its
//! port and TXT and every change to them. Friends' TXT values are ASCII, so the tool's text output carries them whole.

use std::collections::HashMap;
use std::io::{self, BufRead, BufReader};
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};

use super::dnssd::{BrowseEvent, BrowseSink, DnsSd};

const TOOL: &str = "/usr/bin/dns-sd";

/// See the module documentation.
pub struct DnsSdCli {
    service_type: String,
    registrations: HashMap<String, Child>,
    browser: Option<Child>,
    resolvers: Arc<Mutex<HashMap<String, Child>>>,
}

impl std::fmt::Debug for DnsSdCli {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DnsSdCli").field("service_type", &self.service_type).finish()
    }
}

fn end(mut child: Child) {
    // Our own child, by the handle we started it with.
    let _ = child.kill();
    let _ = child.wait();
}

fn tool(args: &[&str]) -> io::Result<Child> {
    Command::new(TOOL).args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()
}

/// The instance name of a `-B` line ("Add" or "Rmv", flags, interface, domain, type, name), if it is one.
pub fn browse_line(line: &str) -> Option<(bool, String)> {
    let fields: Vec<&str> = line.split_whitespace().collect();
    let added = match fields.get(1) {
        Some(&"Add") => true,
        Some(&"Rmv") => false,
        _ => return None,
    };
    // Timestamp, A/R, flags, interface, domain, type, then the name (which may contain spaces; ours do not).
    (fields.len() >= 7).then(|| (added, fields[6..].join(" ")))
}

/// The port of a `-L` line ("... can be reached at host.local.:50828 (interface 1)").
pub fn port_line(line: &str) -> Option<u16> {
    let at = line.split(" can be reached at ").nth(1)?;
    let target = at.split_whitespace().next()?;
    target.rsplit(':').next()?.parse().ok()
}

/// The TXT pairs of a `-L` TXT line (" v=1 t=0102... c=..."): ASCII `key=value` words.
pub fn txt_line(line: &str) -> Vec<(String, Vec<u8>)> {
    line.split_whitespace()
        .filter_map(|word| word.split_once('='))
        .map(|(key, value)| (key.to_owned(), value.as_bytes().to_vec()))
        .collect()
}

fn resolve(service_type: String, name: String, sink: Arc<BrowseSink>, resolvers: Arc<Mutex<HashMap<String, Child>>>) {
    let Ok(mut child) = tool(&["-i", "lo0", "-L", &name, &service_type, "local"]) else { return };
    let Some(stdout) = child.stdout.take() else { return };
    if let Some(old) = resolvers.lock().unwrap_or_else(|e| e.into_inner()).insert(name.clone(), child) {
        end(old);
    }
    let mut port = None;
    for line in BufReader::new(stdout).lines().map_while(Result::ok) {
        if let Some(found) = port_line(&line) {
            port = Some(found);
            continue;
        }
        let Some(port) = port.take() else { continue };
        let txt = txt_line(&line);
        // Both loopback addresses: the entry is on lo0, and its listener may be on either.
        let addresses =
            vec![SocketAddr::from((Ipv4Addr::LOCALHOST, port)), SocketAddr::from((Ipv6Addr::LOCALHOST, port))];
        sink(BrowseEvent::Found { name: name.clone(), addresses, txt });
    }
}

impl DnsSdCli {
    pub fn new(service_type: &str) -> Self {
        Self {
            service_type: service_type.to_owned(),
            registrations: HashMap::new(),
            browser: None,
            resolvers: Arc::new(Mutex::new(HashMap::new())),
        }
    }
}

impl DnsSd for DnsSdCli {
    fn browse(&mut self, sink: BrowseSink) -> io::Result<()> {
        if let Some(old) = self.browser.take() {
            end(old);
        }
        let mut child = tool(&["-i", "lo0", "-B", &self.service_type, "local"])?;
        let stdout = child.stdout.take().ok_or_else(|| io::Error::other("no output"))?;
        self.browser = Some(child);
        let sink = Arc::new(sink);
        let (service_type, resolvers) = (self.service_type.clone(), self.resolvers.clone());
        std::thread::Builder::new().name("szfriends-dns-sd".into()).spawn(move || {
            sink(BrowseEvent::Ready);
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                let Some((added, name)) = browse_line(&line) else { continue };
                if added {
                    let (service_type, sink, resolvers) = (service_type.clone(), sink.clone(), resolvers.clone());
                    std::thread::spawn(move || resolve(service_type, name, sink, resolvers));
                } else {
                    if let Some(child) = resolvers.lock().unwrap_or_else(|e| e.into_inner()).remove(&name) {
                        end(child);
                    }
                    sink(BrowseEvent::Lost { name });
                }
            }
        })?;
        Ok(())
    }

    fn register(&mut self, name: &str, port: u16, txt: &[(String, String)]) -> io::Result<()> {
        let port = port.to_string();
        let pairs: Vec<String> = txt.iter().map(|(k, v)| format!("{k}={v}")).collect();
        let mut args = vec!["-i", "lo0", "-R", name, &self.service_type, "local", &port];
        args.extend(pairs.iter().map(String::as_str));
        let child =
            Command::new(TOOL).args(&args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn()?;
        if let Some(old) = self.registrations.insert(name.to_owned(), child) {
            end(old);
        }
        Ok(())
    }

    fn unregister(&mut self, name: &str) {
        if let Some(child) = self.registrations.remove(name) {
            end(child);
        }
    }

    fn stop(&mut self) {
        if let Some(browser) = self.browser.take() {
            end(browser);
        }
        for (_, child) in self.registrations.drain() {
            end(child);
        }
        for (_, child) in self.resolvers.lock().unwrap_or_else(|e| e.into_inner()).drain() {
            end(child);
        }
    }
}

impl Drop for DnsSdCli {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_tools_lines() {
        let add = " 9:06:36.085  Add        2   1 local.               _szfprobe1._tcp.     b0b2957716b19c42";
        assert_eq!(browse_line(add), Some((true, "b0b2957716b19c42".into())));
        let rmv = " 9:06:40.488  Rmv        0   1 local.               _szfprobe1._tcp.     b0b2957716b19c42";
        assert_eq!(browse_line(rmv), Some((false, "b0b2957716b19c42".into())));
        assert_eq!(browse_line("Timestamp     A/R    Flags  if Domain"), None);
        let at = " 9:09:30.980  probe1._szfp._tcp.local. can be reached at Mac.local.:50828 (interface 1)";
        assert_eq!(port_line(at), Some(50828));
        let txt = txt_line(" v=1 t=0102030405060708 c=aa");
        assert_eq!(txt[1], ("t".into(), b"0102030405060708".to_vec()));
    }
}

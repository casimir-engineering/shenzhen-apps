//! A test home's Bluetooth: a [`Radio`] over a directory the test made, on loopback only, so the Bluetooth adapter,
//! its presence values, windows and channels run end to end between helpers without a radio (one computer cannot
//! discover itself, and a real radio would ask the person for access). Real radios are tested on hardware only.
//!
//! Each powered radio is `<id>.air`, JSON `{"presence": hex, "public": hex, "channels": {"<psm>": port}}`, with a
//! fresh random id each power-up as a real device's address would be. Advertising writes the values (none while
//! not advertising); scanning polls the directory and reports each device once per scan, and again when its public
//! flag changes; a read returns the file's values; a channel is a TCP listener on 127.0.0.1 whose connections
//! reach the core as platform streams, as an L2CAP channel on a phone does.

use std::collections::{BTreeMap, HashMap};
use std::io::{ErrorKind, Read, Write};
use std::net::{Ipv4Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Value};
use szfriends_core::nearby::Permission;

use super::bluetooth::{Power, Radio, RadioEvent, RadioReports};
use super::registry::write_atomically;
use super::stream::{LinkStream, PlatformStream};

/// The test air's directory (`$SZFRIENDS_TEST_BLUETOOTH`, in a test home only).
pub const ENV_TEST_BLUETOOTH: &str = "SZFRIENDS_TEST_BLUETOOTH";
/// The radio as the test wants it: `off`, `denied`, `unsupported`, or (permission only) `ask`; unset: on, allowed.
pub const ENV_TEST_BLUETOOTH_POWER: &str = "SZFRIENDS_TEST_BLUETOOTH_POWER";

const SUFFIX: &str = ".air";
const POLL: Duration = Duration::from_millis(150);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
/// LE dynamic PSMs: odd, 0x0081 to 0x00FF.
const FIRST_PSM: u16 = 0x0081;

#[derive(Debug, Default)]
struct Air {
    presence: Option<Vec<u8>>,
    public: Option<Vec<u8>>,
    channels: BTreeMap<u16, u16>,
}

/// See the module documentation.
#[derive(Debug)]
pub struct TestAir {
    directory: PathBuf,
    id: Option<String>,
    reports: Option<RadioReports>,
    air: Air,
    scanning: Option<Arc<AtomicBool>>,
    channels: HashMap<u16, Arc<AtomicBool>>,
    next_psm: u16,
}

fn setting() -> String {
    std::env::var(ENV_TEST_BLUETOOTH_POWER).unwrap_or_default()
}

fn hex_of(value: &Value) -> Option<Vec<u8>> {
    value.as_str().and_then(|text| hex::decode(text).ok())
}

fn read_air(directory: &Path, id: &str) -> Option<Air> {
    let text = std::fs::read_to_string(directory.join(format!("{id}{SUFFIX}"))).ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    let mut channels = BTreeMap::new();
    for (psm, port) in value["channels"].as_object()? {
        channels.insert(psm.parse().ok()?, u16::try_from(port.as_u64()?).ok()?);
    }
    Some(Air { presence: hex_of(&value["presence"]), public: hex_of(&value["public"]), channels })
}

/// A TCP connection as a platform stream: what it reads goes to the core, what the core writes goes out.
pub fn platform_over_tcp(stream: TcpStream) -> std::io::Result<PlatformStream> {
    stream.set_nodelay(true)?;
    let mut writer = stream.try_clone()?;
    let (platform, sender) = PlatformStream::new(Box::new(move |bytes| match bytes {
        Some(bytes) => {
            let _ = writer.write_all(&bytes);
        }
        None => {
            let _ = writer.flush();
            let _ = writer.shutdown(Shutdown::Write);
        }
    }));
    let mut reader = stream;
    std::thread::Builder::new().name("szfriends-air-read".into()).spawn(move || {
        let mut buffer = vec![0u8; 65_536];
        loop {
            match reader.read(&mut buffer) {
                Ok(n) if n > 0 => {
                    if sender.send(buffer[..n].to_vec()).is_err() {
                        return;
                    }
                }
                Err(error) if error.kind() == ErrorKind::Interrupted => {}
                _ => {
                    let _ = sender.send(Vec::new());
                    return;
                }
            }
        }
    })?;
    Ok(platform)
}

impl TestAir {
    pub fn new(directory: PathBuf) -> Self {
        Self {
            directory,
            id: None,
            reports: None,
            air: Air::default(),
            scanning: None,
            channels: HashMap::new(),
            next_psm: FIRST_PSM,
        }
    }

    fn write(&self) {
        let Some(id) = &self.id else { return };
        let channels: serde_json::Map<String, Value> =
            self.air.channels.iter().map(|(psm, port)| (psm.to_string(), json!(port))).collect();
        let value = json!({
            "presence": self.air.presence.as_ref().map(hex::encode),
            "public": self.air.public.as_ref().map(hex::encode),
            "channels": channels,
        });
        let _ = write_atomically(&self.directory, &format!("{id}{SUFFIX}"), value.to_string().as_bytes());
    }

    fn take_psm(&mut self) -> u16 {
        let psm = self.next_psm;
        self.next_psm = if psm >= 0x00FD { FIRST_PSM } else { psm + 2 };
        psm
    }
}

fn scan(directory: PathBuf, own: String, stop: Arc<AtomicBool>, reports: RadioReports) {
    let mut reported: HashMap<String, bool> = HashMap::new();
    while !stop.load(Ordering::SeqCst) {
        let ids: Vec<String> = std::fs::read_dir(&directory)
            .map(|entries| {
                let names = entries.flatten().filter_map(|e| e.file_name().into_string().ok());
                names.filter_map(|n| n.strip_suffix(SUFFIX).map(str::to_owned)).collect()
            })
            .unwrap_or_default();
        for id in ids.into_iter().filter(|id| *id != own && !id.starts_with('.')) {
            let Some(air) = read_air(&directory, &id) else { continue };
            if air.presence.is_none() {
                continue;
            }
            let public = air.public.is_some();
            if reported.get(&id) != Some(&public) {
                reported.insert(id.clone(), public);
                reports.report(RadioEvent::Discovered { peripheral: id, public });
            }
        }
        std::thread::sleep(POLL);
    }
}

fn accept(listener: TcpListener, stop: Arc<AtomicBool>, public: bool, reports: RadioReports) {
    while !stop.load(Ordering::SeqCst) {
        match listener.accept() {
            Ok((stream, from)) => {
                let Ok(()) = stream.set_nonblocking(false) else { continue };
                let Ok(platform) = platform_over_tcp(stream) else { continue };
                let stream = LinkStream::Platform(platform);
                reports.report(RadioEvent::Accepted { stream, public, peer: Some(from.ip().to_string()) });
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => std::thread::sleep(Duration::from_millis(50)),
            Err(_) => std::thread::sleep(Duration::from_millis(200)),
        }
    }
}

impl Radio for TestAir {
    fn permission(&self) -> Permission {
        match setting().as_str() {
            "denied" => Permission::Denied,
            "ask" => Permission::NotDetermined,
            _ => Permission::Allowed,
        }
    }

    fn power_up(&mut self, reports: RadioReports) {
        let power = match setting().as_str() {
            "off" => Power::Off,
            "denied" => Power::Unauthorized,
            "unsupported" => Power::Unsupported,
            _ => Power::On,
        };
        let mut id = [0u8; 6];
        szfriends_core::crypto::random_bytes(&mut id);
        self.id = Some(hex::encode(id));
        reports.report(RadioEvent::Power(power));
        self.reports = Some(reports);
    }

    fn power_down(&mut self) {
        self.stop_scanning();
        for (_, stop) in self.channels.drain() {
            stop.store(true, Ordering::SeqCst);
        }
        if let Some(id) = self.id.take() {
            let _ = std::fs::remove_file(self.directory.join(format!("{id}{SUFFIX}")));
        }
        self.air = Air::default();
        self.reports = None;
    }

    fn start_scanning(&mut self) {
        let (Some(own), Some(reports)) = (self.id.clone(), self.reports.clone()) else { return };
        self.stop_scanning();
        let stop = Arc::new(AtomicBool::new(false));
        let (directory, thread_stop) = (self.directory.clone(), stop.clone());
        let spawned = std::thread::Builder::new()
            .name("szfriends-air-scan".into())
            .spawn(move || scan(directory, own, thread_stop, reports));
        if spawned.is_ok() {
            self.scanning = Some(stop);
        }
    }

    fn stop_scanning(&mut self) {
        if let Some(stop) = self.scanning.take() {
            stop.store(true, Ordering::SeqCst);
        }
    }

    fn advertise(&mut self, presence: &[u8], public: Option<&[u8]>) {
        self.air.presence = Some(presence.to_vec());
        self.air.public = public.map(<[u8]>::to_vec);
        self.write();
    }

    fn stop_advertising(&mut self) {
        self.air.presence = None;
        self.air.public = None;
        self.write();
    }

    fn publish_channel(&mut self, public: bool) {
        let Some(reports) = self.reports.clone() else { return };
        let bound = TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
            .and_then(|listener| listener.set_nonblocking(true).map(|()| listener))
            .and_then(|listener| listener.local_addr().map(|address| (listener, address.port())));
        let Ok((listener, port)) = bound else {
            return reports.report(RadioEvent::Published { psm: 0, public });
        };
        let psm = self.take_psm();
        let stop = Arc::new(AtomicBool::new(false));
        let (thread_stop, thread_reports) = (stop.clone(), reports.clone());
        let spawned = std::thread::Builder::new()
            .name("szfriends-air-accept".into())
            .spawn(move || accept(listener, thread_stop, public, thread_reports));
        if spawned.is_err() {
            return reports.report(RadioEvent::Published { psm: 0, public });
        }
        self.channels.insert(psm, stop);
        self.air.channels.insert(psm, port);
        self.write();
        reports.report(RadioEvent::Published { psm, public });
    }

    fn unpublish_channel(&mut self, psm: u16) {
        if let Some(stop) = self.channels.remove(&psm) {
            stop.store(true, Ordering::SeqCst);
        }
        self.air.channels.remove(&psm);
        self.write();
    }

    fn read_presence(&mut self, peripheral: &str, public: bool) {
        let Some(reports) = self.reports.clone() else { return };
        let (directory, peripheral) = (self.directory.clone(), peripheral.to_owned());
        std::thread::spawn(move || {
            let air = read_air(&directory, &peripheral);
            let value = air.as_ref().and_then(|a| a.presence.clone());
            let public_value = air.and_then(|a| a.public).filter(|_| public);
            reports.report(RadioEvent::Read { peripheral, value, public_value });
        });
    }

    fn open_channel(&mut self, peripheral: &str, psm: u16, dial: u64) {
        let Some(reports) = self.reports.clone() else { return };
        let (directory, peripheral) = (self.directory.clone(), peripheral.to_owned());
        std::thread::spawn(move || {
            let port = read_air(&directory, &peripheral).and_then(|air| air.channels.get(&psm).copied());
            let address = port.map(|port| SocketAddr::from((Ipv4Addr::LOCALHOST, port)));
            let stream = address.and_then(|address| TcpStream::connect_timeout(&address, CONNECT_TIMEOUT).ok());
            let platform = stream.and_then(|stream| platform_over_tcp(stream).ok());
            reports.opened(dial, platform.map(LinkStream::Platform));
        });
    }
}

impl Drop for TestAir {
    fn drop(&mut self) {
        self.power_down();
    }
}

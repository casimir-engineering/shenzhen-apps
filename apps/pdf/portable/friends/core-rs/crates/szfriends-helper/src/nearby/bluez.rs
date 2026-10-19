//! Bluetooth on Linux through BlueZ (the `bluetooth` feature): the [`Radio`] the Bluetooth adapter drives, over
//! `bluer` on a thread of its own with a small async runtime. It advertises the Friends service and serves the
//! presence characteristics from a GATT application, scans for the service, reads each device's values in one short
//! connection, and listens and connects on LE L2CAP channels (PSM 0 lets the kernel pick a free one). It never turns
//! the radio on or off: a radio the person switched off is reported as off.
//!
//! Hardware only: a VM has no radio, and the tests that use one are ignored unless run on a laptop that has one
//! (`tests/bluez_hardware.rs`).

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use bluer::adv::{Advertisement, AdvertisementHandle, Type};
use bluer::gatt::local::{Application, ApplicationHandle, Characteristic, CharacteristicRead, Service};
use bluer::l2cap::{SocketAddr, Stream, StreamListener};
use bluer::{Adapter, AdapterEvent, AdapterProperty, Address, AddressType, DiscoveryFilter, DiscoveryTransport, Uuid};
use futures::StreamExt;
use szfriends_core::nearby::bluetooth as bt;
use szfriends_core::nearby::Permission;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc::{unbounded_channel, UnboundedReceiver, UnboundedSender};
use tokio::task::JoinHandle;

use super::bluetooth::{Power, Radio, RadioEvent, RadioReports};
use super::stream::{LinkStream, PlatformStream};
use crate::log;

const READ_TIMEOUT: Duration = Duration::from_secs(10);
const OPEN_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug)]
enum Command {
    StartScanning,
    StopScanning,
    Advertise(Vec<u8>, Option<Vec<u8>>),
    StopAdvertising,
    Publish(bool),
    Unpublish(u16),
    Read(String, bool),
    Open(String, u16, u64),
}

/// See the module documentation.
#[derive(Debug, Default)]
pub struct BlueZ {
    commands: Option<UnboundedSender<Command>>,
}

impl BlueZ {
    pub fn new() -> Self {
        Self::default()
    }

    fn send(&self, command: Command) {
        if let Some(commands) = &self.commands {
            let _ = commands.send(command);
        }
    }
}

fn uuid(text: &str) -> Uuid {
    text.parse().expect("a fixed UUID")
}

/// The values reads return, shared with the GATT application's read handlers.
type Served = Arc<Mutex<(Vec<u8>, Option<Vec<u8>>)>>;

fn characteristic(id: &str, served: Served, public: bool) -> Characteristic {
    let read = CharacteristicRead {
        read: true,
        fun: Box::new(move |request| {
            let values = served.lock().unwrap_or_else(|e| e.into_inner()).clone();
            let value = if public { values.1.unwrap_or_default() } else { values.0 };
            let offset = usize::from(request.offset).min(value.len());
            Box::pin(async move { Ok(value[offset..].to_vec()) })
        }),
        ..Default::default()
    };
    Characteristic { uuid: uuid(id), read: Some(read), ..Default::default() }
}

/// An L2CAP stream as a platform stream, bytes crossing through channels.
fn bridge(stream: Stream) -> PlatformStream {
    let (mut reader, mut writer) = stream.into_split();
    let (outgoing, mut queue) = unbounded_channel::<Option<Vec<u8>>>();
    let (platform, incoming) = PlatformStream::new(Box::new(move |bytes| {
        let _ = outgoing.send(bytes);
    }));
    tokio::spawn(async move {
        while let Some(Some(bytes)) = queue.recv().await {
            if writer.write_all(&bytes).await.is_err() {
                return;
            }
        }
        let _ = writer.shutdown().await;
    });
    tokio::spawn(async move {
        let mut buffer = vec![0u8; 65_536];
        loop {
            match reader.read(&mut buffer).await {
                Ok(n) if n > 0 => {
                    if incoming.send(buffer[..n].to_vec()).is_err() {
                        return;
                    }
                }
                _ => {
                    let _ = incoming.send(Vec::new());
                    return;
                }
            }
        }
    });
    platform
}

struct Radioman {
    adapter: Adapter,
    reports: RadioReports,
    served: Served,
    advertising: Option<AdvertisementHandle>,
    advertised: BTreeSet<Uuid>,
    scanning: Option<JoinHandle<()>>,
    channels: HashMap<u16, JoinHandle<()>>,
}

impl Radioman {
    async fn advertise(&mut self, presence: Vec<u8>, public: Option<Vec<u8>>) {
        let mut uuids = BTreeSet::from([uuid(bt::SERVICE_UUID)]);
        if public.is_some() {
            uuids.insert(uuid(bt::PUBLIC_UUID));
        }
        *self.served.lock().unwrap_or_else(|e| e.into_inner()) = (presence, public);
        // Registered again only when the UUIDs change; the values themselves are read live.
        if self.advertising.is_some() && self.advertised == uuids {
            return;
        }
        self.advertising = None;
        let advertisement =
            Advertisement { advertisement_type: Type::Peripheral, service_uuids: uuids.clone(), ..Default::default() };
        match self.adapter.advertise(advertisement).await {
            Ok(handle) => {
                self.advertising = Some(handle);
                self.advertised = uuids;
            }
            Err(error) => log!("bluetooth advertising: {error}"),
        }
    }

    fn scan(&mut self) {
        let (adapter, reports) = (self.adapter.clone(), self.reports.clone());
        self.scanning = Some(tokio::spawn(async move {
            let filter = DiscoveryFilter {
                uuids: HashSet::from([uuid(bt::SERVICE_UUID)]),
                transport: DiscoveryTransport::Le,
                duplicate_data: false,
                ..Default::default()
            };
            if let Err(error) = adapter.set_discovery_filter(filter).await {
                return log!("bluetooth scan filter: {error}");
            }
            let mut events = match adapter.discover_devices().await {
                Ok(events) => Box::pin(events),
                Err(error) => return log!("bluetooth scan: {error}"),
            };
            while let Some(event) = events.next().await {
                let AdapterEvent::DeviceAdded(address) = event else { continue };
                let Ok(device) = adapter.device(address) else { continue };
                // Known devices come first, in range or not: only those heard now count.
                if !matches!(device.rssi().await, Ok(Some(_))) {
                    continue;
                }
                let uuids = device.uuids().await.ok().flatten().unwrap_or_default();
                if !uuids.contains(&uuid(bt::SERVICE_UUID)) {
                    continue;
                }
                let public = uuids.contains(&uuid(bt::PUBLIC_UUID));
                reports.report(RadioEvent::Discovered { peripheral: address.to_string(), public });
            }
        }));
    }

    async fn publish(&mut self, public: bool) {
        let bound = StreamListener::bind(SocketAddr::new(Address::any(), AddressType::LePublic, 0)).await;
        let listener = match bound {
            Ok(listener) => listener,
            Err(error) => {
                log!("bluetooth channel: {error}");
                return self.reports.report(RadioEvent::Published { psm: 0, public });
            }
        };
        let psm = listener.as_ref().local_addr().map_or(0, |address| address.psm);
        if psm == 0 {
            return self.reports.report(RadioEvent::Published { psm: 0, public });
        }
        let reports = self.reports.clone();
        let accepting = tokio::spawn(async move {
            while let Ok((stream, from)) = listener.accept().await {
                let stream = LinkStream::Platform(bridge(stream));
                reports.report(RadioEvent::Accepted { stream, public, peer: Some(from.addr.to_string()) });
            }
        });
        self.channels.insert(psm, accepting);
        self.reports.report(RadioEvent::Published { psm, public });
    }

    fn read(&self, peripheral: String, public: bool) {
        let (adapter, reports) = (self.adapter.clone(), self.reports.clone());
        tokio::spawn(async move {
            let values = tokio::time::timeout(READ_TIMEOUT, read_values(&adapter, &peripheral, public)).await;
            let (value, public_value) = values.ok().flatten().unwrap_or_default();
            reports.report(RadioEvent::Read { peripheral, value, public_value });
        });
    }

    fn open(&self, peripheral: String, psm: u16, dial: u64) {
        let (adapter, reports) = (self.adapter.clone(), self.reports.clone());
        tokio::spawn(async move {
            let opened = tokio::time::timeout(OPEN_TIMEOUT, async {
                let address: Address = peripheral.parse().ok()?;
                let kind = adapter.device(address).ok()?.address_type().await.ok()?;
                Stream::connect(SocketAddr::new(address, kind, psm)).await.ok()
            });
            let stream = opened.await.ok().flatten().map(|stream| LinkStream::Platform(bridge(stream)));
            reports.opened(dial, stream);
        });
    }

    async fn run(mut self, mut commands: UnboundedReceiver<Command>) {
        while let Some(command) = commands.recv().await {
            match command {
                Command::StartScanning => {
                    if let Some(scan) = self.scanning.take() {
                        scan.abort();
                    }
                    self.scan();
                }
                Command::StopScanning => {
                    if let Some(scan) = self.scanning.take() {
                        scan.abort();
                    }
                }
                Command::Advertise(presence, public) => self.advertise(presence, public).await,
                Command::StopAdvertising => self.advertising = None,
                Command::Publish(public) => self.publish(public).await,
                Command::Unpublish(psm) => {
                    if let Some(channel) = self.channels.remove(&psm) {
                        channel.abort();
                    }
                }
                Command::Read(peripheral, public) => self.read(peripheral, public),
                Command::Open(peripheral, psm, dial) => self.open(peripheral, psm, dial),
            }
        }
        if let Some(scan) = self.scanning.take() {
            scan.abort();
        }
        for (_, channel) in self.channels.drain() {
            channel.abort();
        }
    }
}

/// Both values in one connection, which is closed again when this connected it.
async fn read_values(adapter: &Adapter, peripheral: &str, public: bool) -> Option<(Option<Vec<u8>>, Option<Vec<u8>>)> {
    let device = adapter.device(peripheral.parse().ok()?).ok()?;
    let was_connected = device.is_connected().await.unwrap_or(false);
    if !was_connected {
        device.connect().await.ok()?;
    }
    let (mut value, mut public_value) = (None, None);
    for service in device.services().await.unwrap_or_default() {
        if service.uuid().await.ok() != Some(uuid(bt::SERVICE_UUID)) {
            continue;
        }
        for characteristic in service.characteristics().await.unwrap_or_default() {
            let id = characteristic.uuid().await.ok();
            if id == Some(uuid(bt::PRESENCE_CHARACTERISTIC_UUID)) {
                value = characteristic.read().await.ok();
            } else if public && id == Some(uuid(bt::PUBLIC_CHARACTERISTIC_UUID)) {
                public_value = characteristic.read().await.ok();
            }
        }
    }
    if !was_connected {
        let _ = device.disconnect().await;
    }
    Some((value, public_value))
}

/// Powers up on its own thread: the session, the adapter's state, the GATT application, then commands.
fn serve(reports: RadioReports, commands: UnboundedReceiver<Command>) {
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            log!("bluetooth runtime: {error}");
            return reports.report(RadioEvent::Power(Power::Unsupported));
        }
    };
    runtime.block_on(async move {
        let adapter = match bluer::Session::new().await {
            Ok(session) => session.default_adapter().await,
            Err(error) => Err(error),
        };
        let adapter = match adapter {
            Ok(adapter) => adapter,
            Err(error) => {
                log!("bluetooth: {error}");
                return reports.report(RadioEvent::Power(Power::Unsupported));
            }
        };
        let powered = adapter.is_powered().await.unwrap_or(false);
        let served: Served = Arc::default();
        let application = Application {
            services: vec![Service {
                uuid: uuid(bt::SERVICE_UUID),
                primary: true,
                characteristics: vec![
                    characteristic(bt::PRESENCE_CHARACTERISTIC_UUID, served.clone(), false),
                    characteristic(bt::PUBLIC_CHARACTERISTIC_UUID, served.clone(), true),
                ],
                ..Default::default()
            }],
            ..Default::default()
        };
        let _application: Option<ApplicationHandle> = match adapter.serve_gatt_application(application).await {
            Ok(handle) => Some(handle),
            Err(error) => {
                log!("bluetooth GATT: {error}");
                None
            }
        };
        let power_reports = reports.clone();
        if let Ok(events) = adapter.events().await {
            tokio::spawn(async move {
                let mut events = Box::pin(events);
                while let Some(event) = events.next().await {
                    if let AdapterEvent::PropertyChanged(AdapterProperty::Powered(on)) = event {
                        power_reports.report(RadioEvent::Power(if on { Power::On } else { Power::Off }));
                    }
                }
            });
        }
        reports.report(RadioEvent::Power(if powered { Power::On } else { Power::Off }));
        let radio = Radioman {
            adapter,
            reports,
            served,
            advertising: None,
            advertised: BTreeSet::new(),
            scanning: None,
            channels: HashMap::new(),
        };
        radio.run(commands).await;
    });
}

impl Radio for BlueZ {
    /// BlueZ asks nobody: starting waits for the person to open Friends, as the network does.
    fn permission(&self) -> Permission {
        Permission::Unknown
    }

    fn power_up(&mut self, reports: RadioReports) {
        let (commands, inbox) = unbounded_channel();
        let spawned = std::thread::Builder::new().name("szfriends-bluez".into()).spawn(move || serve(reports, inbox));
        if let Err(error) = spawned {
            log!("bluetooth thread: {error}");
            return;
        }
        self.commands = Some(commands);
    }

    fn power_down(&mut self) {
        // Closing the inbox ends the loop; dropping the handles withdraws the advertisement and the application.
        self.commands = None;
    }

    fn start_scanning(&mut self) {
        self.send(Command::StartScanning);
    }

    fn stop_scanning(&mut self) {
        self.send(Command::StopScanning);
    }

    fn advertise(&mut self, presence: &[u8], public: Option<&[u8]>) {
        self.send(Command::Advertise(presence.to_vec(), public.map(<[u8]>::to_vec)));
    }

    fn stop_advertising(&mut self) {
        self.send(Command::StopAdvertising);
    }

    fn publish_channel(&mut self, public: bool) {
        self.send(Command::Publish(public));
    }

    fn unpublish_channel(&mut self, psm: u16) {
        self.send(Command::Unpublish(psm));
    }

    fn read_presence(&mut self, peripheral: &str, public: bool) {
        self.send(Command::Read(peripheral.to_owned(), public));
    }

    fn open_channel(&mut self, peripheral: &str, psm: u16, dial: u64) {
        self.send(Command::Open(peripheral.to_owned(), psm, dial));
    }
}

//! Nearby on phones (ADR 0015 § 9, § 10): the plugin's Kotlin (`android/`) and Swift (`ios/`) do the platform's
//! part, and this installs it into the core before the core starts. Android registers the core's own listeners with
//! `NsdManager` and resolves the instances the core dials; iOS listens and connects itself with `NWListener` and
//! `NWConnection` (peer-to-peer Wi-Fi included). Both run Bluetooth: advertising, the GATT characteristics, scans,
//! reads and L2CAP channels, whose bytes cross here as platform streams.
//!
//! Commands go to the native plugin with `run_mobile_plugin`; what the platform finds comes back on channels, as
//! JSON objects with a `kind`. Bytes travel base64-encoded; each native stream has an id unique within the app.
//! Permissions are asked only by the calls that start a method (browse, power up), which the core makes on
//! `activate` or at launch once the person allowed them.

use std::io;
use std::net::SocketAddr;
use std::sync::Arc;

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use serde_json::{json, Value};
use szfriends_core::presentation::facts::BoostDevice;
use szfriends_core::transfer::boost::{Abilities, Connectivity, Link};
use szfriends_helper::nearby::direct_wifi::{self, DirectWifi, Done};
use szfriends_helper::nearby::platform::{self, PlatformDiscovery, Reports};
use szfriends_helper::nearby::radio::{Permission, Power, Radio, RadioEvent, RadioReports};
use szfriends_helper::nearby::stream::{LinkStream, PlatformStream};
use tauri::ipc::{Channel, InvokeResponseBody};
use tauri::plugin::PluginHandle;
use tauri::Runtime;

use crate::streams::StreamTable;

/// The native plugin and the streams it holds open into the core.
struct Native<R: Runtime> {
    handle: PluginHandle<R>,
    streams: StreamTable,
}

impl<R: Runtime> Native<R> {
    fn call(&self, command: &str, payload: Value) -> io::Result<Value> {
        self.handle.run_mobile_plugin::<Value>(command, payload).map_err(|error| io::Error::other(error.to_string()))
    }

    /// Fire and forget: what fails is reported on the channels.
    fn tell(&self, command: &str, payload: Value) {
        let _ = self.call(command, payload);
    }

    /// A native stream as a platform stream: writes go out as `streamWrite`, the end as `streamClose`.
    fn stream(self: &Arc<Self>, id: u64) -> PlatformStream {
        let native = self.clone();
        let (stream, sender) = PlatformStream::new(Box::new(move |bytes| match bytes {
            Some(bytes) => native.tell("streamWrite", json!({"stream": id, "data": STANDARD.encode(bytes)})),
            None => native.tell("streamClose", json!({"stream": id})),
        }));
        self.streams.claim(id, sender);
        stream
    }

    /// Bytes or the end of a stream; `false` for any other kind.
    fn stream_event(&self, event: &Value) -> bool {
        let Some(id) = event["stream"].as_u64() else { return false };
        match event["kind"].as_str() {
            Some("bytes") => {
                let data = event["data"].as_str().and_then(|d| STANDARD.decode(d).ok()).unwrap_or_default();
                self.streams.bytes(id, data);
                true
            }
            Some("closed") => {
                self.streams.closed(id);
                true
            }
            _ => false,
        }
    }

    /// A channel whose JSON messages go to `on_event`.
    fn channel(on_event: impl Fn(Value) + Send + Sync + 'static) -> Channel {
        Channel::new(move |body| {
            if let InvokeResponseBody::Json(text) = body {
                if let Ok(value) = serde_json::from_str::<Value>(&text) {
                    on_event(value);
                }
            }
            Ok(())
        })
    }
}

fn hex_bytes(value: &Value) -> Option<Vec<u8>> {
    value.as_str().and_then(hex_decode)
}

fn hex_decode(text: &str) -> Option<Vec<u8>> {
    if text.len() % 2 != 0 {
        return None;
    }
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok()).collect()
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn text(value: &Value, key: &str) -> String {
    value[key].as_str().unwrap_or_default().to_owned()
}

/// TXT pairs as the platform reports them: `[[key, hex value], ...]`.
fn txt(value: &Value) -> Vec<(String, Vec<u8>)> {
    let pairs = value.as_array().map(Vec::as_slice).unwrap_or_default();
    pairs.iter().filter_map(|pair| Some((pair[0].as_str()?.to_owned(), hex_bytes(&pair[1])?))).collect()
}

/// The platform's DNS-SD (`NsdManager`; `NWBrowser` and `NWListener`).
struct Discovery<R: Runtime> {
    native: Arc<Native<R>>,
    owns_connections: bool,
}

impl<R: Runtime> PlatformDiscovery for Discovery<R> {
    fn register(&self, service_type: &str, name: &str, port: u16, txt: &[(String, String)]) -> io::Result<()> {
        let payload = json!({"serviceType": service_type, "name": name, "port": port, "txt": txt});
        self.native.call("nearbyRegister", payload).map(|_| ())
    }

    fn unregister(&self, name: &str) {
        self.native.tell("nearbyUnregister", json!({"name": name}));
    }

    fn browse(&self, service_type: &str, reports: Reports) -> io::Result<()> {
        let native = self.native.clone();
        let channel = Native::<R>::channel(move |event| {
            if native.stream_event(&event) {
                return;
            }
            match event["kind"].as_str().unwrap_or_default() {
                "ready" => reports.ready(),
                "denied" => reports.denied(),
                "radio" => reports.radio(event["on"].as_bool().unwrap_or(true)),
                "failed" => reports.failed(&text(&event, "why")),
                "lost" => reports.lost(&text(&event, "name")),
                "found" => {
                    let addresses = event["addresses"].as_array().map(Vec::as_slice).unwrap_or_default();
                    let addresses: Vec<SocketAddr> =
                        addresses.iter().filter_map(|a| a.as_str()?.parse().ok()).collect();
                    reports.found(&text(&event, "name"), addresses, txt(&event["txt"]));
                }
                "foundByPlatform" => {
                    let peer_to_peer = event["peerToPeer"].as_bool().unwrap_or(false);
                    reports.found_by_platform(&text(&event, "name"), txt(&event["txt"]), peer_to_peer);
                }
                "accepted" => {
                    let Some(id) = event["stream"].as_u64() else { return };
                    let address = event["address"].as_str().map(str::to_owned);
                    let peer_to_peer = event["peerToPeer"].as_bool().unwrap_or(false);
                    reports.accepted(&text(&event, "name"), native.stream(id), address, peer_to_peer);
                }
                "opened" => {
                    let Some(dial) = event["dial"].as_u64() else { return };
                    reports.opened(dial, event["stream"].as_u64().map(|id| native.stream(id)));
                }
                _ => {}
            }
        });
        self.native.call("nearbyBrowse", json!({"serviceType": service_type, "channel": channel})).map(|_| ())
    }

    fn stop(&self) {
        self.native.tell("nearbyStop", json!({}));
    }

    fn owns_connections(&self) -> bool {
        self.owns_connections
    }

    fn withdraw(&self, name: &str) {
        self.native.tell("nearbyWithdraw", json!({"name": name}));
    }

    fn connect(&self, name: &str, dial: u64) -> bool {
        self.native.call("nearbyConnect", json!({"name": name, "dial": dial})).is_ok()
    }
}

/// The platform's Bluetooth (CoreBluetooth; Android's BLE and L2CAP).
struct MobileRadio<R: Runtime> {
    native: Arc<Native<R>>,
}

fn power(name: &str) -> Power {
    match name {
        "on" => Power::On,
        "off" => Power::Off,
        "unauthorized" => Power::Unauthorized,
        "unsupported" => Power::Unsupported,
        _ => Power::Unknown,
    }
}

impl<R: Runtime> Radio for MobileRadio<R> {
    fn permission(&self) -> Permission {
        let answer = self.native.call("radioPermission", json!({})).unwrap_or_default();
        match answer["permission"].as_str() {
            Some("allowed") => Permission::Allowed,
            Some("denied") => Permission::Denied,
            Some("notDetermined") => Permission::NotDetermined,
            _ => Permission::Unknown,
        }
    }

    fn power_up(&mut self, reports: RadioReports) {
        let failure = reports.clone();
        let native = self.native.clone();
        let channel = Native::<R>::channel(move |event| {
            if native.stream_event(&event) {
                return;
            }
            let peripheral = text(&event, "peripheral");
            let public = event["public"].as_bool().unwrap_or(false);
            let report = match event["kind"].as_str().unwrap_or_default() {
                "power" => RadioEvent::Power(power(event["power"].as_str().unwrap_or_default())),
                "discovered" => RadioEvent::Discovered { peripheral, public },
                "read" => RadioEvent::Read {
                    peripheral,
                    value: hex_bytes(&event["value"]),
                    public_value: hex_bytes(&event["publicValue"]),
                },
                "published" => {
                    let psm = event["psm"].as_u64().and_then(|p| u16::try_from(p).ok()).unwrap_or(0);
                    RadioEvent::Published { psm, public }
                }
                "accepted" => {
                    let Some(id) = event["stream"].as_u64() else { return };
                    let stream = LinkStream::Platform(native.stream(id));
                    RadioEvent::Accepted { stream, public, peer: event["peer"].as_str().map(str::to_owned) }
                }
                "opened" => {
                    let Some(dial) = event["dial"].as_u64() else { return };
                    let stream = event["stream"].as_u64().map(|id| LinkStream::Platform(native.stream(id)));
                    return reports.opened(dial, stream);
                }
                _ => return,
            };
            reports.report(report);
        });
        if self.native.call("radioPowerUp", json!({"channel": channel})).is_err() {
            // The plugin could not start Bluetooth at all: Nearby says it isn't working.
            failure.report(RadioEvent::Power(Power::Unsupported));
        }
    }

    fn power_down(&mut self) {
        self.native.tell("radioPowerDown", json!({}));
    }

    fn start_scanning(&mut self) {
        self.native.tell("radioStartScanning", json!({}));
    }

    fn stop_scanning(&mut self) {
        self.native.tell("radioStopScanning", json!({}));
    }

    fn advertise(&mut self, presence: &[u8], public: Option<&[u8]>) {
        let payload = json!({"presence": hex_encode(presence), "public": public.map(hex_encode)});
        self.native.tell("radioAdvertise", payload);
    }

    fn stop_advertising(&mut self) {
        self.native.tell("radioStopAdvertising", json!({}));
    }

    fn publish_channel(&mut self, public: bool) {
        self.native.tell("radioPublish", json!({"public": public}));
    }

    fn unpublish_channel(&mut self, psm: u16) {
        self.native.tell("radioUnpublish", json!({"psm": psm}));
    }

    fn read_presence(&mut self, peripheral: &str, public: bool) {
        self.native.tell("radioRead", json!({"peripheral": peripheral, "public": public}));
    }

    fn open_channel(&mut self, peripheral: &str, psm: u16, dial: u64) {
        self.native.tell("radioOpen", json!({"peripheral": peripheral, "psm": psm, "dial": dial}));
    }
}

/// The Wi-Fi Direct boost (ADR 0019): Android hosts and joins (`DirectWifi.kt`), iOS joins (`DirectWifi.swift`).
/// Installed where the hardware (and on iOS the entitlement) allows it; abilities are read each time, since Android's
/// permission may come later. Hosting, joining and leaving answer on a thread of their own, since the plugin resolves
/// them only once the platform did it.
struct PhoneDirectWifi<R: Runtime> {
    native: Arc<Native<R>>,
    system_asks: bool,
}

fn abilities_of(answer: &Value) -> Abilities {
    let flag = |key: &str| answer[key].as_bool().unwrap_or(false);
    Abilities {
        host: flag("host"),
        join: flag("join"),
        host_keeps_wifi: flag("hostKeepsWifi"),
        join_keeps_wifi: flag("joinKeepsWifi"),
    }
}

impl<R: Runtime> PhoneDirectWifi<R> {
    fn later(&self, command: &'static str, payload: Value, done: impl FnOnce(io::Result<Value>) + Send + 'static) {
        let native = self.native.clone();
        std::thread::spawn(move || done(native.call(command, payload)));
    }
}

impl<R: Runtime> DirectWifi for PhoneDirectWifi<R> {
    fn abilities(&self) -> Abilities {
        abilities_of(&self.native.call("directWifiAbilities", json!({})).unwrap_or_default())
    }

    fn connectivity(&self) -> Connectivity {
        let now = self.native.call("directWifiConnectivity", json!({})).unwrap_or_default();
        let flag = |key: &str| now[key].as_bool().unwrap_or(false);
        // Phones never read the network's name (it needs location): the question says "your Wi-Fi".
        Connectivity { on_wifi: flag("onWifi"), wifi_name: None, wired: flag("wired"), mobile: flag("mobile") }
    }

    fn current_network(&self) -> Option<String> {
        let now = self.native.call("directWifiConnectivity", json!({})).unwrap_or_default();
        now["network"].as_str().map(str::to_owned)
    }

    fn device(&self) -> BoostDevice {
        BoostDevice::Phone
    }

    fn system_asks_too(&self) -> bool {
        self.system_asks
    }

    fn host(&self, link: &Link, done: Done<Result<std::net::IpAddr, String>>) {
        let payload = json!({"network": link.network, "passphrase": link.passphrase});
        self.later("directWifiHost", payload, move |answer| {
            done(match answer {
                Ok(value) => {
                    value["address"].as_str().and_then(|a| a.parse().ok()).ok_or_else(|| "no address".to_owned())
                }
                Err(error) => Err(error.to_string()),
            })
        });
    }

    fn stop_hosting(&self) {
        self.native.tell("directWifiStopHosting", json!({}));
    }

    fn join(&self, link: &Link, done: Done<bool>) {
        let payload = json!({"network": link.network, "passphrase": link.passphrase});
        self.later("directWifiJoin", payload, move |answer| {
            done(answer.ok().and_then(|v| v["joined"].as_bool()).unwrap_or(false))
        });
    }

    fn rejoin(&self, network: Option<&str>, joined: &str, done: Done<bool>) {
        let payload = json!({"network": network, "joined": joined});
        self.later("directWifiRejoin", payload, move |answer| {
            done(answer.ok().and_then(|v| v["ok"].as_bool()).unwrap_or(false))
        });
    }

    fn online(&self, done: Done<bool>) {
        self.later("directWifiOnline", json!({}), move |answer| {
            done(answer.ok().and_then(|v| v["online"].as_bool()).unwrap_or(false))
        });
    }
}

/// Installs the platform's discovery and radio for the core (once per process), through the plugin's one native
/// half: Tauri keeps a single Kotlin or Swift plugin per Tauri plugin, so Nearby's commands live on the class that
/// `phone::native` registers (FriendsPlugin extends NearbyPlugin), and a second registration would replace it.
pub fn install<R: Runtime>(handle: PluginHandle<R>) {
    let native = Arc::new(Native { handle, streams: StreamTable::default() });
    let capabilities = native.call("nearbyCapabilities", json!({})).unwrap_or_default();
    let owns_connections = capabilities["ownsConnections"].as_bool().unwrap_or(false);
    let bluetooth = capabilities["bluetooth"].as_bool().unwrap_or(false);
    platform::install(Arc::new(Discovery { native: native.clone(), owns_connections }));
    let boost = native.call("directWifiAbilities", json!({})).unwrap_or_default();
    if boost["supported"].as_bool().unwrap_or(false) {
        let system_asks = boost["systemAsks"].as_bool().unwrap_or(false);
        direct_wifi::install(Arc::new(PhoneDirectWifi { native: native.clone(), system_asks }));
    }
    if bluetooth {
        let factory = move || -> Box<dyn Radio> { Box::new(MobileRadio { native: native.clone() }) };
        platform::install_radio(Box::new(factory));
    }
}

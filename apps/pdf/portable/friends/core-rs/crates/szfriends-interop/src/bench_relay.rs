//! The owner's relay rule on the bench (bench.rs; ADR 0020): the relay carries a file only when no direct route
//! works, and a direct route that appears while the relay carries one takes over at once. Each case starts or ends on
//! the emulated relay and reports, besides the usual, what the relay carried while a direct route worked and how long
//! a new route took to carry its first part. [`RelayCase::check`] is the release gate's verdict
//! (`make friends-relay-rule-check`).

use super::*;

/// A part has crossed a route once this much more passed after it came up (handshake and PINGs are far less).
const FIRST_PART_BYTES: u64 = 16 * 1024;
/// What the relay may still carry once a direct route works: parts this side had already handed to the relay's
/// session and socket (its channel's few queued parts, the kernel's send buffer, the emulated path), which nobody can
/// take back; measured at 100 to 260 KiB on loopback. Parts not yet written are dropped at once (ADR 0020). Before
/// the rule was enforced, a relay beside Bluetooth carried 640 to 770 KB of a 1 MiB file.
pub const RELAY_BESIDE_DIRECT_MAX: u64 = 512 * 1024;
/// While the LAN works from the start the relay's session carries its pings and nothing else.
pub const RELAY_BESIDE_LAN_FIRST_MAX: u64 = 64 * 1024;
/// A new route carries its first part within this of coming up (ADR 0020: "within about a second").
pub const FIRST_PART_MAX: Duration = Duration::from_millis(1000);

/// How the direct route arrives or goes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RelayStory {
    /// Started on the relay; `route` comes up as a lane of it (Bluetooth or direct Wi-Fi asked for by the scheduler,
    /// or found by the lanes' dialing) once the relay carried `after` bytes.
    LateLane,
    /// Started on the relay; `route` comes up as a new session that wins the session race (the same network, a
    /// direct Internet connection that succeeded late): the relay session is closed at once, as both helpers' race
    /// closes its loser, and the transfer resumes on the new one.
    LateSession,
    /// The relay session with a LAN lane from the start: the relay must carry nothing while the LAN works; the LAN is
    /// cut (every direct route gone: the relay may carry the file), then the LAN comes back as a new lane.
    DirectLostAndBack,
}

#[derive(Clone, Debug)]
pub struct RelayCase {
    pub name: String,
    pub story: RelayStory,
    /// The direct route that appears (and, for `DirectLostAndBack`, the one lost and back).
    pub route: RouteProfile,
    pub files: Vec<u64>,
    /// Relay bytes before the direct route appears (or comes back).
    pub after: u64,
}

impl RelayCase {
    pub fn named(name: &str) -> Option<Self> {
        let (story, route, files) = match name {
            "relay-then-lan" => (RelayStory::LateSession, LAN, vec![8 * MIB]),
            "relay-then-p2p" => (RelayStory::LateSession, INTERNET, vec![4 * MIB]),
            "relay+lan-late" => (RelayStory::LateLane, LAN, vec![8 * MIB]),
            "relay+p2p_wifi-late" => (RelayStory::LateLane, P2P_WIFI, vec![8 * MIB]),
            // 1 MiB: Bluetooth then holds three slices and a stale one behind them, the case where the relay took the
            // file back from a Bluetooth lane that was only slow (ADR 0020).
            "relay+bt-late" => (RelayStory::LateLane, BLUETOOTH, vec![MIB]),
            "lan+relay-cut-lan-back" => (RelayStory::DirectLostAndBack, LAN, vec![8 * MIB]),
            _ => return None,
        };
        Some(Self { name: name.to_owned(), story, route, files, after: 256 * 1024 })
    }

    pub const ALL: &'static str =
        "relay-then-lan,relay-then-p2p,relay+lan-late,relay+p2p_wifi-late,relay+bt-late,lan+relay-cut-lan-back";

    /// The rule's verdict on a result: `None` when it holds.
    pub fn check(result: &Value) -> Option<String> {
        if let Some(error) = result["error"].as_str() {
            return Some(error.to_owned());
        }
        if result["skipped"].is_string() {
            return None;
        }
        let beside = result["relay_bytes_beside_direct"].as_u64().unwrap_or(u64::MAX);
        if beside > RELAY_BESIDE_DIRECT_MAX {
            return Some(format!("the relay carried {beside} bytes while a direct route worked"));
        }
        let first = result["first_part_ms"].as_f64().unwrap_or(f64::INFINITY);
        if first > FIRST_PART_MAX.as_secs_f64() * 1000.0 {
            return Some(format!("the new route carried its first part {first:.0} ms after it came up"));
        }
        let first_phase = result["relay_bytes_beside_lan_first"].as_u64().unwrap_or(0);
        if first_phase > RELAY_BESIDE_LAN_FIRST_MAX {
            return Some(format!("the relay carried {first_phase} bytes beside the LAN, which worked from the start"));
        }
        if result["story"] == "direct-lost-and-back" && result["relay_bytes_while_alone"].as_u64().unwrap_or(0) == 0 {
            return Some("the relay never took over once every direct route was gone".into());
        }
        None
    }
}

/// Runs a [`RelayCase`], reported like [`run_multi`] plus `relay_bytes_beside_direct`, `first_part_ms` (from the new
/// route's session or lane established, at the sender, to its first part across) and `relay_bytes_while_alone`.
pub fn run_relay(case: &RelayCase, sender: &PeerSpec, receiver: &PeerSpec) -> Value {
    let total: u64 = case.files.iter().sum();
    let mut result = json!({
        "case": case.name, "sender": sender.label, "receiver": receiver.label,
        "route": format!("relay+{}", case.route.name), "files": case.files.len(), "bytes": total,
        "story": match case.story {
            RelayStory::LateLane => "late-lane",
            RelayStory::LateSession => "late-session",
            RelayStory::DirectLostAndBack => "direct-lost-and-back",
        },
    });
    let outcome =
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| measure_relay(case, sender, receiver, &mut result)));
    match outcome {
        Ok(Ok(())) => {}
        Ok(Err(why)) if why.starts_with("skip: ") => result["skipped"] = json!(why.trim_start_matches("skip: ")),
        Ok(Err(why)) => result["error"] = json!(why),
        Err(_) => result["error"] = json!("panicked"),
    }
    if result["error"].is_null() {
        if let Some(why) = RelayCase::check(&result) {
            result["error"] = json!(format!("the relay rule: {why}"));
        }
    }
    keep_logs(&mut result);
    result
}

/// Waits, pulling both peers' events, until `done` or `limit`.
fn pump(
    sender: &mut (ObjcPeer, Log),
    receiver: &mut (ObjcPeer, Log),
    limit: Duration,
    mut done: impl FnMut() -> bool,
) -> bool {
    let until = Instant::now() + limit;
    while Instant::now() < until {
        sender.1.drain(&mut sender.0);
        receiver.1.drain(&mut receiver.0);
        if done() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(1));
    }
    false
}

fn measure_relay(
    case: &RelayCase,
    sender_spec: &PeerSpec,
    receiver_spec: &PeerSpec,
    result: &mut Value,
) -> Result<(), String> {
    let homes = (TempHome::new("relay-s"), TempHome::new("relay-r"), TempHome::new("relay-content"));
    let sender = sender_spec.start(&homes.0.path().join("state"), "Sender");
    let receiver = receiver_spec.start(&homes.1.path().join("state"), "Receiver");
    watch("sender", &sender);
    watch("receiver", &receiver);
    let (mut s, mut r) = ((sender, Log::new()), (receiver, Log::new()));
    let lanes = |peer: &mut ObjcPeer| peer.command(json!({ "cmd": "hello" }))["lanes"] == true;
    if case.story != RelayStory::LateSession && (!lanes(&mut s.0) || !lanes(&mut r.0)) {
        return Err("skip: these peers open no lanes".into());
    }
    befriend(&mut s.0, &mut r.0, ("Sender", "Receiver"));
    let remote = keys(&mut r.0);
    let port = listen(&mut r.0);
    let relay = Proxy::start(port);
    relay.set(RELAY.tamper());
    let step = Duration::from_secs(30);
    let dial = |proxy: &Proxy, route: &RouteProfile, lane_of: Option<u64>| {
        let mut command = json!({ "cmd": "dial", "port": proxy.port(), "pattern": "IK",
            "remote_static": remote.static_key, "expected_identity": remote.identity, "route": route.class });
        if let Some(head) = lane_of {
            command["lane_of"] = json!(head);
        }
        command
    };
    // Dials and waits for the sender's "established" of that dial; the time it came up.
    let up = |s: &mut (ObjcPeer, Log), command: Value| -> Result<(u64, Instant), String> {
        let from = s.1.events.len();
        let reply = s.0.command(command);
        let id = reply["session"].as_u64().ok_or_else(|| format!("the dial failed: {reply}"))?;
        let (at, _) =
            s.1.wait(&mut s.0, from, step, |e| e["event"] == "established" && e["session"].as_u64() == Some(id))
                .ok_or("the dialed session never came up")?;
        Ok((id, at))
    };
    let (first, _) = up(&mut s, dial(&relay, &RELAY, None))?;
    r.1.wait(&mut r.0, 0, step, is("established")).ok_or("the receiver's session never came up")?;
    // DirectLostAndBack: the LAN lane is there from the start.
    let mut direct = Vec::<(Proxy, Instant)>::new();
    if case.story == RelayStory::DirectLostAndBack {
        let lan = Proxy::start(port);
        lan.set(case.route.tamper());
        let (_, at) = up(&mut s, dial(&lan, &case.route, Some(first)))?;
        direct.push((lan, at));
    }
    let mut digests = Vec::new();
    let mut ids = Vec::new();
    for (index, size) in case.files.iter().enumerate() {
        let path = homes.2.path().join(format!("file-{index}.bin"));
        digests.push(bench_content(&path, &format!("relay {} {index}", case.name), *size));
        let offer = s.0.command(json!({ "cmd": "send_file", "session": first, "path": path.to_string_lossy() }));
        ids.push(offer["transfer"].as_str().ok_or_else(|| format!("send_file failed: {offer}"))?.to_owned());
    }
    let started = Instant::now();
    let total: u64 = case.files.iter().sum();
    let long = Duration::from_secs_f64(total as f64 / RELAY.bytes_per_second.unwrap() as f64 * 2.0 + 60.0);
    let relay_sent = || relay.counts().0;
    let mut beside = 0u64;
    let mut alone = 0u64;
    if case.story == RelayStory::DirectLostAndBack {
        // While the LAN works: the relay carries nothing but its own session's pings.
        let lan_sent = || direct[0].0.counts().0;
        let before = relay_sent();
        if !pump(&mut s, &mut r, long, || lan_sent() >= total * 3 / 10) {
            return Err("the LAN lane never carried 30 % of the file".into());
        }
        beside += relay_sent() - before;
        result["relay_bytes_beside_lan_first"] = json!(relay_sent() - before);
        direct[0].0.cut_now();
        result["lan_cut_after_s"] = json!(started.elapsed().as_secs_f64());
        let before = relay_sent();
        if !pump(&mut s, &mut r, long, || relay_sent() >= before + case.after) {
            return Err(format!("the relay never took over once the LAN was cut ({} bytes)", relay_sent() - before));
        }
        alone = relay_sent() - before;
        result["relay_took_over_s"] = json!(started.elapsed().as_secs_f64());
    } else if !pump(&mut s, &mut r, long, || relay_sent() >= case.after) {
        return Err("the relay never carried the first bytes".into());
    }
    // The direct route appears (or comes back).
    let new = Proxy::start(port);
    new.set(case.route.tamper());
    let lane_of = (case.story != RelayStory::LateSession).then_some(first);
    let (_, new_at) = up(&mut s, dial(&new, &case.route, lane_of))?;
    let mut at_up = relay_sent();
    if case.story == RelayStory::LateSession {
        // The race's loser closes at once on both sides (ADR 0001 § Session race).
        s.0.command(json!({ "cmd": "close", "session": first, "reason": 3 }));
        at_up = relay_sent();
    }
    result["direct_up_s"] = json!(new_at.duration_since(started).as_secs_f64());
    let base = new.counts().0;
    let mut first_part = None;
    pump(&mut s, &mut r, Duration::from_secs(10), || {
        first_part = (new.counts().0 >= base + FIRST_PART_BYTES).then(Instant::now);
        first_part.is_some()
    });
    // Measured from when the sender saw the route up; the harness polls every millisecond.
    result["first_part_ms"] = json!(first_part.map(|t| t.duration_since(new_at).as_secs_f64() * 1000.0));
    for id in &ids {
        if r.1.wait(&mut r.0, 0, long, |e| e["event"] == "received_file" && e["transfer"] == id.as_str()).is_none() {
            for peer in [&mut s.0, &mut r.0] {
                peer.command(json!({ "cmd": "debug" }));
            }
            return Err(format!("{id} not received within {long:?}"));
        }
    }
    beside += relay_sent().saturating_sub(at_up);
    result["relay_bytes_beside_direct"] = json!(beside);
    result["relay_bytes_while_alone"] = json!(alone);
    result["relay_bytes"] = json!(relay_sent());
    result["direct_bytes"] = json!(new.counts().0 + direct.iter().map(|(p, _)| p.counts().0).sum::<u64>());
    result["seconds"] = json!(started.elapsed().as_secs_f64());
    let paths: Vec<PathBuf> = ids
        .iter()
        .filter_map(|id| r.1.events.iter().find(|(_, e)| e["event"] == "received_file" && e["transfer"] == id.as_str()))
        .map(|(_, e)| PathBuf::from(e["path"].as_str().unwrap_or_default()))
        .collect();
    let intact =
        paths.len() == digests.len() && paths.iter().zip(&digests).all(|(p, d)| digest_of(p).as_ref() == Some(d));
    result["intact"] = json!(intact);
    if !intact {
        return Err("the received bytes differ from the sent ones".into());
    }
    Ok(())
}

//! Bench cases over several routes at once (bench.rs): one transfer whose session and lanes take different
//! emulated routes, with one route lost partway.

use super::*;

/// One transfer over several emulated routes between the same two peers at once (ADR 0018 § 6, 7): the first route
/// carries the session, each other one a lane of it; `lost` cuts or silences one route once the whole transfer is
/// at that fraction. Needs peers whose `hello` says `"lanes": true` and whose `dial` takes `"lane_of"` (the session
/// the lane joins); until then the case is reported as skipped.
#[derive(Clone, Debug)]
pub struct MultiCase {
    pub name: String,
    pub routes: Vec<RouteProfile>,
    pub files: Vec<u64>,
    /// Which route (index into `routes`) and what happens to it.
    pub lost: Option<(usize, Loss)>,
    /// A route that flaps from its connection on: up this long, then silent that long, again and again.
    pub flap: Option<(usize, Duration, Duration)>,
}

impl MultiCase {
    /// What the routes carry together, and what the fastest alone carries.
    pub fn rates(&self) -> (f64, f64) {
        let rates: Vec<f64> = self.routes.iter().filter_map(RouteProfile::expected_bytes_per_second).collect();
        (rates.iter().sum(), rates.iter().copied().fold(0.0, f64::max))
    }
}

/// Runs a [`MultiCase`]; reported like [`run`], plus `route_bytes` (what each route carried), `best_route_share`
/// (against the fastest route alone) and, after a loss, when a side noticed the lane was gone.
pub fn run_multi(case: &MultiCase, sender: &PeerSpec, receiver: &PeerSpec) -> Value {
    let total: u64 = case.files.iter().sum();
    let mut result = json!({
        "case": case.name, "sender": sender.label, "receiver": receiver.label,
        "route": case.routes.iter().map(|r| r.name).collect::<Vec<_>>().join("+"),
        "files": case.files.len(), "bytes": total,
    });
    let outcome =
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| measure_multi(case, sender, receiver, &mut result)));
    match outcome {
        Ok(Ok(())) => {}
        Ok(Err(why)) if why.starts_with("skip: ") => result["skipped"] = json!(why.trim_start_matches("skip: ")),
        Ok(Err(why)) => result["error"] = json!(why),
        Err(_) => result["error"] = json!("panicked"),
    }
    keep_logs(&mut result);
    result
}

pub(super) fn measure_multi(
    case: &MultiCase,
    sender_spec: &PeerSpec,
    receiver_spec: &PeerSpec,
    result: &mut Value,
) -> Result<(), String> {
    let total: u64 = case.files.iter().sum();
    let homes = (TempHome::new("multi-s"), TempHome::new("multi-r"), TempHome::new("multi-content"));
    let mut sender = sender_spec.start(&homes.0.path().join("state"), "Sender");
    let mut receiver = receiver_spec.start(&homes.1.path().join("state"), "Receiver");
    watch("sender", &sender);
    watch("receiver", &receiver);
    let lanes = |peer: &mut ObjcPeer| peer.command(json!({ "cmd": "hello" }))["lanes"] == true;
    if !lanes(&mut sender) || !lanes(&mut receiver) {
        return Err("skip: these peers open no lanes yet (ADR 0018 WP3)".into());
    }
    let (pid_s, pid_r) = (sender.pid(), receiver.pid());
    befriend(&mut sender, &mut receiver, ("Sender", "Receiver"));
    let remote = keys(&mut receiver);
    let (mut log_s, mut log_r) = (Log::new(), Log::new());
    let port = listen(&mut receiver);
    let proxies: Vec<Proxy> = case
        .routes
        .iter()
        .map(|route| {
            let proxy = Proxy::start(port);
            proxy.set(route.tamper());
            proxy
        })
        .collect();
    if let Some((which, up, down)) = case.flap {
        proxies[which].set(Tamper { flap: Some((up, down)), ..case.routes[which].tamper() });
    }
    let step = Duration::from_secs(30);
    let dial = |proxy: &Proxy, route: &RouteProfile| {
        json!({ "cmd": "dial", "port": proxy.port(), "pattern": "IK", "remote_static": remote.static_key,
                "expected_identity": remote.identity, "route": route.class })
    };
    let first =
        sender.command(dial(&proxies[0], &case.routes[0]))["session"].as_u64().ok_or("the first dial failed")?;
    let (_, live) = log_s.wait(&mut sender, 0, step, is("established")).ok_or("the session never came up")?;
    log_r.wait(&mut receiver, 0, step, is("established")).ok_or("the receiver's session never came up")?;
    result["minor"] = live["minor"].clone();
    result["fast"] = live["fast"].clone();
    for (index, (proxy, route)) in proxies.iter().zip(&case.routes).enumerate().skip(1) {
        let mut lane = dial(proxy, route);
        lane["lane_of"] = json!(first);
        let reply = sender.command(lane);
        if reply["session"].is_null() {
            return Err(format!("lane {index} ({}) refused: {reply}", route.name));
        }
        let from = log_s.events.len();
        let (_, up) = log_s
            .wait(&mut sender, from, step, is("established"))
            .ok_or_else(|| format!("lane {index} never came up"))?;
        // Each lane's cipher (ADR 0018 § 9.2), where the peer says it.
        if !up["cipher"].is_null() {
            let ciphers = result["lane_ciphers"].as_array().cloned().unwrap_or_default();
            result["lane_ciphers"] = json!([ciphers, vec![up["cipher"].clone()]].concat());
        }
    }
    let mut digests = Vec::new();
    let mut paths = Vec::new();
    for (index, size) in case.files.iter().enumerate() {
        let path = homes.2.path().join(format!("file-{index}.bin"));
        digests.push(bench_content(&path, &format!("multi {} {index}", case.name), *size));
        paths.push(path);
    }
    let (cpu_s0, cpu_r0) = (cpu_seconds(pid_s), cpu_seconds(pid_r));
    let started = Instant::now();
    let mut ids = Vec::new();
    for path in &paths {
        let offer = sender.command(json!({ "cmd": "send_file", "session": first, "path": path.to_string_lossy() }));
        ids.push(offer["transfer"].as_str().ok_or_else(|| format!("send_file failed: {offer}"))?.to_owned());
    }
    let (together, best) = case.rates();
    let long = Duration::from_secs_f64(total as f64 / best.max(1.0) * 4.0 + 120.0);
    if let Some((which, loss)) = case.lost {
        let carried = || proxies.iter().map(|p| p.counts().0).sum::<u64>();
        let at = match loss {
            Loss::Cut(f) | Loss::Silence(f) => (total as f64 * f) as u64,
            Loss::None => u64::MAX,
        };
        while carried() < at && started.elapsed() < long {
            log_s.drain(&mut sender);
            log_r.drain(&mut receiver);
            std::thread::sleep(Duration::from_millis(2));
        }
        let lost_at = Instant::now();
        if matches!(loss, Loss::Cut(_)) {
            proxies[which].cut_now();
        } else {
            proxies[which].silence_now();
        }
        result["lost_route"] = json!(case.routes[which].name);
        result["lost_after_s"] = json!(lost_at.duration_since(started).as_secs_f64());
        let (from_s, from_r) = (log_s.events.len(), log_r.events.len());
        let short = Duration::from_millis(20);
        let mut noticed = None;
        while noticed.is_none() && lost_at.elapsed() < Duration::from_secs(20) {
            noticed = log_s
                .wait(&mut sender, from_s, short, is("closed"))
                .or_else(|| log_r.wait(&mut receiver, from_r, short, is("closed")))
                .map(|(at, _)| at.duration_since(lost_at).as_secs_f64());
            if log_r.events[from_r..].iter().any(|(_, e)| e["event"] == "received_file") {
                break;
            }
        }
        result["noticed_s"] = json!(noticed);
    }
    for id in &ids {
        if log_r.wait(&mut receiver, 0, long, |e| e["event"] == "received_file" && e["transfer"] == id.as_str()).is_none()
        {
            // What each side holds now, for the transcripts (peers without "debug" answer that they do not know it).
            for peer in [&mut sender, &mut receiver] {
                peer.command(json!({ "cmd": "debug" }));
            }
            return Err(format!("{id} not received within {long:?}"));
        }
    }
    let seconds = started.elapsed().as_secs_f64();
    let (cpu_s, cpu_r) = (cpu_seconds(pid_s) - cpu_s0, cpu_seconds(pid_r) - cpu_r0);
    let received: Vec<PathBuf> = ids
        .iter()
        .filter_map(|id| {
            log_r.events.iter().find(|(_, e)| e["event"] == "received_file" && e["transfer"] == id.as_str())
        })
        .map(|(_, e)| PathBuf::from(e["path"].as_str().unwrap_or_default()))
        .collect();
    let intact = received.len() == digests.len()
        && received.iter().zip(&digests).all(|(path, digest)| digest_of(path).as_ref() == Some(digest));
    result["seconds"] = json!(seconds);
    result["mbyte_per_s"] = json!(total as f64 / seconds / 1e6);
    result["link_share"] = json!(total as f64 / seconds / together);
    result["best_route_share"] = json!(total as f64 / seconds / best);
    result["route_bytes"] = json!(proxies.iter().map(|p| p.counts().0).collect::<Vec<_>>());
    result["cpu_sender_s_per_gb"] = json!(cpu_s / (total as f64 / 1e9));
    result["cpu_receiver_s_per_gb"] = json!(cpu_r / (total as f64 / 1e9));
    result["intact"] = json!(intact);
    if !intact {
        return Err("the received bytes differ from the sent ones".into());
    }
    Ok(())
}

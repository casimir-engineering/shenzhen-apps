//! One bench case measured (bench.rs): the two peers started with their routes, the file sent, and a stalled pair
//! recovered once before it counts as failed.

use super::*;

pub(super) fn measure(
    case: &Case,
    sender_spec: &PeerSpec,
    receiver_spec: &PeerSpec,
    result: &mut Value,
) -> Result<(), String> {
    let homes = (TempHome::new("bench-s"), TempHome::new("bench-r"), TempHome::new("bench-content"));
    let mut sender = sender_spec.start(&homes.0.path().join("state"), "Sender");
    let mut receiver = receiver_spec.start(&homes.1.path().join("state"), "Receiver");
    let (pid_s, pid_r) = (sender.pid(), receiver.pid());
    befriend(&mut sender, &mut receiver, ("Sender", "Receiver"));
    let (keys_s, keys_r) = (keys(&mut sender), keys(&mut receiver));
    // The newest minor each side speaks; peers before WP5 do not say (released apps speak 3).
    for (key, peer) in [("sender_session_minor", &mut sender), ("receiver_session_minor", &mut receiver)] {
        result[key] = peer.command(json!({ "cmd": "hello" }))["session_minor"].clone();
    }
    let (mut log_s, mut log_r) = (Log::new(), Log::new());
    let total: u64 = case.files.iter().sum();
    // A peer that declares its route dials, so the session's class is the emulated route's.
    let sender_dials = sender_spec.declares_route || !receiver_spec.declares_route;
    let declared = if sender_dials { sender_spec.declares_route } else { receiver_spec.declares_route };
    result["declared_route"] = json!(if declared { case.route.class } else { "lan" });
    let port = listen(if sender_dials { &mut receiver } else { &mut sender });
    let proxy = Proxy::start(port);
    let mut tamper = case.route.tamper();
    match case.loss {
        Loss::None => {}
        Loss::Cut(fraction) if sender_dials => tamper.cut_to_listener_after = Some((total as f64 * fraction) as u64),
        Loss::Cut(fraction) => tamper.cut_to_dialer_after = Some((total as f64 * fraction) as u64),
        Loss::Silence(fraction) => tamper.silence_after = Some((total as f64 * fraction) as u64),
    }
    proxy.set(tamper);
    let remote = if sender_dials { &keys_r } else { &keys_s };
    let dial = json!({
        "cmd": "dial", "port": proxy.port(), "pattern": "IK", "remote_static": remote.static_key,
        "expected_identity": remote.identity, "route": case.route.class,
    });
    let step = Duration::from_secs(30);
    {
        let dialer: &mut ObjcPeer = if sender_dials { &mut sender } else { &mut receiver };
        dialer.command(dial.clone());
    }
    let (_, live_s) =
        log_s.wait(&mut sender, 0, step, is("established")).ok_or("the sender's session never came up")?;
    let (_, live_r) =
        log_r.wait(&mut receiver, 0, step, is("established")).ok_or("the receiver's session never came up")?;
    result["minor"] = live_s["minor"].clone();
    if live_r["minor"] != live_s["minor"] {
        return Err(format!("the two sides negotiated different minors: {live_s} and {live_r}"));
    }
    for key in ["fast", "capabilities"] {
        if !live_s[key].is_null() {
            result[key] = live_s[key].clone();
        }
    }
    let session = live_s["session"].as_u64().ok_or("no session id")?;
    let mut digests = Vec::new();
    let mut paths = Vec::new();
    for (index, size) in case.files.iter().enumerate() {
        let path = homes.2.path().join(format!("file-{index}.bin"));
        digests.push(bench_content(&path, &format!("bench {} {index}", case.name), *size));
        paths.push(path);
    }
    let (cpu_s0, cpu_r0) = (cpu_seconds(pid_s), cpu_seconds(pid_r));
    let started = Instant::now();
    let mut ids = Vec::new();
    // Many files go as a person sends them, together (send_files, one store batch), where the peer can; one by one
    // otherwise.
    if paths.len() > 1 {
        let all: Vec<String> = paths.iter().map(|p| p.to_string_lossy().into_owned()).collect();
        let offers = sender.command(json!({ "cmd": "send_files", "session": session, "paths": all }));
        for offer in offers["transfers"].as_array().into_iter().flatten() {
            ids.push(offer["transfer"].as_str().ok_or_else(|| format!("send_files failed: {offers}"))?.to_owned());
        }
    }
    if ids.is_empty() {
        for path in &paths {
            let offer =
                sender.command(json!({ "cmd": "send_file", "session": session, "path": path.to_string_lossy() }));
            let id = offer["transfer"].as_str().ok_or_else(|| format!("send_file failed: {offer}"))?.to_owned();
            ids.push(id);
        }
    }
    result["offer_seconds"] = json!(started.elapsed().as_secs_f64());
    let expected = case.route.expected_bytes_per_second().map_or(60.0, |rate| total as f64 / rate);
    let long = Duration::from_secs_f64(expected * 4.0 + 120.0);
    if case.loss != Loss::None {
        recover(
            case,
            &mut (&mut sender, &mut log_s),
            &mut (&mut receiver, &mut log_r),
            &proxy,
            sender_dials,
            &dial,
            result,
        )?;
    }
    let mut received = Vec::new();
    for id in &ids {
        let (_, event) = log_r
            .wait(&mut receiver, 0, long, |e| e["event"] == "received_file" && e["transfer"] == id.as_str())
            .ok_or_else(|| format!("{id} not received within {long:?}"))?;
        received.push(PathBuf::from(event["path"].as_str().unwrap_or_default()));
    }
    let seconds = started.elapsed().as_secs_f64();
    let (cpu_s, cpu_r) = (cpu_seconds(pid_s) - cpu_s0, cpu_seconds(pid_r) - cpu_r0);
    for id in &ids {
        log_s
            .wait(&mut sender, 0, step, |e| e["event"] == "delivered" && e["transfer"] == id.as_str())
            .ok_or_else(|| format!("{id} received but its sender never heard"))?;
    }
    let failed = log_s.events.iter().chain(&log_r.events).find(|(_, e)| e["event"] == "transfer_failed");
    if let Some((_, event)) = failed {
        return Err(format!("a transfer failed on the way: {event}"));
    }
    let intact = received.iter().zip(&digests).all(|(path, digest)| digest_of(path).as_ref() == Some(digest));
    result["seconds"] = json!(seconds);
    result["mbyte_per_s"] = json!(total as f64 / seconds / 1e6);
    if let Some(rate) = case.route.expected_bytes_per_second() {
        result["link_share"] = json!(total as f64 / seconds / rate);
    }
    // What crossed the route toward the receiver: more than the file without compression, less with it (§ 9.4).
    result["route_bytes"] = json!(proxy.counts().0);
    result["cpu_sender_s"] = json!(cpu_s);
    result["cpu_receiver_s"] = json!(cpu_r);
    result["cpu_sender_s_per_gb"] = json!(cpu_s / (total as f64 / 1e9));
    result["cpu_receiver_s_per_gb"] = json!(cpu_r / (total as f64 / 1e9));
    result["intact"] = json!(intact);
    if !intact {
        return Err("the received bytes differ from the sent ones".into());
    }
    Ok(())
}

pub(super) type Side<'a, 'b> = (&'a mut ObjcPeer, &'b mut Log);

/// After a cut or a silence: who noticed and when, then the route comes back (the harness dials again through the
/// proxy, now without loss, as the route racer would), and where and how soon the sender resumed.
pub(super) fn recover(
    case: &Case,
    sender: &mut Side,
    receiver: &mut Side,
    proxy: &Proxy,
    sender_dials: bool,
    dial: &Value,
    result: &mut Value,
) -> Result<(), String> {
    let expected =
        case.route.expected_bytes_per_second().map_or(60.0, |rate| case.files.iter().sum::<u64>() as f64 / rate);
    let deadline = Instant::now() + Duration::from_secs_f64(expected * 2.0 + 60.0);
    let lost_at = loop {
        if let Some(at) = proxy.lost_at() {
            break at;
        }
        if Instant::now() > deadline {
            return Err("the route was never lost: the transfer ended first".into());
        }
        sender.1.drain(sender.0);
        receiver.1.drain(receiver.0);
        std::thread::sleep(Duration::from_millis(5));
    };
    let (to_listener, to_dialer) = proxy.counts();
    result["lost_after_bytes"] = json!(if sender_dials { to_listener } else { to_dialer });
    let (from_s, from_r) = (sender.1.events.len(), receiver.1.events.len());
    let window = match case.loss {
        Loss::Silence(_) => case.silence_wait,
        _ => Duration::from_secs(30),
    };
    // Whoever notices first: watch both sides in turn until the window ends.
    let until = lost_at + window;
    let mut noticed = None;
    let short = Duration::from_millis(20);
    while noticed.is_none() && Instant::now() < until {
        noticed = sender
            .1
            .wait(sender.0, from_s, short, is("closed"))
            .or_else(|| receiver.1.wait(receiver.0, from_r, short, is("closed")))
            .map(|(at, _)| at.duration_since(lost_at).as_secs_f64());
    }
    result["noticed_s"] = json!(noticed);
    let from_s = sender.1.events.len();
    proxy.set(case.route.tamper());
    let dialer: &mut ObjcPeer = if sender_dials { sender.0 } else { receiver.0 };
    let reply = dialer.command(dial.clone());
    if reply["session"].is_null() {
        return Err(format!("the second dial failed: {reply}"));
    }
    let (at, resumed) = sender
        .1
        .wait(sender.0, from_s, Duration::from_secs(60), is("sending"))
        .ok_or("the sender never resumed on the new route")?;
    result["resume_offset"] = resumed["offset"].clone();
    result["resent_bytes"] =
        json!(result["lost_after_bytes"].as_u64().unwrap_or(0).saturating_sub(resumed["offset"].as_u64().unwrap_or(0)));
    result["recovery_s"] = json!(at.duration_since(lost_at).as_secs_f64());
    Ok(())
}

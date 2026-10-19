//! Probing on loopback.

use super::*;
use std::net::UdpSocket;
use std::sync::mpsc::channel;

fn config(role: ProbeRole, remote: SocketAddr, local: (&str, &str), other: (&str, &str)) -> ProberConfig {
    let mut config = ProberConfig::new(role, vec![role as u8], remote);
    config.presented = vec![remote];
    (config.local_ufrag, config.local_password) = (local.0.into(), local.1.into());
    (config.remote_ufrag, config.remote_password) = (other.0.into(), other.1.into());
    (config.loopback_only, config.socket_count, config.duration) = (true, 32, Duration::from_secs(5));
    config.port_range = (40000, 40100);
    config.budget = Some(Arc::new(Mutex::new(ProbeBudget::default())));
    config
}

/// Both roles on loopback (no NAT between them): the easy side prepares, the hard side's probes reach it, and
/// both agree on one pair, whose ports are free again when the hit is reported.
#[test]
fn hard_and_easy_sides_agree_on_a_pair() {
    let (hard, easy) = (("hard", "hardpasswordhardpassword"), ("easy", "easypasswordeasypassword"));
    let (events, results) = channel();
    let to_easy = events.clone();
    let anywhere: SocketAddr = "127.0.0.1:9".parse().unwrap();
    let easy_prober = Prober::spawn(
        config(ProbeRole::Easy, anywhere, easy, hard),
        Box::new(move |event| {
            let _ = to_easy.send(("easy", event));
        }),
    );
    let ("easy", ProberEvent::Prepared(Some(easy_address))) = results.recv().unwrap() else { panic!("prepared") };
    let hard_prober = Prober::spawn(
        config(ProbeRole::Hard, easy_address, hard, easy),
        Box::new(move |event| {
            let _ = events.send(("hard", event));
        }),
    );
    let mut hits = Vec::new();
    while hits.len() < 2 {
        match results.recv_timeout(Duration::from_secs(10)).unwrap() {
            (side, ProberEvent::Finished(Ok(hit))) => hits.push((side, hit)),
            (side, other) => panic!("{side}: {other:?}"),
        }
    }
    let hit = |side: &str| hits.iter().find(|(s, _)| *s == side).unwrap().1;
    assert_eq!(hit("hard").remote, easy_address);
    assert_eq!(hit("easy").remote.port(), hit("hard").local_port);
    assert!(UdpSocket::bind(("127.0.0.1", hit("hard").local_port)).is_ok(), "the winning port is free again");
    drop((easy_prober, hard_prober));
}

//! Two peers in one process open a data channel over 127.0.0.1 and echo a message; prints "ok" and exits 0. The
//! size measurement (tools/datachannel-sizes.sh) builds it in release beside `baseline` to see what the stack adds,
//! and it is a quick check on a device or VM where the test harness is awkward to run.

use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant};

use szfriends_datachannel_sys::{sdp_mid, Config, DataChannel, Event, PeerConnection};

fn peer() -> (PeerConnection, Receiver<Event>, u16) {
    let port = std::net::UdpSocket::bind("127.0.0.1:0").and_then(|s| s.local_addr()).expect("a free port").port();
    let config = Config { bind_address: Some("127.0.0.1".into()), port_range: Some((port, port)), ..Config::default() };
    let (pc, events) = PeerConnection::new(&config).expect("a peer connection");
    (pc, events, port)
}

fn main() {
    szfriends_datachannel_sys::log_to_stderr(false);
    let (offerer, offerer_events, offerer_port) = peer();
    let (answerer, answerer_events, answerer_port) = peer();
    let channel = offerer.create_data_channel("szfriends").expect("a data channel");
    let mut remote: Option<DataChannel> = None;
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        assert!(Instant::now() < deadline, "timed out");
        for event in offerer_events.try_iter() {
            match event {
                Event::LocalDescription { sdp, kind } => {
                    answerer.set_remote_description(&sdp, &kind).expect("the offer applies");
                    let candidate = format!("candidate:1 1 UDP 2130706431 127.0.0.1 {offerer_port} typ host");
                    answerer.add_remote_candidate(&candidate, sdp_mid(&sdp).as_deref()).expect("a candidate");
                }
                Event::ChannelOpen(_) => channel.send(b"Shenzhen Friends").expect("send"),
                Event::Message { data, .. } => {
                    assert_eq!(data, b"Shenzhen Friends");
                    println!("ok: {} over {:?}", szfriends_datachannel_sys::mbedtls_version(), offerer.selected_pair());
                    return;
                }
                _ => {}
            }
        }
        for event in answerer_events.try_iter() {
            match event {
                Event::LocalDescription { sdp, kind } => {
                    offerer.set_remote_description(&sdp, &kind).expect("the answer applies");
                    let candidate = format!("candidate:1 1 UDP 2130706431 127.0.0.1 {answerer_port} typ host");
                    offerer.add_remote_candidate(&candidate, sdp_mid(&sdp).as_deref()).expect("a candidate");
                }
                Event::DataChannel(channel) => remote = Some(channel),
                Event::Message { data, .. } => remote.as_ref().expect("a channel").send(&data).expect("echo"),
                _ => {}
            }
        }
        std::thread::sleep(Duration::from_millis(2));
    }
}

// udp-forward — for an Android emulator in a Friends test (phones-join.mjs --route online): what the app sends to
// 127.0.0.1:<port> over UDP reaches the Mac's 127.0.0.1:<port> through the emulator's 10.0.2.2, and the answers come
// back, for each port named. adb reverse does the same for TCP (the host's WebSocket); the relay and STUN are UDP.
// A test home's online stack reaches only loopback, so this is how the phone reaches the relay running on the Mac.
//
//   rustc --edition 2021 -O --target aarch64-linux-android -C linker=<NDK clang> udp-forward.rs
//   udp-forward <port>...
use std::collections::HashMap;
use std::net::{SocketAddr, UdpSocket};
use std::sync::{Arc, Mutex};
use std::thread;

fn forward(port: u16) {
    let local = Arc::new(UdpSocket::bind(("127.0.0.1", port)).expect("the port is free on the emulator"));
    let upstream: SocketAddr = ([10, 0, 2, 2], port).into();
    let peers: Arc<Mutex<HashMap<SocketAddr, Arc<UdpSocket>>>> = Arc::default();
    let mut buffer = [0u8; 65536];
    loop {
        let Ok((size, from)) = local.recv_from(&mut buffer) else { continue };
        let socket = {
            let mut peers = peers.lock().unwrap();
            peers
                .entry(from)
                .or_insert_with(|| {
                    // One socket toward the Mac per sender here, so each answer finds its way back.
                    let socket = Arc::new(UdpSocket::bind("0.0.0.0:0").expect("a socket"));
                    socket.connect(upstream).expect("10.0.2.2");
                    let (back, local) = (socket.clone(), local.clone());
                    thread::spawn(move || {
                        let mut buffer = [0u8; 65536];
                        while let Ok(size) = back.recv(&mut buffer) {
                            let _ = local.send_to(&buffer[..size], from);
                        }
                    });
                    socket
                })
                .clone()
        };
        let _ = socket.send(&buffer[..size]);
    }
}

fn main() {
    let ports: Vec<u16> = std::env::args().skip(1).filter_map(|a| a.parse().ok()).collect();
    if ports.is_empty() {
        eprintln!("usage: udp-forward <port>...");
        std::process::exit(64);
    }
    let threads: Vec<_> = ports.into_iter().map(|port| thread::spawn(move || forward(port))).collect();
    println!("forwarding");
    for thread in threads {
        let _ = thread.join();
    }
}

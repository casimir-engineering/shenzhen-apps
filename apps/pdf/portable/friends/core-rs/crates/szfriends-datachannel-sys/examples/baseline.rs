//! The size baseline for dc_echo: the same standard-library machinery (a thread, a channel, a UDP socket, printing)
//! without the stack, so the difference between the two stripped binaries is what the stack and its wrapper add.

fn main() {
    let port = std::net::UdpSocket::bind("127.0.0.1:0").and_then(|s| s.local_addr()).expect("a free port").port();
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || sender.send(port).expect("send"));
    println!("ok: {:?}", receiver.recv_timeout(std::time::Duration::from_secs(1)));
}

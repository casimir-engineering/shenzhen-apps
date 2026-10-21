//! For end-to-end tests on any computer, the Mac included: `loopback-peer <home>` runs the Friends service for a
//! test home in this process, as a phone's app does, with its loopback test routes (`$SZFRIENDS_STATE_DIR` must name
//! the same home and `$SZFRIENDS_TEST_LOOPBACK` the routes' directory). Each line on stdin is one intent (JSON,
//! without `id`, which is added); every frame the service sends is printed as one JSON line. The far end of the
//! phone checks (Shenzhen 3D's `scripts/friends/phones-exchange.mjs`).

use std::io::{BufRead, Write};
use std::sync::mpsc::channel;
use std::sync::Arc;

use serde_json::{json, Value};
use szfriends_contract::framing::encode;
use szfriends_contract::handshake::HelperFacts;
use szfriends_contract::lifecycle::PROTOCOL;
use szfriends_helper::client::{AppInfo, ClientConnection};
use szfriends_helper::server::Server;
use szfriends_helper::service::{seed, Service};
use szfriends_helper::transport::{memory_pair, PeerInfo};

fn main() -> std::process::ExitCode {
    let Some(home) = std::env::args().nth(1) else {
        eprintln!("usage: loopback-peer <home>");
        return std::process::ExitCode::from(64);
    };
    let service = match Service::start(home.as_ref(), seed::test_key_store(home.as_ref())) {
        Ok(service) => service,
        Err(error) => {
            eprintln!("loopback-peer: {error}");
            return std::process::ExitCode::FAILURE;
        }
    };
    let facts = HelperFacts { version: "1.0".into(), build_number: 1, protocol: PROTOCOL, pid: std::process::id() };
    let server = Server::new(service.clone(), facts, channel().0, Box::new(|_, _| false));
    let (ours, theirs) = memory_pair();
    server.add(theirs, PeerInfo::default());
    let mut connection = ClientConnection::new(ours);
    let app = AppInfo {
        app_id: "com.example.loopback-peer".into(),
        app_name: "Loopback Peer".into(),
        app_version: "1.0".into(),
        toolkit: "cli".into(),
        reveal_in: "Finder".into(),
        capabilities: vec!["drop.files".into()],
        open_formats: vec!["stl".into(), "step".into()],
        locale: "en".into(),
        url_scheme: None,
    };
    match connection.hello(&app, None) {
        Ok(welcome) => println!("{}", json!({"type": "ready", "welcome": welcome["type"]})),
        Err(error) => {
            eprintln!("loopback-peer: no welcome: {error}");
            return std::process::ExitCode::FAILURE;
        }
    }
    let stream = connection.stream();
    let printer = std::thread::spawn(move || {
        let stdout = std::io::stdout();
        while let Ok(Some(frame)) = connection.next_frame() {
            let mut out = stdout.lock();
            let _ = writeln!(out, "{frame}");
            let _ = out.flush();
        }
    });
    for (number, line) in std::io::stdin().lock().lines().map_while(Result::ok).enumerate() {
        let Ok(mut frame) = serde_json::from_str::<Value>(&line) else { continue };
        frame["id"] = json!(format!("p{}", number + 1));
        if let Ok(bytes) = encode(&frame) {
            if stream.write_all(&bytes).is_err() {
                break;
            }
        }
    }
    stream.close();
    let _ = printer.join();
    let service: Arc<dyn szfriends_helper::presentation::Presentation> = service;
    service.shutdown();
    std::process::ExitCode::SUCCESS
}

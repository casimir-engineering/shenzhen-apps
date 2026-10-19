//! The host connection over `wss://`: a WebSocket echo server behind TLS (Node's `https` and the host's own `ws`
//! module, on 127.0.0.1) with a certificate from the test CA in `tests/tls/`. The client accepts it when told to
//! trust that CA, by IP address and by name, and refuses it against another CA and against the system's roots, which
//! never hold a test CA. Needs `SZFRIENDS_HOST_SERVER_DIR` (as the online suites); without it the test says so and
//! passes.

use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::channel;
use std::time::Duration;

use szfriends_online::host::websocket::{Endpoint, Roots, Socket, SocketEvent};

const SERVER: &str = r#"
const [wsPath, keyPath, certPath] = process.argv.slice(-3);
const fs = await import('node:fs');
const https = await import('node:https');
const { WebSocketServer } = await import(wsPath);
const server = https.createServer({ key: fs.readFileSync(keyPath), cert: fs.readFileSync(certPath) });
const wss = new WebSocketServer({ server, path: '/v1' });
wss.on('connection', (socket) => socket.on('message', (data) => socket.send(data.toString())));
server.listen(0, '127.0.0.1', () => console.log(server.address().port));
process.stdin.on('end', () => process.exit(0));
process.stdin.resume();
"#;

struct EchoServer(Child, u16);

impl Drop for EchoServer {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/tls")
}

fn echo_server(server_dir: &Path) -> EchoServer {
    let ws = server_dir.join("node_modules/ws/wrapper.mjs");
    let mut child = Command::new("node")
        .args(["--input-type=module", "-e", SERVER, "--"])
        .arg(url_of(&ws))
        .arg(fixtures().join("host-key.pem"))
        .arg(fixtures().join("host.pem"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("node");
    let mut line = String::new();
    BufReader::new(child.stdout.take().unwrap()).read_line(&mut line).unwrap();
    let port = line.trim().parse().expect("the server's port");
    EchoServer(child, port)
}

fn url_of(path: &Path) -> String {
    let text = path.to_string_lossy().replace('\\', "/");
    if text.starts_with('/') {
        format!("file://{text}")
    } else {
        format!("file:///{text}")
    }
}

/// Connects and echoes one message; the error when the connection was refused.
fn echo(url: &str, roots: &Roots) -> Result<String, String> {
    let endpoint = Endpoint::parse(url).ok_or("url")?;
    let (sender, events) = channel();
    let socket = Socket::connect(&endpoint, roots, move |e| drop(sender.send(e)), Duration::from_secs(5))
        .map_err(|e| e.to_string())?;
    assert!(socket.send_text("{\"type\":\"hello\"}"));
    match events.recv_timeout(Duration::from_secs(5)) {
        Ok(SocketEvent::Text(text)) => Ok(text),
        other => Err(format!("{other:?}")),
    }
}

#[test]
fn wss_with_the_host_certificate_checked() {
    let Some(server_dir) = std::env::var_os("SZFRIENDS_HOST_SERVER_DIR").map(PathBuf::from) else {
        eprintln!("SZFRIENDS_HOST_SERVER_DIR is not set: the TLS host test needs Node and the host's ws module");
        return;
    };
    let server = echo_server(&server_dir);
    let ca = Roots::Pem(std::fs::read(fixtures().join("ca.pem")).unwrap());
    let other = Roots::Pem(std::fs::read(fixtures().join("other-ca.pem")).unwrap());
    let by_address = format!("wss://127.0.0.1:{}/v1", server.1);
    let by_name = format!("wss://localhost:{}/v1", server.1);
    assert_eq!(echo(&by_address, &ca).as_deref(), Ok("{\"type\":\"hello\"}"));
    assert_eq!(echo(&by_name, &ca).as_deref(), Ok("{\"type\":\"hello\"}"));
    // Several messages both ways on one connection, larger than one TLS record.
    let endpoint = Endpoint::parse(&by_address).unwrap();
    let (sender, events) = channel();
    let socket = Socket::connect(&endpoint, &ca, move |e| drop(sender.send(e)), Duration::from_secs(5)).unwrap();
    let big = format!("{{\"pad\":\"{}\"}}", "x".repeat(40_000));
    for _ in 0..3 {
        assert!(socket.send_text(&big));
    }
    for _ in 0..3 {
        match events.recv_timeout(Duration::from_secs(5)) {
            Ok(SocketEvent::Text(text)) => assert_eq!(text.len(), big.len()),
            other => panic!("{other:?}"),
        }
    }
    assert!(echo(&by_address, &other).is_err(), "a certificate from another CA is refused");
    assert!(echo(&by_address, &Roots::System).is_err(), "the system never trusts a test CA");
}

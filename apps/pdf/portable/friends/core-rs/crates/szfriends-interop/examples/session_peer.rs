//! The Rust peer in a process of its own, speaking the Objective-C peer's protocol (`tools/objc-session-peer`): one
//! JSON command per line on standard input, `{"reply": ...}` in order on standard output, every other line an event.
//! `session_peer <home> <name>`: the state directory and the name the identity is derived from (BLAKE2b-256 of
//! "<name> seed" and "<name> static", as the vector exporter and the Objective-C peer derive theirs).
//!
//! The transfer bench runs every peer this way so each side's CPU time is its own, the interop matrix builds this file
//! at a release tag for the released Rust core, and `tools/transfer-devices.sh` runs it on another device.

use std::io::{BufRead, Write};
use std::sync::mpsc::{channel, TryRecvError};
use std::time::Duration;

use serde_json::{json, Value};
use szfriends_core::identity::Identity;
use szfriends_interop::{Peer, RustPeer};

fn identity(name: &str) -> Identity {
    let seed = szfriends_core::crypto::blake2b::<32>(None, &[format!("{name} seed").as_bytes()]);
    let mut private = szfriends_core::crypto::blake2b::<32>(None, &[format!("{name} static").as_bytes()]);
    private[0] &= 248;
    private[31] = (private[31] & 127) | 64;
    Identity::from_secrets(&seed, &private)
}

fn main() {
    let mut args = std::env::args().skip(1);
    let (Some(home), Some(name)) = (args.next(), args.next()) else {
        eprintln!("usage: session_peer <home> <name>");
        std::process::exit(2);
    };
    std::fs::create_dir_all(&home).expect("the peer's home");
    let mut peer = RustPeer::start(home.into(), identity(&name));
    let (lines_tx, lines) = channel();
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            if lines_tx.send(line).is_err() {
                return;
            }
        }
    });
    let stdout = std::io::stdout();
    let print = |value: &Value| {
        let mut out = stdout.lock();
        let _ = writeln!(out, "{value}");
        let _ = out.flush();
    };
    loop {
        if let Some(event) = peer.next_event(Duration::from_millis(2)) {
            print(&event);
            continue;
        }
        let line = match lines.try_recv() {
            Ok(line) => line,
            Err(TryRecvError::Empty) => continue,
            Err(TryRecvError::Disconnected) => break,
        };
        let Ok(command) = serde_json::from_str::<Value>(&line) else {
            print(&json!({ "reply": { "error": "not JSON" } }));
            continue;
        };
        let quit = command["cmd"] == "quit";
        if quit {
            break;
        }
        let reply = peer.command(command);
        print(&json!({ "reply": reply }));
    }
    drop(peer);
    print(&json!({ "reply": {} }));
}

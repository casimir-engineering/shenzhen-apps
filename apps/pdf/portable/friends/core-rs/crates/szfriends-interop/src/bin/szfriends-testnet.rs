//! The VM's side of the test network's bridge (`szfriends_interop::bridge`): `szfriends-testnet guest <home>
//! [blocked|firewall]` runs a Rust helper in a test home under `<home>` (accepting connections, or as a computer whose
//! firewall admits none, or as this one's firewall decides) and talks to the Mac over standard input and output. On a
//! Mac, `szfriends-testnet dir <routes> <service type>` joins a loopback test network's directory to the Objective-C
//! helper's Bonjour on lo0 (`bridge::dir`), until its standard input ends. `szfriends-testnet host <dir>` runs the
//! local Friends host with its relay (`host::LocalHost`, from `$SZFRIENDS_HOST_SERVER_DIR` and `$FRIENDS_TEST_COTURN`)
//! with its data under `<dir>`, prints one JSON line naming its URL, its signed list and keys and its relay's and
//! STUN's ports, and stops it when its standard input ends.

fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    let code = match arguments.get(1..).unwrap_or_default() {
        [mode, home] if mode == "guest" => szfriends_interop::bridge::guest::run(std::path::Path::new(home), None),
        [mode, home, inbound] if mode == "guest" => {
            szfriends_interop::bridge::guest::run(std::path::Path::new(home), Some(inbound))
        }
        #[cfg(target_os = "macos")]
        [mode, routes, service] if mode == "dir" => {
            szfriends_interop::bridge::dir::run(std::path::Path::new(routes), service)
        }
        [mode, dir] if mode == "host" => host(std::path::Path::new(dir)),
        _ => {
            eprintln!(
                "usage: szfriends-testnet guest <home> [blocked|firewall] | dir <routes> <service type> | host <dir>"
            );
            2
        }
    };
    std::process::exit(code);
}

fn host(dir: &std::path::Path) -> i32 {
    use szfriends_interop::host::{self, LocalHost};
    let Some(server) = host::server_dir() else {
        eprintln!("szfriends-testnet host: set SZFRIENDS_HOST_SERVER_DIR");
        return 2;
    };
    if let Some(why) = host::unavailable(&server, true) {
        eprintln!("szfriends-testnet host: {why}");
        return 2;
    }
    if let Err(error) = std::fs::create_dir_all(dir) {
        eprintln!("szfriends-testnet host: {}: {error}", dir.display());
        return 1;
    }
    let local = LocalHost::start(&server, dir, true);
    let started = serde_json::json!({
        "url": local.url, "list": local.list_path, "keys": local.keys_path,
        "turn_port": local.turn_port, "stun_port": local.stun_port,
    });
    println!("{started}");
    let _ = std::io::Read::read_to_end(&mut std::io::stdin(), &mut Vec::new());
    drop(local);
    0
}

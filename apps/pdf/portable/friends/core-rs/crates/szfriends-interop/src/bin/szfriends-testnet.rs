//! The VM's side of the test network's bridge (`szfriends_interop::bridge`): `szfriends-testnet guest <home>
//! [blocked|firewall]` runs a Rust helper in a test home under `<home>` (accepting connections, or as a computer whose
//! firewall admits none, or as this one's firewall decides) and talks to the Mac over standard input and output. On a
//! Mac, `szfriends-testnet dir <routes> <service type>` joins a loopback test network's directory to the Objective-C
//! helper's Bonjour on lo0 (`bridge::dir`), until its standard input ends.

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
        _ => {
            eprintln!("usage: szfriends-testnet guest <home> [blocked|firewall] | dir <routes> <service type>");
            2
        }
    };
    std::process::exit(code);
}

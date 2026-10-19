//! `szfnat-rust-peer`: the Rust core as one host of the NAT emulator's punching matrix ([`peer`]). The emulator runs
//! on macOS and hands the signalling socket over as a Unix descriptor, so elsewhere this binary only says so.

#[cfg(unix)]
mod peer;

#[cfg(unix)]
fn main() {
    peer::main();
}

#[cfg(not(unix))]
fn main() {
    eprintln!("szfnat-rust-peer runs inside the NAT emulator, which needs macOS");
    std::process::exit(2);
}

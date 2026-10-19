//! Writes the helper's build stamp (`src/stamp.rs`): the version and build number every copy of this binary carries
//! in its data, so an app can read which helper it embeds without running it, and handover can compare builds.
//! A release sets `SZFRIENDS_HELPER_VERSION` (dotted numbers) and `SZFRIENDS_HELPER_BUILD` (`YYMMDDNN`); a developer
//! build is the crate version with build 0.

use std::env;
use std::fs;
use std::path::Path;

const MAGIC: &[u8; 20] = b"\0SZF-HELPER-STAMP-1\0";
const VERSION_BYTES: usize = 24;
const BUILD_DIGITS: usize = 20;

fn main() {
    println!("cargo:rerun-if-env-changed=SZFRIENDS_HELPER_VERSION");
    println!("cargo:rerun-if-env-changed=SZFRIENDS_HELPER_BUILD");
    let version = env::var("SZFRIENDS_HELPER_VERSION").unwrap_or_else(|_| env::var("CARGO_PKG_VERSION").unwrap());
    let dotted = version.split('.').all(|p| !p.is_empty() && p.len() <= 9 && p.bytes().all(|b| b.is_ascii_digit()));
    assert!(dotted && version.len() < VERSION_BYTES, "SZFRIENDS_HELPER_VERSION must be dotted numbers: {version}");
    let build: u64 = env::var("SZFRIENDS_HELPER_BUILD")
        .map(|b| b.parse().expect("SZFRIENDS_HELPER_BUILD must be a number"))
        .unwrap_or(0);
    let mut stamp = MAGIC.to_vec();
    let mut field = version.into_bytes();
    field.resize(VERSION_BYTES, 0);
    stamp.extend(field);
    stamp.extend(format!("{build:0width$}", width = BUILD_DIGITS).into_bytes());
    let bytes: Vec<String> = stamp.iter().map(|b| b.to_string()).collect();
    let code = format!(
        "/// The build stamp (written by build.rs).\n#[used]\npub(crate) static STAMP: [u8; {}] = [{}];\n",
        stamp.len(),
        bytes.join(", ")
    );
    let out = Path::new(&env::var("OUT_DIR").unwrap()).join("stamp.rs");
    fs::write(out, code).unwrap();
}

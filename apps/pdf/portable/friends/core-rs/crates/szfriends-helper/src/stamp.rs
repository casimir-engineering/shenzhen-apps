//! The build stamp: 64 bytes in the helper's data holding its version and build number (`build.rs` writes them). An
//! app reads the stamp of the helper it embeds without running it (for its `hello` and the versioned copy), and the
//! running helper reads the stamp of the binary a client runs to check that a handover it asks for is real.
//!
//! The helper reads its own stamp from memory at run time rather than from constants, so a binary whose stamp was
//! rewritten ([`restamp`]: a test's "newer build") is that build in every respect.

use std::collections::HashMap;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::SystemTime;

include!(concat!(env!("OUT_DIR"), "/stamp.rs"));

const MAGIC_BYTES: usize = 20;
const VERSION_BYTES: usize = 24;
const BUILD_DIGITS: usize = 20;
const STAMP_BYTES: usize = MAGIC_BYTES + VERSION_BYTES + BUILD_DIGITS;
/// Larger files are not read for a stamp.
const BINARY_MAX: u64 = 512 * 1024 * 1024;
/// How much of a file is read at a time.
const CHUNK: usize = 64 * 1024;
/// Files whose stamp is remembered, at most.
const CACHED_FILES: usize = 64;

/// A helper's version (dotted numbers) and build number (`YYMMDDNN`; 0 for a developer build).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Stamp {
    pub version: String,
    pub build: u64,
}

fn own_bytes() -> [u8; STAMP_BYTES] {
    // Through black_box, so the compiler cannot fold the stamp into constants: a rewritten stamp must count.
    *std::hint::black_box(&STAMP)
}

/// This binary's stamp.
pub fn own() -> Stamp {
    parse(&own_bytes()).expect("build.rs writes a valid stamp")
}

fn parse(bytes: &[u8]) -> Option<Stamp> {
    let magic = &own_bytes()[..MAGIC_BYTES];
    if bytes.len() != STAMP_BYTES || &bytes[..MAGIC_BYTES] != magic {
        return None;
    }
    let field = &bytes[MAGIC_BYTES..MAGIC_BYTES + VERSION_BYTES];
    let end = field.iter().position(|&b| b == 0)?;
    let version = std::str::from_utf8(&field[..end]).ok()?;
    let dotted = version.split('.').all(|p| !p.is_empty() && p.len() <= 9 && p.bytes().all(|b| b.is_ascii_digit()));
    if !dotted || field[end..].iter().any(|&b| b != 0) {
        return None;
    }
    let digits = &bytes[MAGIC_BYTES + VERSION_BYTES..];
    if !digits.iter().all(u8::is_ascii_digit) {
        return None;
    }
    let build = std::str::from_utf8(digits).ok()?.parse().ok()?;
    Some(Stamp { version: version.to_owned(), build })
}

fn offsets(binary: &[u8]) -> Vec<usize> {
    let magic = &own_bytes()[..MAGIC_BYTES];
    let mut found = Vec::new();
    let mut start = 0;
    while let Some(at) = binary[start..].windows(MAGIC_BYTES).position(|w| w == magic) {
        found.push(start + at);
        start += at + 1;
    }
    found
}

/// The stamp a binary carries: exactly one valid stamp, or several that agree. `None` for anything else.
pub fn find(binary: &[u8]) -> Option<Stamp> {
    let stamps: Vec<Stamp> =
        offsets(binary).into_iter().filter_map(|at| binary.get(at..at + STAMP_BYTES).and_then(parse)).collect();
    let first = stamps.first()?;
    stamps.iter().all(|s| s == first).then(|| first.clone())
}

/// Reads the file at `path` (an executable) and returns its stamp, if it has one: in chunks, never the whole file
/// at once, and once per file while it stays the same (a handover check may ask about the same app many times).
pub fn read(path: &Path) -> io::Result<Option<Stamp>> {
    let metadata = std::fs::metadata(path)?;
    let file = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_owned());
    let key = (file, metadata.modified().ok(), metadata.len());
    let cache = read_cache();
    if let Some(found) = cache.lock().unwrap_or_else(|e| e.into_inner()).get(&key) {
        return Ok(found.clone());
    }
    let found = scan(std::fs::File::open(path)?.take(BINARY_MAX))?;
    let mut cached = cache.lock().unwrap_or_else(|e| e.into_inner());
    if cached.len() >= CACHED_FILES {
        cached.clear();
    }
    cached.insert(key, found.clone());
    Ok(found)
}

type ReadKey = (PathBuf, Option<SystemTime>, u64);

fn read_cache() -> &'static Mutex<HashMap<ReadKey, Option<Stamp>>> {
    static CACHE: OnceLock<Mutex<HashMap<ReadKey, Option<Stamp>>>> = OnceLock::new();
    CACHE.get_or_init(Default::default)
}

/// What [`find`] says of everything `reader` gives, read 64 KiB at a time. Each chunk is searched together with the
/// end of the one before, so a stamp across the boundary is found; a stamp is taken only once it is whole, so none
/// is counted twice.
fn scan(mut reader: impl Read) -> io::Result<Option<Stamp>> {
    let mut window: Vec<u8> = Vec::with_capacity(CHUNK + STAMP_BYTES);
    let mut stamps: Vec<Stamp> = Vec::new();
    loop {
        let kept = window.len();
        window.resize(kept + CHUNK, 0);
        let read = loop {
            match reader.read(&mut window[kept..]) {
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                other => break other?,
            }
        };
        window.truncate(kept + read);
        if read == 0 {
            break;
        }
        stamps.extend(offsets(&window).into_iter().filter_map(|at| window.get(at..at + STAMP_BYTES).and_then(parse)));
        // Keep what a stamp starting near the end would still need.
        let keep = window.len().min(STAMP_BYTES - 1);
        window.drain(..window.len() - keep);
    }
    let Some(first) = stamps.first() else { return Ok(None) };
    Ok(stamps.iter().all(|s| s == first).then(|| first.clone()))
}

/// Rewrites the build number of every stamp in `binary`; returns how many. For tests (a newer build of the same
/// binary) and for release tooling that numbers a build after linking.
pub fn restamp(binary: &mut [u8], build: u64) -> usize {
    let digits = format!("{build:0width$}", width = BUILD_DIGITS);
    let mut count = 0;
    for at in offsets(binary) {
        if binary.get(at..at + STAMP_BYTES).and_then(parse).is_some() {
            binary[at + MAGIC_BYTES + VERSION_BYTES..at + STAMP_BYTES].copy_from_slice(digits.as_bytes());
            count += 1;
        }
    }
    count
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_stamp_is_found_read_and_rewritten() {
        let own = own();
        assert!(!own.version.is_empty());
        let mut binary = b"some code".to_vec();
        binary.extend_from_slice(&own_bytes());
        binary.extend_from_slice(b"more code");
        assert_eq!(find(&binary), Some(own.clone()));
        assert_eq!(restamp(&mut binary, 26102001), 1);
        assert_eq!(find(&binary), Some(Stamp { build: 26102001, ..own.clone() }));
        assert_eq!(find(b"no stamp here"), None);
        let mut broken = binary.clone();
        let digit = broken.len() - b"more code".len() - 1;
        broken[digit] = b'x';
        assert_eq!(find(&broken), None, "a damaged stamp is no stamp");
        let mut two = binary.clone();
        two.extend_from_slice(&own_bytes());
        assert_eq!(find(&two), None, "two stamps that disagree");
    }

    /// Read in chunks, a stamp is found wherever it lies, across a chunk boundary too, and judged as `find` does.
    #[test]
    fn a_stamp_is_found_in_any_chunk_and_across_their_boundaries() {
        let own = own();
        for offset in [0, 5, CHUNK - STAMP_BYTES, CHUNK - 30, CHUNK - 1, CHUNK, 3 * CHUNK - 7, 3 * CHUNK + 100] {
            let mut binary = vec![0x5a; offset];
            binary.extend_from_slice(&own_bytes());
            binary.extend_from_slice(&[0x5a; 70_000]);
            assert_eq!(scan(&binary[..]).unwrap(), find(&binary), "at {offset}");
            assert_eq!(scan(&binary[..]).unwrap(), Some(own.clone()), "at {offset}");
            let mut two = binary.clone();
            two.extend_from_slice(&own_bytes());
            let last = offset + STAMP_BYTES - 1;
            two[last] = if two[last] == b'7' { b'8' } else { b'7' };
            assert_eq!(scan(&two[..]).unwrap(), None, "two that disagree, the first at {offset}");
        }
        let mut cut = vec![0x5a; CHUNK - 10];
        cut.extend_from_slice(&own_bytes()[..30]);
        assert_eq!(scan(&cut[..]).unwrap(), None, "a stamp cut off by the end of the file");
        assert_eq!(scan(&b""[..]).unwrap(), None);
    }

    #[test]
    fn a_file_is_read_again_only_when_it_changes() {
        let path = std::env::temp_dir().join(format!("szf-stamp-{}", std::process::id()));
        let mut binary = vec![1u8; 100_000];
        binary.extend_from_slice(&own_bytes());
        std::fs::write(&path, &binary).unwrap();
        assert_eq!(read(&path).unwrap(), Some(own()));
        restamp(&mut binary, 26102001);
        binary.push(0); // a different length, so the change shows whatever the clock's resolution
        std::fs::write(&path, &binary).unwrap();
        assert_eq!(read(&path).unwrap().map(|s| s.build), Some(26102001));
        std::fs::remove_file(&path).unwrap();
    }

    #[test]
    fn this_test_binary_carries_the_stamp() {
        let path = std::env::current_exe().expect("test binary");
        assert_eq!(read(&path).expect("readable"), Some(own()));
    }
}

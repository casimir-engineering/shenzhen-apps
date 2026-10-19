//! Files the panel shows but the page cannot read: previews and photos from the Friends state directory, and the
//! animal set; the rules of Shenzhen 3D's Electron bridge (`electron/friends/files.cjs`), which are PROTOCOL.md's
//! (§ Shared objects, Avatar; § Thumbnails): a path is judged by the path alone, the file is opened without
//! following a link and without blocking, and only a small regular file whose header declares the expected kind and
//! size is returned. Decoding happens in the page, which checks the decoded size again, so nothing here decodes what
//! a friend sent. Also: what a dropped path is, the received files a snapshot offers to open, and staged copies.

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde_json::{json, Value};

const MAX_IMAGE_BYTES: u64 = 256 * 1024;
const MAX_SVG_BYTES: u64 = 64 * 1024;
/// The most one staged file may hold. Its bytes cross into Rust in one piece: a phone takes what the panel stages of
/// a dropped file and no more; a desktop, a project the page made.
pub const MAX_STAGED_BYTES: usize =
    if cfg!(any(target_os = "android", target_os = "ios")) { crate::STAGED_DROP_LIMIT as usize } else { 1 << 30 };
/// Staged copies stay while a download link may still serve them, the longest a link lives plus a day.
const STAGED_DAYS: u64 = 31;

/// An image's kind and size, from its header.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ImageSize {
    pub kind: &'static str,
    pub width: u32,
    pub height: u32,
}

pub fn png_size(bytes: &[u8]) -> Option<ImageSize> {
    const SIGNATURE: [u8; 8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    if bytes.len() < 24 || bytes[..8] != SIGNATURE || &bytes[12..16] != b"IHDR" {
        return None;
    }
    let word = |at: usize| u32::from_be_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]]);
    Some(ImageSize { kind: "image/png", width: word(16), height: word(20) })
}

pub fn jpeg_size(bytes: &[u8]) -> Option<ImageSize> {
    if bytes.len() < 4 || bytes[0] != 0xff || bytes[1] != 0xd8 {
        return None;
    }
    let half = |at: usize| u16::from_be_bytes([bytes[at], bytes[at + 1]]) as u32;
    let mut offset = 2;
    while offset + 9 < bytes.len() {
        if bytes[offset] != 0xff {
            return None;
        }
        let marker = bytes[offset + 1];
        if marker == 0xff {
            offset += 1;
            continue;
        }
        let length = half(offset + 2) as usize;
        if length < 2 {
            return None;
        }
        // Start of frame, any kind but the DHT, JPG and DAC markers that share the range.
        if (0xc0..=0xcf).contains(&marker) && ![0xc4, 0xc8, 0xcc].contains(&marker) {
            return Some(ImageSize { kind: "image/jpeg", height: half(offset + 5), width: half(offset + 7) });
        }
        offset += 2 + length;
    }
    None
}

/// The directory names a helper path may sit in, as given and canonical.
fn state_directories(state_dir: &Path) -> Vec<PathBuf> {
    let mut names = vec![state_dir.to_path_buf()];
    if let Ok(real) = fs::canonicalize(state_dir) {
        if real != state_dir {
            names.push(real);
        }
    }
    names
}

/// Whether `file` names an entry directly inside `<state dir>/<folder>/`: no subfolder, no `.` or `..`.
pub fn directly_inside(file: &str, state_dir: &Path, folder: &str) -> bool {
    if !crate::validate::plain_path(file) {
        return false;
    }
    let path = Path::new(file);
    let (Some(parent), Some(_)) = (path.parent(), path.file_name()) else { return false };
    state_directories(state_dir).iter().any(|directory| parent == directory.join(folder))
}

fn read_small_regular_file(file: &Path, max: u64) -> Option<Vec<u8>> {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // O_NOFOLLOW: a planted link is never followed. O_NONBLOCK: a FIFO in its place cannot block the open.
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        // FILE_FLAG_OPEN_REPARSE_POINT: a link or junction is opened as itself, which is then not a plain file.
        options.custom_flags(0x0020_0000);
    }
    let mut handle = options.open(file).ok()?;
    let metadata = handle.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > max {
        return None;
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    handle.by_ref().take(max + 1).read_to_end(&mut bytes).ok()?;
    (bytes.len() as u64 == metadata.len()).then_some(bytes)
}

/// A preview (`thumbnail`) or a friend's photo (`picture`) from the Friends state directory: the image's kind and
/// size and its bytes, or None when it fails any check. A thumbnail must be a PNG of exactly the size its snapshot
/// declared; a picture a JPEG or PNG of 1 to 1024 pixels a side.
pub fn read_helper_image(
    state_dir: Option<&Path>,
    kind: &str,
    file: &str,
    expected: (Option<u32>, Option<u32>),
) -> Option<(ImageSize, Vec<u8>)> {
    let folder = match kind {
        "thumbnail" => "thumbnails",
        "picture" => "pictures",
        _ => return None,
    };
    let state_dir = state_dir?;
    if !directly_inside(file, state_dir, folder) {
        return None;
    }
    let bytes = read_small_regular_file(Path::new(file), MAX_IMAGE_BYTES)?;
    let size = if kind == "thumbnail" { png_size(&bytes)? } else { png_size(&bytes).or_else(|| jpeg_size(&bytes))? };
    let largest = if kind == "thumbnail" { 192 } else { 1024 };
    if kind == "thumbnail" && (Some(size.width), Some(size.height)) != expected {
        return None;
    }
    if !(1..=largest).contains(&size.width) || !(1..=largest).contains(&size.height) {
        return None;
    }
    Some((size, bytes))
}

/// The bundled animal set, read on first use.
#[derive(Debug)]
pub struct AnimalSet {
    directory: PathBuf,
    manifest: std::sync::OnceLock<Option<Value>>,
}

impl AnimalSet {
    pub fn new(directory: PathBuf) -> Self {
        Self { directory, manifest: std::sync::OnceLock::new() }
    }

    fn manifest(&self) -> Option<&Value> {
        self.manifest
            .get_or_init(|| {
                let text = fs::read_to_string(self.directory.join("manifest.json")).ok()?;
                serde_json::from_str(&text).ok()
            })
            .as_ref()
    }

    /// `{svg, color, name}` for one animal of the bundled set, or None (an index newer than the set).
    pub fn animal(&self, set: &Value, index: &Value) -> Option<Value> {
        let data = self.manifest()?;
        if data["set"] != *set || !index.is_i64() && !index.is_u64() {
            return None;
        }
        let entry = data["animals"].as_array()?.iter().find(|animal| animal["index"] == *index)?;
        let svg = entry["svg"].as_str()?;
        let name = svg.strip_prefix("svg/")?.strip_suffix(".svg")?;
        if name.is_empty() || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)) {
            return None;
        }
        let bytes = read_small_regular_file(&self.directory.join(svg), MAX_SVG_BYTES)?;
        let text = String::from_utf8(bytes).ok()?;
        let field = |key: &str| entry[key].as_str().map(str::to_owned).unwrap_or_else(|| display(&entry[key]));
        Some(json!({"svg": text, "color": field("color"), "name": field("name")}))
    }

    /// The set's number and every animal's index and name, for the profile's picker.
    pub fn list(&self) -> Option<Value> {
        let data = self.manifest()?;
        let animals: Vec<Value> = data["animals"]
            .as_array()
            .map(|list| {
                list.iter()
                    .map(|a| json!({"index": a["index"], "name": display(&a["name"]), "color": display(&a["color"])}))
                    .collect()
            })
            .unwrap_or_default();
        Some(json!({"set": data["set"], "animals": animals}))
    }
}

/// JavaScript's `String(value ?? "")`, for the manifest's text fields.
fn display(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::String(text) => text.clone(),
        other => other.to_string(),
    }
}

/// What a dropped path is, for refusing folders and links while the person still holds the drag.
pub fn classify_path(file: &str) -> &'static str {
    match fs::symlink_metadata(file) {
        Ok(metadata) if metadata.is_file() => "file",
        Ok(metadata) if metadata.is_dir() => "folder",
        Ok(_) => "other",
        Err(_) => "missing",
    }
}

/// Every path a snapshot offers to open: its `open_file` actions (PROTOCOL.md § Shared objects, Action).
pub fn openable_paths(value: &Value, found: &mut Vec<String>, depth: usize) {
    if depth > 32 {
        return;
    }
    match value {
        Value::Array(list) => list.iter().for_each(|entry| openable_paths(entry, found, depth + 1)),
        Value::Object(object) => {
            if object.get("action").and_then(Value::as_str) == Some("open_file") {
                if let Some(path) = object.get("path").and_then(Value::as_str) {
                    found.push(path.to_owned());
                }
            }
            object.values().filter(|v| v.is_object() || v.is_array()).for_each(|v| openable_paths(v, found, depth + 1));
        }
        _ => {}
    }
}

/// A project the page made, written where only this app looks, for send_files, `#` or a download link: a plain
/// name of at most 200 bytes ending in one of `extensions` (any, when there are none), not starting with a dot.
pub fn stage(outgoing: &Path, name: &str, bytes: &[u8], extensions: &[String]) -> Result<PathBuf, &'static str> {
    let lower = name.to_lowercase();
    let plain = !name.is_empty()
        && Path::new(name).file_name().and_then(|n| n.to_str()) == Some(name)
        && !name.starts_with('.')
        && name.len() <= 200
        && !name.contains(['\0', '/', '\\'])
        && (extensions.is_empty()
            || extensions.iter().any(|e| lower.ends_with(&format!(".{e}")) && lower.len() > e.len() + 1));
    if !plain {
        return Err("Invalid project name");
    }
    if bytes.len() > MAX_STAGED_BYTES {
        return Err("Invalid project");
    }
    let mut random = [0u8; 16];
    szfriends_crypto::random_bytes(&mut random);
    let directory = outgoing.join(random.iter().map(|b| format!("{b:02x}")).collect::<String>());
    szfriends_helper::state::create_private_dir(&directory).map_err(|_| "Could not stage")?;
    let file = directory.join(name);
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut handle = options.open(&file).map_err(|_| "Could not stage")?;
    std::io::Write::write_all(&mut handle, bytes).map_err(|_| "Could not stage")?;
    handle.sync_all().map_err(|_| "Could not stage")?;
    Ok(file)
}

/// Removes staged copies older than a link can live, plus a day.
pub fn sweep_outgoing(outgoing: &Path) {
    let Ok(entries) = fs::read_dir(outgoing) else { return };
    let cutoff = SystemTime::now() - Duration::from_secs(STAGED_DAYS * 24 * 3600);
    for entry in entries.filter_map(Result::ok) {
        let old =
            entry.metadata().ok().filter(|m| m.is_dir()).and_then(|m| m.modified().ok()).is_some_and(|t| t < cutoff);
        if old {
            let _ = fs::remove_dir_all(entry.path());
        }
    }
}

#[cfg(test)]
#[path = "tests/files.rs"]
mod tests;

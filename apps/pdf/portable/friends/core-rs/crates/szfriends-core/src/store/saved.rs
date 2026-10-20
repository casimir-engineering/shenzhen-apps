//! Where a received file was saved, for its "Saved to {folder}" (PROTOCOL.md, a transfer's `status_label`), and where
//! the last one went when the folder it was meant for could not take it, for Settings' note.

use std::fs;
use std::path::Path;

use super::destination::PhoneFolder;
use super::{new_identifier, Store};

/// Where the last file went when the folder it was meant for could not take it (one word: `downloads` or `kept`),
/// beside [`super::RECEIVED_FOLDER_FILE`] so a restart keeps it, until a file is saved where meant or the folder changes.
pub const RECEIVED_FALLBACK_FILE: &str = "received-fallback";

/// Where the last received file went instead of the folder it was meant for (Settings' note says so).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReceivedFallback {
    /// The chosen folder could not take it; the default Downloads did.
    Downloads,
    /// No folder could; it is in the store's own `received/`, where its chat still opens it.
    Kept,
}

impl ReceivedFallback {
    fn word(self) -> &'static str {
        match self {
            Self::Downloads => "downloads",
            Self::Kept => "kept",
        }
    }
}

/// The folder a received file is in, for its "Saved to {folder}"; the store's own `received/` (older files, the last
/// resort) has none, and keeps "Received".
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SavedPlace {
    /// The default Downloads (Android's public Downloads too).
    Downloads,
    /// iOS: the app's Documents, which the Files app shows under the app's name.
    AppFiles,
    /// Another folder, by its name.
    Folder(String),
}

/// Remembers (or forgets, with `None`) where the last file went instead; written only when it changes.
pub(crate) fn record_fallback(state_dir: &Path, fallback: Option<ReceivedFallback>) {
    if read_fallback(state_dir) == fallback {
        return;
    }
    let file = state_dir.join(RECEIVED_FALLBACK_FILE);
    match fallback {
        None => {
            let _ = fs::remove_file(&file);
        }
        Some(fallback) => {
            // Beside it and renamed over it, so a crash leaves one word or the other.
            let temporary = state_dir.join(format!(".{RECEIVED_FALLBACK_FILE}.{}", new_identifier()));
            if fs::write(&temporary, fallback.word()).and_then(|()| fs::rename(&temporary, &file)).is_err() {
                let _ = fs::remove_file(&temporary);
            }
        }
    }
}

fn read_fallback(state_dir: &Path) -> Option<ReceivedFallback> {
    match fs::read_to_string(state_dir.join(RECEIVED_FALLBACK_FILE)).ok()?.trim() {
        "downloads" => Some(ReceivedFallback::Downloads),
        "kept" => Some(ReceivedFallback::Kept),
        _ => None,
    }
}

impl Store {
    /// Where the last received file went when the folder it was meant for could not take it; `None` once a file
    /// was saved there again or the folder changed.
    pub fn received_fallback(&self) -> Option<ReceivedFallback> {
        read_fallback(self.state_dir())
    }

    /// The folder a received file at `received_path` is in, for its "Saved to …"; `None` for the store's own
    /// `received/` (older files, the last resort), whose items keep "Received".
    pub fn saved_place(&self, received_path: &Path) -> Option<SavedPlace> {
        // A MediaStore content URI (Android 10 and later): the public Downloads.
        if !received_path.is_absolute() {
            return Some(SavedPlace::Downloads);
        }
        let parent = received_path.parent()?;
        let real = |p: &Path| fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf());
        let folder = real(parent);
        if folder == real(&self.state_dir().join("received")) {
            return None;
        }
        match self.received_defaults.phone {
            Some(PhoneFolder::Downloads) => return Some(SavedPlace::Downloads),
            Some(PhoneFolder::AppFiles) => return Some(SavedPlace::AppFiles),
            Some(PhoneFolder::App) => return None,
            None => {}
        }
        if self.received_defaults.folder.as_deref().map(real) == Some(folder) {
            return Some(SavedPlace::Downloads);
        }
        parent.file_name().map(|n| SavedPlace::Folder(n.to_string_lossy().into_owned()))
    }
}

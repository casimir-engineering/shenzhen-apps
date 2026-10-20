//! Room for a file about to come here (`SZFriendsTransfers freeBytesForReceiving`): Get and Get again answer
//! `disk_full` when the file is larger than the free space where it is staged (the state directory) and, on another
//! volume, where received files go. In a test home (`SZFRIENDS_STATE_DIR` set), a `test-free-bytes` file in it holding
//! a number stands in for both, so a test can fill the disk without filling it.

use std::path::{Path, PathBuf};

use super::State;
use crate::state::ENV_STATE_DIR;

/// In a test home: the free space this file says there is.
pub const TEST_FREE_BYTES_FILE: &str = "test-free-bytes";

#[cfg(unix)]
fn volume(path: &Path) -> Option<(u64, u64)> {
    let stats = rustix::fs::statvfs(path).ok()?;
    let device = rustix::fs::stat(path).ok()?.st_dev;
    Some((stats.f_bavail.saturating_mul(stats.f_frsize), device as u64))
}

#[cfg(not(unix))]
fn volume(_path: &Path) -> Option<(u64, u64)> {
    None // Windows: no check, as before
}

/// The nearest existing folder at or above `path`: a Downloads not made yet will be made there.
fn existing(path: &Path) -> Option<PathBuf> {
    path.ancestors().find(|p| p.exists()).map(Path::to_owned)
}

/// The free space for a file coming here, or `None` when the system cannot say (then nothing is refused).
pub fn free_for_receiving(state_dir: &Path, destination: Option<&Path>) -> Option<u64> {
    if std::env::var_os(ENV_STATE_DIR).is_some() {
        if let Ok(text) = std::fs::read_to_string(state_dir.join(TEST_FREE_BYTES_FILE)) {
            return text.trim().parse().ok();
        }
    }
    let (staging, staging_volume) = volume(state_dir)?;
    // Elsewhere the file needs room in both places, for the staging and the copy.
    match destination.and_then(existing).and_then(|d| volume(&d)) {
        Some((free, other)) if other != staging_volume => Some(staging.min(free)),
        _ => Some(staging),
    }
}

impl State {
    /// `disk_full` when `size` bytes do not fit where a file coming here goes.
    pub(crate) fn room_for(&self, size: u64) -> Result<(), &'static str> {
        let free = free_for_receiving(self.store.state_dir(), self.store.received_folder().as_deref());
        if free.is_some_and(|free| free < size) {
            return Err("disk_full");
        }
        Ok(())
    }
}

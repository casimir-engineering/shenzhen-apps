//! Removing a test's directory on every platform: Windows refuses while any file in it is still open (a database
//! just closed on another thread, a helper process just gone, the indexer or a scanner looking in), so removal is
//! tried again for a while, and a directory that outlasts that is reported rather than left behind silently.

use std::path::Path;
use std::time::Duration;

pub fn remove_tree(path: &Path) {
    for attempt in 0..100 {
        match std::fs::remove_dir_all(path) {
            Ok(()) => return,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
            Err(error) if attempt == 99 => eprintln!("could not remove {}: {error}", path.display()),
            Err(_) => std::thread::sleep(Duration::from_millis(100)),
        }
    }
}

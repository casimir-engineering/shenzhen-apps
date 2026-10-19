//! The helper's log, `<state dir>/helper.log`, as the Mac helper keeps it: the spawner gives the helper no stderr
//! (so it never holds an app's pipe open), the lock holder writes here, and the previous log moves aside past 1 MiB.
//! Never keys, secrets or message contents.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::Path;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

static LOG: Mutex<Option<File>> = Mutex::new(None);

const ROTATE_AT: u64 = 1024 * 1024;

/// Starts writing to `<state dir>/helper.log`. Until then, and if it cannot be opened, lines go to stderr.
pub fn open(state_dir: &Path) {
    let path = state_dir.join("helper.log");
    if std::fs::metadata(&path).is_ok_and(|m| m.len() > ROTATE_AT) {
        let _ = std::fs::rename(&path, state_dir.join("helper.log.1"));
    }
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32);
    }
    if let Ok(file) = options.open(path) {
        *LOG.lock().unwrap_or_else(|e| e.into_inner()) = Some(file);
    }
}

/// One line: seconds since 1970, the process id, the text.
pub fn write(args: std::fmt::Arguments<'_>) {
    let seconds = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
    let line = format!("{seconds} [{}] {args}\n", std::process::id());
    let mut log = LOG.lock().unwrap_or_else(|e| e.into_inner());
    match log.as_mut() {
        Some(file) => {
            let _ = file.write_all(line.as_bytes());
        }
        None => {
            let _ = std::io::stderr().write_all(line.as_bytes());
        }
    }
}

/// `log!("format", args…)`: a line in the helper's log.
#[macro_export]
macro_rules! log {
    ($($arg:tt)*) => { $crate::log::write(format_args!($($arg)*)) };
}

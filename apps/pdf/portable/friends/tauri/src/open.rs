//! Handing a checked URL or file to the system: the default browser or mail app, and the file manager with the
//! file selected. Arguments go straight to the program, never through a shell. Phones have neither here: their
//! received files are offered through the app (ADR 0015 § 10).

use std::path::Path;
use std::process::{Command, Stdio};

fn run(program: &str, arguments: &[&std::ffi::OsStr]) -> bool {
    let child =
        Command::new(program).args(arguments).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
    match child {
        Ok(mut child) => {
            // Reaped off the caller's thread; the opener returns quickly on every system.
            std::thread::spawn(move || child.wait());
            true
        }
        Err(_) => false,
    }
}

/// Opens an `http`, `https`, `mailto` or system-settings URL the bridge already checked.
pub fn open_url(url: &str) -> bool {
    let url = std::ffi::OsStr::new(url);
    if cfg!(target_os = "macos") {
        run("/usr/bin/open", &[url])
    } else if cfg!(windows) {
        // The URL protocol handler, without cmd.exe and its metacharacters.
        run("rundll32.exe", &[std::ffi::OsStr::new("url.dll,FileProtocolHandler"), url])
    } else if cfg!(target_os = "linux") {
        run("xdg-open", &[url])
    } else {
        false
    }
}

/// Shows `file` in the system's file manager.
pub fn reveal(file: &Path) -> bool {
    if cfg!(target_os = "macos") {
        run("/usr/bin/open", &[std::ffi::OsStr::new("-R"), file.as_os_str()])
    } else if cfg!(windows) {
        let mut select = std::ffi::OsString::from("/select,");
        select.push(file.as_os_str());
        run("explorer.exe", &[&select])
    } else if cfg!(target_os = "linux") {
        // The freedesktop file-manager interface selects the file where one runs; otherwise open its folder.
        show_items(file) || file.parent().is_some_and(|folder| run("xdg-open", &[folder.as_os_str()]))
    } else {
        false
    }
}

/// The file manager's Show Items over the helper's own D-Bus client, which sends each name whole (`dbus-send`
/// would split one at its commas).
#[cfg(target_os = "linux")]
fn show_items(file: &Path) -> bool {
    use szfriends_helper::linux::{dbus::Bus, file_manager};
    let Ok(uri) = tauri::Url::from_file_path(file) else { return false };
    let Ok(mut bus) = Bus::session() else { return false };
    let _ = bus.set_timeout(Some(std::time::Duration::from_secs(5)));
    file_manager::show_items(&mut bus, &[uri.to_string()]).is_ok()
}

#[cfg(not(target_os = "linux"))]
fn show_items(_file: &Path) -> bool {
    false
}

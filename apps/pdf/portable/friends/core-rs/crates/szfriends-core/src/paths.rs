//! Where Friends keeps its state on each platform (ADR 0015 § State and files). One directory per person on a
//! desktop, shared by every app that hosts Friends there; one per app on a phone, where apps cannot share files.

use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Platform {
    Linux,
    Windows,
    Android,
    Ios,
    /// The Objective-C helper owns the state directory on a Mac; the Rust core never runs there as a helper.
    MacOs,
}

impl Platform {
    pub fn current() -> Self {
        if cfg!(target_os = "windows") {
            Self::Windows
        } else if cfg!(target_os = "android") {
            Self::Android
        } else if cfg!(target_os = "ios") {
            Self::Ios
        } else if cfg!(target_os = "macos") {
            Self::MacOs
        } else {
            Self::Linux
        }
    }
}

/// The state directory, from the environment `env` reads (injected for tests) and, on a phone, the app's private
/// directory the host passes in (`Context.getNoBackupFilesDir()` on Android; Application Support on iOS, where the
/// plugin marks the directory excluded from backups: ADR 0015 § Backups). `None` on a Mac, and when the variable a
/// desktop needs is missing or not absolute.
pub fn state_dir(
    platform: Platform,
    env: impl Fn(&str) -> Option<String>,
    app_private: Option<PathBuf>,
) -> Option<PathBuf> {
    let absolute = |value: Option<String>| value.map(PathBuf::from).filter(|p| p.is_absolute());
    match platform {
        Platform::Linux => absolute(env("XDG_DATA_HOME"))
            .or_else(|| absolute(env("HOME")).map(|home| home.join(".local/share")))
            .map(|base| base.join("shenzhen-friends")),
        Platform::Windows => absolute(env("LOCALAPPDATA")).map(|base| base.join("Shenzhen Friends")),
        Platform::Android | Platform::Ios => app_private.map(|base| base.join("Shenzhen Friends")),
        Platform::MacOs => None,
    }
}

/// The person's Downloads folder, where received files go until they choose another (PROTOCOL.md § Views,
/// `settings`): Linux `XDG_DOWNLOAD_DIR` from `user-dirs.dirs` (`read` reads it; injected for tests), else
/// `~/Downloads`; a Mac `~/Downloads`; Windows `%USERPROFILE%\Downloads`, for when the Downloads known folder
/// cannot be read; iOS the app's Documents (`$HOME/Documents`, shown in the Files app). `None` on Android, whose
/// public Downloads only MediaStore reaches, and when the environment names no home.
pub fn downloads_dir(
    platform: Platform,
    env: impl Fn(&str) -> Option<String>,
    read: impl Fn(&Path) -> Option<String>,
) -> Option<PathBuf> {
    let absolute = |value: Option<String>| value.map(PathBuf::from).filter(|p| p.is_absolute());
    match platform {
        Platform::Linux => {
            let home = absolute(env("HOME"))?;
            let config = absolute(env("XDG_CONFIG_HOME")).unwrap_or_else(|| home.join(".config"));
            let chosen = read(&config.join("user-dirs.dirs")).and_then(|text| xdg_download_dir(&text, &home));
            Some(chosen.unwrap_or_else(|| home.join("Downloads")))
        }
        Platform::MacOs => absolute(env("HOME")).map(|home| home.join("Downloads")),
        Platform::Windows => absolute(env("USERPROFILE")).map(|home| home.join("Downloads")),
        Platform::Ios => absolute(env("HOME")).map(|home| home.join("Documents")),
        Platform::Android => None,
    }
}

/// `XDG_DOWNLOAD_DIR="$HOME/…"` (or an absolute path) from `user-dirs.dirs`; `None` when absent, or set to the
/// home itself, which the specification reads as "no Downloads folder".
fn xdg_download_dir(text: &str, home: &Path) -> Option<PathBuf> {
    let line = text.lines().map(str::trim).find(|l| l.starts_with("XDG_DOWNLOAD_DIR="))?;
    let value = line["XDG_DOWNLOAD_DIR=".len()..].trim().trim_matches('"');
    let path = if let Some(rest) = value.strip_prefix("$HOME") {
        let rest = rest.trim_start_matches('/');
        if rest.is_empty() {
            return None;
        }
        home.join(rest)
    } else {
        PathBuf::from(value)
    };
    (path.is_absolute() && path != home).then_some(path)
}

/// Where a desktop app puts its copy of the helper before spawning it (ADR 0015 § Desktop packaging):
/// `<state dir>/helper/<version>-<build>-<first 16 hex of the binary's SHA-256>/`. The helper never runs from the
/// app's own files: a Windows installer cannot replace an executable that is running, and an AppImage's mount
/// disappears when the app that mounted it quits. One directory per distinct binary, so a copy is written once and
/// never replaced while it may be running. `None` for a malformed version, build or digest.
pub fn helper_copy_dir(state_dir: &Path, version: &str, build: u32, digest: &str) -> Option<PathBuf> {
    let name = format!("{version}-{build}-{}", digest.get(..16)?);
    parse_copy_name(&name).map(|_| state_dir.join("helper").join(name))
}

/// The helper's file name inside its copy directory.
pub fn helper_executable(platform: Platform) -> &'static str {
    if platform == Platform::Windows {
        "szfriends-helper.exe"
    } else {
        "szfriends-helper"
    }
}

/// `(version parts, build)` of a copy directory's name, or `None` when the name is not one [`helper_copy_dir`] makes.
fn parse_copy_name(name: &str) -> Option<(Vec<u32>, u32)> {
    let mut parts = name.rsplitn(3, '-');
    let (digest, build, version) = (parts.next()?, parts.next()?, parts.next()?);
    let digest_ok = digest.len() == 16 && digest.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
    let digits = |s: &str| !s.is_empty() && s.len() <= 9 && s.bytes().all(|b| b.is_ascii_digit());
    if !digest_ok || !digits(build) || !version.split('.').all(digits) {
        return None;
    }
    Some((version.split('.').map(|p| p.parse().ok()).collect::<Option<_>>()?, build.parse().ok()?))
}

/// The copy directories a running helper (the lock holder, `current`) removes: those older than its own version and
/// build. Newer ones may belong to a helper about to take over; unknown names are left alone. On Windows a copy that
/// is still running cannot be deleted, which is fine: the next start tries again.
pub fn stale_helper_copies<'a>(names: &'a [String], current: &str) -> Vec<&'a str> {
    let Some(mine) = parse_copy_name(current) else { return Vec::new() };
    names.iter().map(String::as_str).filter(|name| parse_copy_name(name).is_some_and(|theirs| theirs < mine)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<String> {
        move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
    }

    // Each desktop's rule needs that desktop's idea of an absolute path, so each runs on its own kind of host.
    #[cfg(windows)]
    #[test]
    fn windows_location() {
        let local = state_dir(Platform::Windows, env(&[("LOCALAPPDATA", r"C:\Users\mei\AppData\Local")]), None);
        assert_eq!(local, Some(PathBuf::from(r"C:\Users\mei\AppData\Local\Shenzhen Friends")));
        assert_eq!(state_dir(Platform::Windows, env(&[("LOCALAPPDATA", r"AppData\Local")]), None), None);
        assert_eq!(state_dir(Platform::Windows, env(&[]), None), None);
    }

    #[cfg(unix)]
    #[test]
    fn downloads_folders() {
        let none = |_: &Path| None;
        let home = env(&[("HOME", "/home/mei")]);
        assert_eq!(downloads_dir(Platform::Linux, &home, none), Some(PathBuf::from("/home/mei/Downloads")));
        let dirs = |text: &'static str| {
            move |path: &Path| (path == Path::new("/home/mei/.config/user-dirs.dirs")).then(|| text.to_owned())
        };
        let french = "# comment\nXDG_DESKTOP_DIR=\"$HOME/Bureau\"\nXDG_DOWNLOAD_DIR=\"$HOME/Téléchargements\"\n";
        assert_eq!(
            downloads_dir(Platform::Linux, &home, dirs(french)),
            Some(PathBuf::from("/home/mei/Téléchargements"))
        );
        let elsewhere = "XDG_DOWNLOAD_DIR=\"/data/downloads\"";
        assert_eq!(downloads_dir(Platform::Linux, &home, dirs(elsewhere)), Some(PathBuf::from("/data/downloads")));
        let disabled = "XDG_DOWNLOAD_DIR=\"$HOME/\"";
        assert_eq!(downloads_dir(Platform::Linux, &home, dirs(disabled)), Some(PathBuf::from("/home/mei/Downloads")));
        assert_eq!(downloads_dir(Platform::Linux, env(&[]), none), None);
        assert_eq!(
            downloads_dir(Platform::MacOs, env(&[("HOME", "/Users/mei")]), none),
            Some(PathBuf::from("/Users/mei/Downloads"))
        );
        let ios = downloads_dir(Platform::Ios, env(&[("HOME", "/var/mobile/Containers/Data/Application/X")]), none);
        assert_eq!(ios, Some(PathBuf::from("/var/mobile/Containers/Data/Application/X/Documents")));
        assert_eq!(downloads_dir(Platform::Android, &home, none), None);
    }

    #[test]
    fn mobile_and_mac_locations() {
        let phone = state_dir(Platform::Android, env(&[]), Some(PathBuf::from("/data/user/0/app/no_backup")));
        assert_eq!(phone, Some(PathBuf::from("/data/user/0/app/no_backup/Shenzhen Friends")));
        assert_eq!(state_dir(Platform::Android, env(&[]), None), None);
        assert_eq!(state_dir(Platform::MacOs, env(&[("HOME", "/Users/mei")]), None), None);
    }

    #[cfg(unix)]
    #[test]
    fn linux_location() {
        let linux = state_dir(Platform::Linux, env(&[("HOME", "/home/mei")]), None);
        assert_eq!(linux, Some(PathBuf::from("/home/mei/.local/share/shenzhen-friends")));
        let xdg = state_dir(Platform::Linux, env(&[("XDG_DATA_HOME", "/data"), ("HOME", "/home/mei")]), None);
        assert_eq!(xdg, Some(PathBuf::from("/data/shenzhen-friends")));
        assert_eq!(state_dir(Platform::Linux, env(&[("XDG_DATA_HOME", "relative")]), None), None);
    }

    #[test]
    fn helper_copies_are_versioned_and_pruned_oldest_first() {
        let digest = "0123456789abcdef0123456789abcdef";
        let dir = helper_copy_dir(Path::new("/state"), "1.2.0", 345, digest);
        assert_eq!(dir, Some(PathBuf::from("/state/helper/1.2.0-345-0123456789abcdef")));
        assert_eq!(helper_copy_dir(Path::new("/s"), "1.2.0", 1, "0123"), None, "short digest");
        assert_eq!(helper_copy_dir(Path::new("/s"), "1..0", 1, digest), None, "empty version part");
        assert_eq!(helper_copy_dir(Path::new("/s"), "../x", 1, digest), None, "a path");
        assert_eq!(helper_executable(Platform::Windows), "szfriends-helper.exe");
        let names: Vec<String> = [
            "1.2.0-345-0123456789abcdef",
            "1.2.0-344-ffffffffffffffff",
            "1.10.0-1-0000000000000000",
            "1.9.9-999-0000000000000000",
            "0.9.0-1-zzzzzzzzzzzzzzzz",
            "notes",
        ]
        .map(String::from)
        .to_vec();
        let stale = stale_helper_copies(&names, "1.10.0-1-0000000000000000");
        assert_eq!(stale, ["1.2.0-345-0123456789abcdef", "1.2.0-344-ffffffffffffffff", "1.9.9-999-0000000000000000"]);
        assert_eq!(stale_helper_copies(&names, "1.2.0-345-0123456789abcdef"), ["1.2.0-344-ffffffffffffffff"]);
        assert!(stale_helper_copies(&names, "garbage").is_empty());
    }
}

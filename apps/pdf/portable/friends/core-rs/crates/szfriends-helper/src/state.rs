//! The state directory the helper and its clients share (PROTOCOL.md § Transport): where it is, its canonical form
//! (what socket and pipe names derive from), and creating it for the user alone.

use std::io;
use std::path::{Component, Path, PathBuf};

use szfriends_core::paths::{state_dir, Platform};

/// An absolute path here replaces the platform's state directory (tests, probes, two helpers side by side).
pub const ENV_STATE_DIR: &str = "SZFRIENDS_STATE_DIR";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StateDir {
    pub path: PathBuf,
    /// The form every name is derived from, so a client that starts before the directory exists agrees with the
    /// helper that creates it.
    pub canonical: String,
}

impl StateDir {
    /// `$SZFRIENDS_STATE_DIR` when absolute, else the platform's directory (`None` on a Mac and when the
    /// environment names none).
    pub fn from_environment() -> Option<Self> {
        let env = |key: &str| std::env::var(key).ok();
        let chosen = env(ENV_STATE_DIR)
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .or_else(|| state_dir(Platform::current(), env, None))?;
        Some(Self::new(chosen))
    }

    /// The person's own Friends home on this platform, whatever `$SZFRIENDS_STATE_DIR` says (`None` on a Mac and
    /// when the environment names no home). What an app's release build uses.
    pub fn platform() -> Option<Self> {
        state_dir(Platform::current(), |key| std::env::var(key).ok(), None).map(Self::new)
    }

    /// Whether this is the person's own home rather than a test or development one.
    pub fn is_platform_default(&self) -> bool {
        Self::platform().is_some_and(|own| own.canonical == self.canonical)
    }

    pub fn new(path: PathBuf) -> Self {
        let canonical = canonical_form(&path);
        Self { path, canonical }
    }

    /// Creates the directory (0700 on Unix) and checks it is the user's own and not a link.
    pub fn prepare(&self) -> io::Result<()> {
        create_private_dir(&self.path)
    }
}

/// Creates `path` and its missing parents (each new one 0700 on Unix), then refuses it unless it is a directory of
/// ours that no one else may enter.
pub fn create_private_dir(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(path)?;
        let metadata = std::fs::symlink_metadata(path)?;
        let ours = metadata.uid() == rustix::process::geteuid().as_raw();
        if !metadata.is_dir() || !ours || metadata.permissions().mode() & 0o077 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!("unsafe directory {}", path.display()),
            ));
        }
        Ok(())
    }
    #[cfg(not(unix))]
    {
        std::fs::create_dir_all(path)?;
        let metadata = std::fs::symlink_metadata(path)?;
        if !metadata.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!("not a directory: {}", path.display()),
            ));
        }
        Ok(())
    }
}

/// The deepest existing ancestor resolved (links followed), then the components that do not exist yet. On Windows
/// the path as given, without the `\\?\` prefix resolution would add, since pipe names hash this text.
pub fn canonical_form(path: &Path) -> String {
    if cfg!(windows) {
        return path.to_string_lossy().into_owned();
    }
    let mut missing: Vec<&std::ffi::OsStr> = Vec::new();
    let mut existing = path;
    loop {
        if let Ok(resolved) = std::fs::canonicalize(existing) {
            let mut full = resolved;
            for part in missing.iter().rev() {
                full.push(part);
            }
            return full.to_string_lossy().into_owned();
        }
        match (existing.parent(), existing.components().next_back()) {
            (Some(parent), Some(Component::Normal(name))) => {
                missing.push(name);
                existing = parent;
            }
            _ => return path.to_string_lossy().into_owned(),
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn the_canonical_form_resolves_what_exists_and_keeps_the_rest() {
        let base = std::env::temp_dir().join(format!("szf-state-{}", std::process::id()));
        std::fs::create_dir_all(&base).unwrap();
        let resolved = std::fs::canonicalize(&base).unwrap();
        let state = base.join("not").join("yet");
        assert_eq!(canonical_form(&state), resolved.join("not/yet").to_string_lossy());
        let dir = StateDir::new(state.clone());
        dir.prepare().unwrap();
        assert_eq!(canonical_form(&state), dir.canonical, "the same before and after it exists");
        std::fs::remove_dir_all(&base).unwrap();
    }

    /// A test home is never the person's own, so a spawned helper is told about it; the person's own home is the
    /// platform's, whatever `$SZFRIENDS_STATE_DIR` says.
    #[test]
    fn only_the_platform_home_is_the_persons_own() {
        let test_home = StateDir::new(std::env::temp_dir().join("szf-not-the-persons-home"));
        assert!(!test_home.is_platform_default());
        if let Some(own) = StateDir::platform() {
            assert!(StateDir::new(own.path.clone()).is_platform_default());
            assert!(own.path.ends_with("shenzhen-friends") || own.path.ends_with("Shenzhen Friends"));
        }
    }
}

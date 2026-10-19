//! Where the identity secret lives, and the rule that keeps an unreadable key from being replaced.
//!
//! Each platform supplies a [`KeyStore`] (ADR 0015 § Key storage): the iOS Keychain, an Android Keystore-wrapped
//! file, DPAPI on Windows, the Secret Service on Linux. This module holds what is common: the trait, the
//! [`IdentityManager`] that loads or creates the identity exactly as the helper does, a [`MemoryKeyStore`] for tests,
//! and on Unix a [`FileKeyStore`] (0600 files in a 0700 directory) for tests, harnesses and Linux without a Secret
//! Service.

use std::collections::HashMap;
use std::sync::Mutex;

use zeroize::Zeroizing;

use crate::identity::{Identity, IdentityError};

/// The one key-store item holding both identity keys.
pub const IDENTITY_SECRET_NAME: &str = "identity";

/// Names are 1 to 64 characters of `A-Z a-z 0-9 . _ -`, not starting with '.', so a name can never be a path.
pub fn name_is_valid(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && !name.starts_with('.')
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

pub trait KeyStore: Send + Sync {
    /// `Ok(None)` when no secret exists under `name`; `Err(Unavailable)` when one exists but cannot be read. The
    /// distinction is what keeps an unreadable key from being replaced. Reads never prompt.
    fn secret(&self, name: &str) -> Result<Option<Zeroizing<Vec<u8>>>, IdentityError>;
    /// Creates the secret and never replaces one: an existing `name` fails with `StoreFailed`, so not even a caller
    /// that misread "absent" can overwrite an identity. Replacing is delete, then store (Reset Friends).
    fn store(&self, name: &str, secret: &[u8]) -> Result<(), IdentityError>;
    /// Succeeds when the secret is gone afterwards, including when there was none.
    fn delete(&self, name: &str) -> Result<(), IdentityError>;
}

/// What the Friends store (friends.sqlite) says about the identity it was made for. The store records the identity's
/// public key when it is created, so a key and a store that do not belong together are never used together.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StoreIdentity {
    /// No store yet: a first start, or one after Start again.
    NoStore,
    /// The store exists and was made for this identity key.
    Recorded([u8; 32]),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IdentityState {
    /// Loaded an existing identity.
    Ready,
    /// First start: a new identity was generated, stored and read back.
    Created,
}

#[derive(Debug)]
pub struct IdentityManager<K: KeyStore> {
    store: K,
}

impl<K: KeyStore> IdentityManager<K> {
    pub fn new(store: K) -> Self {
        Self { store }
    }

    /// Loads the identity for the store, creating one only when neither a secret nor a store exists. Unavailable
    /// when a secret exists but cannot be read, Corrupt when it cannot be parsed, StoreFailed when a new one could not
    /// be stored and read back (a key that will not survive a restart would be a key change tomorrow), KeyMissing
    /// when the store exists without its key (restored from a backup the key was not in), StoreMismatch when key and
    /// store belong to different identities. The last two are distinct states the views explain; neither creates
    /// anything.
    pub fn load_or_create(&self, store: StoreIdentity) -> Result<(Identity, IdentityState), IdentityError> {
        match (self.store.secret(IDENTITY_SECRET_NAME)?, store) {
            (Some(item), store) => {
                let identity = Identity::from_secret_item(&item)?;
                match store {
                    StoreIdentity::Recorded(key) if key != identity.public_key() => Err(IdentityError::StoreMismatch),
                    _ => Ok((identity, IdentityState::Ready)),
                }
            }
            (None, StoreIdentity::Recorded(_)) => Err(IdentityError::KeyMissing),
            (None, StoreIdentity::NoStore) => Ok((self.create()?, IdentityState::Created)),
        }
    }

    /// Explicit reset: deletes the old secret and creates a new identity. Only the person's Reset Friends (Start
    /// again) calls it, after the caller has removed the store, which belonged to the old identity.
    pub fn reset(&self) -> Result<Identity, IdentityError> {
        self.store.delete(IDENTITY_SECRET_NAME)?;
        self.create()
    }

    fn create(&self) -> Result<Identity, IdentityError> {
        let identity = Identity::generate();
        let item = identity.secret_item();
        self.store.store(IDENTITY_SECRET_NAME, &item)?;
        // Read it back before anyone sees the new key.
        match self.store.secret(IDENTITY_SECRET_NAME) {
            Ok(Some(read)) if read.as_slice() == item.as_slice() => Ok(identity),
            _ => Err(IdentityError::StoreFailed),
        }
    }
}

/// In memory, with failure injection, for tests.
#[derive(Debug, Default)]
pub struct MemoryKeyStore {
    items: Mutex<HashMap<String, Zeroizing<Vec<u8>>>>,
    /// Reads of an existing item fail as Unavailable (a locked keychain).
    pub locked: std::sync::atomic::AtomicBool,
}

impl KeyStore for MemoryKeyStore {
    fn secret(&self, name: &str) -> Result<Option<Zeroizing<Vec<u8>>>, IdentityError> {
        let items = self.items.lock().map_err(|_| IdentityError::Unavailable)?;
        match items.get(name) {
            Some(_) if self.locked.load(std::sync::atomic::Ordering::SeqCst) => Err(IdentityError::Unavailable),
            Some(item) => Ok(Some(item.clone())),
            None => Ok(None),
        }
    }

    fn store(&self, name: &str, secret: &[u8]) -> Result<(), IdentityError> {
        let mut items = self.items.lock().map_err(|_| IdentityError::StoreFailed)?;
        if !name_is_valid(name) || items.contains_key(name) {
            return Err(IdentityError::StoreFailed);
        }
        items.insert(name.to_owned(), Zeroizing::new(secret.to_vec()));
        Ok(())
    }

    fn delete(&self, name: &str) -> Result<(), IdentityError> {
        self.items.lock().map_err(|_| IdentityError::StoreFailed)?.remove(name);
        Ok(())
    }
}

#[cfg(unix)]
pub use file::FileKeyStore;

#[cfg(unix)]
mod file {
    use std::fs::{self, OpenOptions};
    use std::io::{ErrorKind, Read, Write};
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
    use std::path::{Path, PathBuf};

    use zeroize::Zeroizing;

    use super::{name_is_valid, KeyStore};
    use crate::identity::IdentityError;

    /// A 0600 file per name in a 0700 directory. A file that is a symbolic link, not ours, or readable by group or
    /// others is reported unavailable, never used and never replaced. An empty file is no secret: it is what a store
    /// interrupted between claiming the name and moving the secret in leaves (see `publish`).
    #[derive(Debug)]
    pub struct FileKeyStore {
        directory: PathBuf,
    }

    impl FileKeyStore {
        pub fn new(directory: impl Into<PathBuf>) -> Self {
            Self { directory: directory.into() }
        }

        fn path(&self, name: &str) -> Option<PathBuf> {
            name_is_valid(name).then(|| self.directory.join(name))
        }
    }

    fn no_follow() -> i32 {
        rustix::fs::OFlags::NOFOLLOW.bits() as i32
    }

    fn ours(metadata: &fs::Metadata) -> bool {
        metadata.is_file() && metadata.uid() == rustix::process::geteuid().as_raw() && metadata.mode() & 0o077 == 0
    }

    /// `temporary` to `path`, never replacing what is there: a hard link fails when `path` exists. Where the system
    /// refuses hard links with a permission error (Android's SELinux policy gives apps none), `path` is claimed with
    /// an exclusive create and `temporary` renamed over the claim, which fails just the same when `path` exists.
    fn publish(temporary: &Path, path: &Path) -> std::io::Result<()> {
        match fs::hard_link(temporary, path) {
            Err(e) if e.kind() == ErrorKind::PermissionDenied => {}
            other => return other,
        }
        OpenOptions::new().write(true).create_new(true).mode(0o600).custom_flags(no_follow()).open(path)?;
        fs::rename(temporary, path)
    }

    fn sync_directory(directory: &Path) {
        if let Ok(handle) = fs::File::open(directory) {
            let _ = handle.sync_all();
        }
    }

    impl KeyStore for FileKeyStore {
        fn secret(&self, name: &str) -> Result<Option<Zeroizing<Vec<u8>>>, IdentityError> {
            let path = self.path(name).ok_or(IdentityError::Unavailable)?;
            let mut file = match OpenOptions::new().read(true).custom_flags(no_follow()).open(&path) {
                Ok(file) => file,
                Err(e) if e.kind() == ErrorKind::NotFound => return Ok(None),
                Err(_) => return Err(IdentityError::Unavailable),
            };
            let metadata = file.metadata().map_err(|_| IdentityError::Unavailable)?;
            if !ours(&metadata) || metadata.len() > 4096 {
                return Err(IdentityError::Unavailable);
            }
            if metadata.len() == 0 {
                return Ok(None);
            }
            let mut contents = Zeroizing::new(Vec::with_capacity(metadata.len() as usize));
            file.read_to_end(&mut contents).map_err(|_| IdentityError::Unavailable)?;
            Ok(Some(contents))
        }

        fn store(&self, name: &str, secret: &[u8]) -> Result<(), IdentityError> {
            let path = self.path(name).ok_or(IdentityError::StoreFailed)?;
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(&self.directory)
                .map_err(|_| IdentityError::StoreFailed)?;
            let directory = fs::symlink_metadata(&self.directory).map_err(|_| IdentityError::StoreFailed)?;
            if !directory.is_dir() || directory.permissions().mode() & 0o077 != 0 {
                return Err(IdentityError::StoreFailed);
            }
            // The empty claim of a store that was interrupted holds nothing: taken back, as `secret` reads it absent.
            if fs::symlink_metadata(&path).is_ok_and(|m| ours(&m) && m.len() == 0) {
                let _ = fs::remove_file(&path);
            }
            let mut random = [0u8; 8];
            szfriends_crypto::random_bytes(&mut random);
            let suffix: String = random.iter().map(|b| format!("{b:02x}")).collect();
            let temporary = self.directory.join(format!(".{name}.{suffix}.tmp"));
            let written = (|| {
                let mut file = OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .custom_flags(no_follow())
                    .open(&temporary)?;
                file.write_all(secret)?;
                file.sync_all()?;
                publish(&temporary, &path)
            })();
            let _ = fs::remove_file(&temporary);
            sync_directory(&self.directory);
            written.map_err(|_| IdentityError::StoreFailed)
        }

        fn delete(&self, name: &str) -> Result<(), IdentityError> {
            let path = self.path(name).ok_or(IdentityError::StoreFailed)?;
            match fs::remove_file(path) {
                Ok(()) => {
                    sync_directory(&self.directory);
                    Ok(())
                }
                Err(e) if e.kind() == ErrorKind::NotFound => Ok(()),
                Err(_) => Err(IdentityError::StoreFailed),
            }
        }
    }
}

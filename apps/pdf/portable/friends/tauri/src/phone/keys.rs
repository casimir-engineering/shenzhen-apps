//! The phones' key stores (ADR 0015 § 7, § 17), behind `szfriends-identity`'s [`KeyStore`] rules: a secret that
//! exists but cannot be read is unavailable, never absent, and nothing replaces an existing secret.
//!
//! - Android: [`SealedFileKeyStore`], one file per secret in the app's no-backup directory, sealed with an AES-GCM key
//!   that the Android Keystore holds and never exports. A file whose Keystore key is gone (a file copied from another
//!   device, or restored) can never be opened again: it reads as absent, so a store beside it is `KeyMissing` and the
//!   views offer Start again.
//! - iOS: [`KeychainKeyStore`], a generic-password item per secret, readable after the first unlock and on this
//!   device only (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), never synchronised, so neither a backup nor a
//!   new iPhone carries it.
//!
//! The platform calls are the app's own plugin code (`android/`, `ios/`), reached through the traits here, so the
//! rules are tested on any computer.

// Each phone uses one of the two stores; both are tested everywhere.
#![cfg_attr(any(target_os = "android", target_os = "ios"), allow(dead_code))]

use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::PathBuf;
use std::sync::Arc;

use szfriends_identity::keystore::{name_is_valid, KeyStore};
use szfriends_identity::IdentityError;
use zeroize::Zeroizing;

/// What a sealed secret's Keystore key says when asked to open it.
#[derive(Debug, PartialEq, Eq)]
pub enum Unsealed {
    Secret(Zeroizing<Vec<u8>>),
    /// The Keystore holds no key under this alias: the file can never be opened.
    KeyGone,
}

/// The Android Keystore, as the plugin's Kotlin side offers it.
pub trait Sealer: Send + Sync {
    /// Seals `secret` with the key under `alias`, creating the key on first use.
    fn seal(&self, alias: &str, secret: &[u8]) -> Result<Vec<u8>, String>;
    /// Opens what [`seal`](Self::seal) returned; an error when the key exists but refuses (a corrupted file).
    fn unseal(&self, alias: &str, sealed: &[u8]) -> Result<Unsealed, String>;
    /// Deletes the key under `alias`; fine when there is none.
    fn forget(&self, alias: &str) -> Result<(), String>;
}

/// Files sealed by the Android Keystore, in a 0700 directory of the no-backup area.
#[derive(Clone)]
pub struct SealedFileKeyStore {
    directory: PathBuf,
    sealer: Arc<dyn Sealer>,
}

impl std::fmt::Debug for SealedFileKeyStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SealedFileKeyStore").field("directory", &self.directory).finish()
    }
}

/// The Keystore alias of a secret: one per name, prefixed so it never meets the app's own keys.
pub fn alias(name: &str) -> String {
    format!("szfriends.{name}")
}

impl SealedFileKeyStore {
    pub fn new(directory: impl Into<PathBuf>, sealer: Arc<dyn Sealer>) -> Self {
        Self { directory: directory.into(), sealer }
    }

    fn path(&self, name: &str) -> Option<PathBuf> {
        name_is_valid(name).then(|| self.directory.join(format!("{name}.sealed")))
    }
}

impl KeyStore for SealedFileKeyStore {
    fn secret(&self, name: &str) -> Result<Option<Zeroizing<Vec<u8>>>, IdentityError> {
        let path = self.path(name).ok_or(IdentityError::Unavailable)?;
        let sealed = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(IdentityError::Unavailable),
        };
        if sealed.is_empty() {
            return Ok(None);
        }
        match self.sealer.unseal(&alias(name), &sealed) {
            Ok(Unsealed::Secret(secret)) => Ok(Some(secret)),
            Ok(Unsealed::KeyGone) => Ok(None),
            Err(_) => Err(IdentityError::Unavailable),
        }
    }

    fn store(&self, name: &str, secret: &[u8]) -> Result<(), IdentityError> {
        let path = self.path(name).ok_or(IdentityError::StoreFailed)?;
        private_directory(&self.directory).map_err(|_| IdentityError::StoreFailed)?;
        // A file left by a key that is gone holds nothing anyone can open: taken back, as `secret` reads it absent.
        if fs::metadata(&path).is_ok() {
            if self.secret(name)?.is_some() {
                return Err(IdentityError::StoreFailed);
            }
            fs::remove_file(&path).map_err(|_| IdentityError::StoreFailed)?;
        }
        let sealed = self.sealer.seal(&alias(name), secret).map_err(|_| IdentityError::StoreFailed)?;
        let temporary = self.directory.join(format!(".{name}.sealed.tmp"));
        let _ = fs::remove_file(&temporary);
        let written = (|| {
            let mut file = OpenOptions::new().write(true).create_new(true).open(&temporary)?;
            file.write_all(&sealed)?;
            file.sync_all()?;
            // Never over an existing file: claim the name, then move the sealed bytes in.
            OpenOptions::new().write(true).create_new(true).open(&path)?;
            fs::rename(&temporary, &path)
        })();
        let _ = fs::remove_file(&temporary);
        written.map_err(|_| IdentityError::StoreFailed)
    }

    fn delete(&self, name: &str) -> Result<(), IdentityError> {
        let path = self.path(name).ok_or(IdentityError::StoreFailed)?;
        match fs::remove_file(path) {
            Ok(()) => {}
            Err(e) if e.kind() == ErrorKind::NotFound => {}
            Err(_) => return Err(IdentityError::StoreFailed),
        }
        self.sealer.forget(&alias(name)).map_err(|_| IdentityError::StoreFailed)
    }
}

/// The iOS Keychain, as the plugin's Swift side offers it.
pub trait Keychain: Send + Sync {
    /// `Ok(None)` for errSecItemNotFound; an error for any other failure (errSecInteractionNotAllowed while the
    /// device has not been unlocked since it started, for one).
    fn read(&self, account: &str) -> Result<Option<Zeroizing<Vec<u8>>>, String>;
    /// Adds the item; an error when it exists (errSecDuplicateItem) or cannot be added.
    fn add(&self, account: &str, secret: &[u8]) -> Result<(), String>;
    /// Deletes the item; fine when there is none.
    fn delete(&self, account: &str) -> Result<(), String>;
}

/// Keychain items, this device only.
#[derive(Clone)]
pub struct KeychainKeyStore {
    keychain: Arc<dyn Keychain>,
}

impl std::fmt::Debug for KeychainKeyStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("KeychainKeyStore")
    }
}

impl KeychainKeyStore {
    pub fn new(keychain: Arc<dyn Keychain>) -> Self {
        Self { keychain }
    }
}

impl KeyStore for KeychainKeyStore {
    fn secret(&self, name: &str) -> Result<Option<Zeroizing<Vec<u8>>>, IdentityError> {
        if !name_is_valid(name) {
            return Err(IdentityError::Unavailable);
        }
        match self.keychain.read(&alias(name)) {
            Ok(Some(secret)) if !secret.is_empty() => Ok(Some(secret)),
            Ok(_) => Ok(None),
            Err(_) => Err(IdentityError::Unavailable),
        }
    }

    fn store(&self, name: &str, secret: &[u8]) -> Result<(), IdentityError> {
        if !name_is_valid(name) {
            return Err(IdentityError::StoreFailed);
        }
        self.keychain.add(&alias(name), secret).map_err(|_| IdentityError::StoreFailed)
    }

    fn delete(&self, name: &str) -> Result<(), IdentityError> {
        if !name_is_valid(name) {
            return Err(IdentityError::StoreFailed);
        }
        self.keychain.delete(&alias(name)).map_err(|_| IdentityError::StoreFailed)
    }
}

/// Makes `directory` (and its parents) and keeps it to the app's user on Unix.
pub fn private_directory(directory: &std::path::Path) -> std::io::Result<()> {
    fs::create_dir_all(directory)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(directory, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Hex for the plugin's native calls, which carry secrets as text.
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn unhex(text: &str) -> Option<Zeroizing<Vec<u8>>> {
    if text.len() % 2 != 0 {
        return None;
    }
    let mut out = Zeroizing::new(Vec::with_capacity(text.len() / 2));
    for i in (0..text.len()).step_by(2) {
        out.push(u8::from_str_radix(text.get(i..i + 2)?, 16).ok()?);
    }
    Some(out)
}

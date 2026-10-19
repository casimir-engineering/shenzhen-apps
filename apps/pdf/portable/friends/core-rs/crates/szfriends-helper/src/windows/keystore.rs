//! The Windows key store (ADR 0015 § 7): one DPAPI-protected file per name under `<state dir>\keys`
//! (`%LOCALAPPDATA%\Shenzhen Friends\keys`, never roamed), not Credential Manager, whose entries roam with roaming
//! profiles. A file that exists but does not open (restored onto another account or PC, damaged) is unavailable,
//! never absent, and never replaced; an empty file is the claim of a store that was interrupted and holds nothing.

use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::path::{Path, PathBuf};

use szfriends_helper_sys::dpapi;
use szfriends_identity::keystore::{name_is_valid, KeyStore};
use szfriends_identity::IdentityError;
use zeroize::Zeroizing;

const ENTROPY: &[u8] = b"Shenzhen Friends key store 1\0";
const FILE_MAX: u64 = 64 * 1024;
/// Stored inside the protected blob; Windows shows it only to tools that list DPAPI blobs.
const DESCRIPTION: &str = "Shenzhen Friends identity";

#[derive(Debug)]
pub struct DpapiKeyStore {
    directory: PathBuf,
}

impl DpapiKeyStore {
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        Self { directory: directory.into() }
    }

    fn path(&self, name: &str) -> Option<PathBuf> {
        name_is_valid(name).then(|| self.directory.join(format!("{name}.dpapi")))
    }
}

/// Binds a blob to its name, so one name's file copied over another's does not open.
fn entropy(name: &str) -> Vec<u8> {
    [ENTROPY, name.as_bytes()].concat()
}

/// `temporary` to `path`, never replacing what is there: a hard link fails when `path` exists. Where the volume has
/// no hard links, `path` is claimed with an exclusive create and `temporary` renamed over the empty claim.
fn publish(temporary: &Path, path: &Path) -> std::io::Result<()> {
    match fs::hard_link(temporary, path) {
        Err(e) if e.kind() != ErrorKind::AlreadyExists => {}
        other => return other,
    }
    OpenOptions::new().write(true).create_new(true).open(path)?;
    fs::rename(temporary, path)
}

impl KeyStore for DpapiKeyStore {
    fn secret(&self, name: &str) -> Result<Option<Zeroizing<Vec<u8>>>, IdentityError> {
        let path = self.path(name).ok_or(IdentityError::Unavailable)?;
        let mut file = match fs::File::open(&path) {
            Ok(file) => file,
            Err(e) if e.kind() == ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(IdentityError::Unavailable),
        };
        let length = file.metadata().map_err(|_| IdentityError::Unavailable)?.len();
        if length == 0 {
            return Ok(None);
        }
        if length > FILE_MAX {
            return Err(IdentityError::Unavailable);
        }
        let mut protected = Vec::with_capacity(length as usize);
        file.read_to_end(&mut protected).map_err(|_| IdentityError::Unavailable)?;
        let secret = dpapi::unprotect(&protected, &entropy(name)).map_err(|_| IdentityError::Unavailable)?;
        Ok(Some(Zeroizing::new(secret)))
    }

    fn store(&self, name: &str, secret: &[u8]) -> Result<(), IdentityError> {
        let path = self.path(name).ok_or(IdentityError::StoreFailed)?;
        fs::create_dir_all(&self.directory).map_err(|_| IdentityError::StoreFailed)?;
        // The empty claim of a store that was interrupted holds nothing: taken back, as `secret` reads it absent.
        if fs::metadata(&path).is_ok_and(|m| m.is_file() && m.len() == 0) {
            let _ = fs::remove_file(&path);
        }
        let protected = dpapi::protect(secret, &entropy(name), DESCRIPTION).map_err(|_| IdentityError::StoreFailed)?;
        let mut random = [0u8; 8];
        szfriends_crypto::random_bytes(&mut random);
        let suffix: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let temporary = self.directory.join(format!(".{name}.{suffix}.tmp"));
        let written = (|| {
            let mut file = OpenOptions::new().write(true).create_new(true).open(&temporary)?;
            file.write_all(&protected)?;
            file.sync_all()?;
            publish(&temporary, &path)
        })();
        let _ = fs::remove_file(&temporary);
        written.map_err(|_| IdentityError::StoreFailed)
    }

    fn delete(&self, name: &str) -> Result<(), IdentityError> {
        let path = self.path(name).ok_or(IdentityError::StoreFailed)?;
        match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == ErrorKind::NotFound => Ok(()),
            Err(_) => Err(IdentityError::StoreFailed),
        }
    }
}

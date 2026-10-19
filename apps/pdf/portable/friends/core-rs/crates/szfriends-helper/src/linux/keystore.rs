//! The Linux key store (ADR 0015 § 7): the Secret Service where one runs, a 0600 file under the state directory
//! where none does, and a record of which (`<state dir>/keystore`), written before the first key is stored. With
//! the record saying Secret Service, a Secret Service missing later (a session without a keyring) makes the key
//! unavailable, never absent, so no second identity is made beside the first.

use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;

use szfriends_identity::keystore::{FileKeyStore, KeyStore};
use szfriends_identity::IdentityError;
use zeroize::Zeroizing;

use super::dbus;
use super::secret_service::SecretService;

const RECORD: &str = "keystore";
const SECRET_SERVICE: &str = "secret-service\n";
const FILE: &str = "file\n";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Backend {
    SecretService,
    File,
}

type Connect = Box<dyn Fn() -> Result<SecretService, dbus::Error> + Send + Sync>;

pub struct LinuxKeyStore {
    record: PathBuf,
    file: FileKeyStore,
    connect: Connect,
}

impl std::fmt::Debug for LinuxKeyStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LinuxKeyStore").field("record", &self.record).finish()
    }
}

impl LinuxKeyStore {
    /// The store for a state directory: its record, its `keys` directory, and the session bus's Secret Service
    /// scoped to `scope` (the state directory's hash).
    pub fn new(state_dir: PathBuf, scope: String) -> Self {
        Self::with_connector(state_dir, Box::new(move || SecretService::open(&scope)))
    }

    /// With another way to reach a Secret Service (tests: a private bus).
    pub fn with_connector(state_dir: PathBuf, connect: Connect) -> Self {
        Self { record: state_dir.join(RECORD), file: FileKeyStore::new(state_dir.join("keys")), connect }
    }

    /// Which store the record names; `Err` for a record that cannot be read or is not one of ours.
    pub fn backend(&self) -> Result<Option<Backend>, IdentityError> {
        match fs::read_to_string(&self.record) {
            Ok(text) if text == SECRET_SERVICE => Ok(Some(Backend::SecretService)),
            Ok(text) if text == FILE => Ok(Some(Backend::File)),
            Err(e) if e.kind() == ErrorKind::NotFound => Ok(None),
            _ => Err(IdentityError::Unavailable),
        }
    }

    /// Records `choice` unless a record exists, and returns what the record says.
    fn record(&self, choice: Backend) -> Result<Backend, IdentityError> {
        let text = if choice == Backend::SecretService { SECRET_SERVICE } else { FILE };
        let written = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
            .open(&self.record)
            .and_then(|mut file| {
                file.write_all(text.as_bytes())?;
                file.sync_all()
            });
        match written {
            Ok(()) => Ok(choice),
            Err(e) if e.kind() == ErrorKind::AlreadyExists => self.backend()?.ok_or(IdentityError::StoreFailed),
            Err(_) => Err(IdentityError::StoreFailed),
        }
    }

    fn service(&self, error: IdentityError) -> Result<SecretService, IdentityError> {
        (self.connect)().map_err(|_| error)
    }
}

impl KeyStore for LinuxKeyStore {
    fn secret(&self, name: &str) -> Result<Option<Zeroizing<Vec<u8>>>, IdentityError> {
        match self.backend()? {
            Some(Backend::SecretService) => self.service(IdentityError::Unavailable)?.secret(name),
            // No record yet means nothing was ever stored; the file store answers that (and finds a file key that
            // lost its record, rather than calling it absent).
            Some(Backend::File) | None => self.file.secret(name),
        }
    }

    fn store(&self, name: &str, secret: &[u8]) -> Result<(), IdentityError> {
        let backend = match self.backend().map_err(|_| IdentityError::StoreFailed)? {
            Some(backend) => backend,
            None => {
                let usable = (self.connect)().is_ok_and(|mut service| service.usable());
                self.record(if usable { Backend::SecretService } else { Backend::File })?
            }
        };
        match backend {
            Backend::SecretService => self.service(IdentityError::StoreFailed)?.store(name, secret),
            Backend::File => self.file.store(name, secret),
        }
    }

    fn delete(&self, name: &str) -> Result<(), IdentityError> {
        match self.backend().map_err(|_| IdentityError::StoreFailed)? {
            Some(Backend::SecretService) => self.service(IdentityError::StoreFailed)?.delete(name),
            Some(Backend::File) | None => self.file.delete(name),
        }
    }
}

//! The identity key in the Secret Service (ADR 0015 § 7): one item per key-store name in the default collection,
//! found by attributes that name Friends, the state directory and the name. The `plain` session algorithm: the
//! secret crosses only the user's own session bus.
//!
//! The key-store rules hold here as everywhere: an item that exists but cannot be read (its collection locked) is
//! unavailable, never absent; reads never prompt (a locked collection is not unlocked); storing never replaces an
//! existing item.

use szfriends_identity::IdentityError;
use zeroize::Zeroizing;

use super::dbus::{Bus, Error};
use super::marshal::Value;

const SERVICE: &str = "org.freedesktop.secrets";
const SERVICE_PATH: &str = "/org/freedesktop/secrets";
const SERVICE_INTERFACE: &str = "org.freedesktop.Secret.Service";
const ITEM_INTERFACE: &str = "org.freedesktop.Secret.Item";
const COLLECTION_INTERFACE: &str = "org.freedesktop.Secret.Collection";
/// What the person sees in their keyring app ("Passwords and Keys") beside the item.
const LABEL: &str = "Shenzhen Friends identity";

/// A session with the Secret Service, for one key-store operation.
#[derive(Debug)]
pub struct SecretService {
    bus: Bus,
    session: String,
    /// Separates the items of different state directories (tests, a second profile directory).
    scope: String,
}

fn object(values: &[Value], at: usize) -> Option<String> {
    values.get(at)?.as_str().map(str::to_owned)
}

fn paths(value: Option<&Value>) -> Vec<String> {
    match value {
        Some(Value::Array(_, items)) => items.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect(),
        _ => Vec::new(),
    }
}

impl SecretService {
    /// Connects to the session bus's Secret Service and opens a `plain` session. Fails when none runs.
    pub fn open(scope: &str) -> Result<Self, Error> {
        Self::open_on(Bus::session()?, scope)
    }

    pub fn open_on(mut bus: Bus, scope: &str) -> Result<Self, Error> {
        let algorithm = [Value::Str("plain".into()), Value::Variant(Box::new(Value::Str(String::new())))];
        let opened = bus.call(SERVICE, SERVICE_PATH, SERVICE_INTERFACE, "OpenSession", &algorithm)?;
        let session = object(&opened, 1).ok_or(Error::Protocol("OpenSession answered no session"))?;
        Ok(Self { bus, session, scope: scope.to_owned() })
    }

    fn attributes(&self, name: &str) -> Value {
        Value::string_dict(&[
            ("application", "shenzhen-friends"),
            ("szfriends-state", &self.scope),
            ("szfriends-name", name),
        ])
    }

    /// The items for `name`: (unlocked, locked).
    fn search(&mut self, name: &str) -> Result<(Vec<String>, Vec<String>), Error> {
        let attributes = self.attributes(name);
        let found = self.bus.call(SERVICE, SERVICE_PATH, SERVICE_INTERFACE, "SearchItems", &[attributes])?;
        Ok((paths(found.first()), paths(found.get(1))))
    }

    /// `Ok(None)` when no item exists; `Unavailable` when one exists but is locked, or several claim the name.
    pub fn secret(&mut self, name: &str) -> Result<Option<Zeroizing<Vec<u8>>>, IdentityError> {
        let (unlocked, locked) = self.search(name).map_err(|_| IdentityError::Unavailable)?;
        let item = match (unlocked.as_slice(), locked.is_empty()) {
            ([], true) => return Ok(None),
            ([item], true) => item.clone(),
            _ => return Err(IdentityError::Unavailable),
        };
        let session = Value::ObjectPath(self.session.clone());
        let answer = self
            .bus
            .call(SERVICE, &item, ITEM_INTERFACE, "GetSecret", &[session])
            .map_err(|_| IdentityError::Unavailable)?;
        match answer.into_iter().next() {
            Some(Value::Struct(fields)) => match fields.into_iter().nth(2) {
                Some(Value::Bytes(value)) => Ok(Some(value)),
                _ => Err(IdentityError::Unavailable),
            },
            _ => Err(IdentityError::Unavailable),
        }
    }

    /// The default collection, when there is one; creating one would prompt, so none is created.
    pub fn default_collection(&mut self) -> Result<Option<String>, Error> {
        let alias = [Value::Str("default".into())];
        let answer = self.bus.call(SERVICE, SERVICE_PATH, SERVICE_INTERFACE, "ReadAlias", &alias)?;
        Ok(object(&answer, 0).filter(|path| path != "/"))
    }

    /// Whether this service can take a new item now: a default collection exists.
    pub fn usable(&mut self) -> bool {
        matches!(self.default_collection(), Ok(Some(_)))
    }

    /// Creates the item; refuses when one exists, when there is no default collection, and when the collection
    /// would need a prompt (locked).
    pub fn store(&mut self, name: &str, secret: &[u8]) -> Result<(), IdentityError> {
        let (unlocked, locked) = self.search(name).map_err(|_| IdentityError::StoreFailed)?;
        if !unlocked.is_empty() || !locked.is_empty() {
            return Err(IdentityError::StoreFailed);
        }
        let collection = match self.default_collection() {
            Ok(Some(collection)) => collection,
            _ => return Err(IdentityError::StoreFailed),
        };
        let property = |key: &str, value: Value| {
            Value::DictEntry(Box::new(Value::Str(key.into())), Box::new(Value::Variant(Box::new(value))))
        };
        let properties = Value::Array(
            "{sv}".into(),
            vec![
                property("org.freedesktop.Secret.Item.Label", Value::Str(LABEL.into())),
                property("org.freedesktop.Secret.Item.Attributes", self.attributes(name)),
            ],
        );
        let secret = Value::Struct(vec![
            Value::ObjectPath(self.session.clone()),
            Value::Bytes(Zeroizing::new(Vec::new())),
            Value::Bytes(Zeroizing::new(secret.to_vec())),
            Value::Str("application/octet-stream".into()),
        ]);
        let created = self
            .bus
            .call(SERVICE, &collection, COLLECTION_INTERFACE, "CreateItem", &[properties, secret, Value::Bool(false)])
            .map_err(|_| IdentityError::StoreFailed)?;
        // A prompt other than "/" means the collection is locked: nothing was stored, and no prompt is shown.
        match (object(&created, 0), object(&created, 1)) {
            (Some(item), Some(prompt)) if item != "/" && prompt == "/" => Ok(()),
            _ => Err(IdentityError::StoreFailed),
        }
    }

    /// Deletes every item for `name`; succeeds when none is left.
    pub fn delete(&mut self, name: &str) -> Result<(), IdentityError> {
        let (unlocked, locked) = self.search(name).map_err(|_| IdentityError::StoreFailed)?;
        if !locked.is_empty() {
            return Err(IdentityError::StoreFailed);
        }
        for item in unlocked {
            let answer =
                self.bus.call(SERVICE, &item, ITEM_INTERFACE, "Delete", &[]).map_err(|_| IdentityError::StoreFailed)?;
            if object(&answer, 0).as_deref() != Some("/") {
                return Err(IdentityError::StoreFailed);
            }
        }
        Ok(())
    }

    /// Locks the default collection (tests: a locked keyring's items must read as unavailable).
    pub fn lock_default_collection(&mut self) -> Result<(), Error> {
        let collection = self.default_collection()?.ok_or(Error::Protocol("no default collection"))?;
        let objects = Value::Array("o".into(), vec![Value::ObjectPath(collection)]);
        self.bus.call(SERVICE, SERVICE_PATH, SERVICE_INTERFACE, "Lock", &[objects])?;
        Ok(())
    }
}

impl Drop for SecretService {
    fn drop(&mut self) {
        let session = self.session.clone();
        let _ = self.bus.call(SERVICE, &session, "org.freedesktop.Secret.Session", "Close", &[]);
    }
}

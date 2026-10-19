//! Device chains in the store (`SZFriendsStoreDevices.m`, schema v8): this person's own chain and each friend's, each
//! verified before it is kept and only replaced by a superset of its links, with every device indexed by its key in
//! the same transaction, so the index never disagrees with the chain beside it.

use rusqlite::{params, Connection, OptionalExtension};
use szfriends_identity::chain::{ChainError, DeviceChain, DeviceState};
use szfriends_identity::Identity;

use super::sync_log::atomically;
use super::{unix_now, Result, StoreError};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChainMerge {
    Unchanged,
    /// The union is stored, and the device index with it.
    Changed,
}

/// One device of a kept chain.
#[derive(Clone, Debug, PartialEq)]
pub struct DeviceRecord {
    pub root_key: [u8; 32],
    pub device_key: [u8; 32],
    pub static_key: [u8; 32],
    pub name: String,
    pub system: String,
    pub state: DeviceState,
    pub added_at: f64,
    pub revoked_at: Option<f64>,
    /// The last session with it went live.
    pub last_seen_at: Option<f64>,
    pub is_root: bool,
}

fn chain_error(error: ChainError) -> StoreError {
    match error {
        ChainError::WrongRoot => StoreError::IdentityMismatch,
        _ => StoreError::Invalid("a chain that does not verify"),
    }
}

fn stored_chain(conn: &Connection, clause: &str, bind: Option<&[u8]>) -> Result<Option<(Vec<u8>, bool)>> {
    let sql = format!("SELECT chain, own FROM device_chains {clause}");
    let row = match bind {
        Some(bind) => conn.query_row(&sql, [bind], |r| Ok((r.get(0)?, r.get::<_, i64>(1)? == 1))),
        None => conn.query_row(&sql, [], |r| Ok((r.get(0)?, r.get::<_, i64>(1)? == 1))),
    };
    Ok(row.optional()?)
}

/// Writes `chain` as the row for its root and rewrites that root's device index, keeping each device's last
/// connection. Refused when a device key already belongs to another root: a key speaks for one person only.
fn write_chain(conn: &Connection, chain: &DeviceChain, own: bool) -> Result<()> {
    let root = chain.root_key().to_vec();
    for device in chain.devices() {
        let other: Option<Vec<u8>> = conn
            .query_row(
                "SELECT root_pk FROM chain_devices WHERE device_pk = ?1 AND root_pk <> ?2",
                params![device.device_key.to_vec(), root],
                |r| r.get(0),
            )
            .optional()?;
        if other.is_some() {
            return Err(StoreError::Constraint);
        }
    }
    conn.execute(
        "INSERT INTO device_chains(root_pk, genesis_hash, chain, own, updated_at) VALUES (?1, ?2, ?3, ?4, ?5) \
         ON CONFLICT(root_pk) DO UPDATE SET chain = excluded.chain, own = excluded.own, \
         updated_at = excluded.updated_at",
        params![root, chain.genesis_hash().to_vec(), chain.encoded(), i64::from(own), unix_now()],
    )?;
    for device in chain.devices() {
        conn.execute(
            "INSERT INTO chain_devices(device_pk, root_pk, static_pk, name, system, state, added_at, revoked_at) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8) ON CONFLICT(device_pk) DO UPDATE SET \
             static_pk = excluded.static_pk, name = excluded.name, system = excluded.system, \
             state = excluded.state, added_at = excluded.added_at, revoked_at = excluded.revoked_at",
            params![
                device.device_key.to_vec(),
                root,
                device.static_key.to_vec(),
                device.name,
                device.system,
                device.state as i64,
                device.added_at,
                device.revoked_at
            ],
        )?;
    }
    Ok(())
}

pub fn own_chain(conn: &Connection) -> Result<Option<DeviceChain>> {
    let Some((data, _)) = stored_chain(conn, "WHERE own = 1", None)? else { return Ok(None) };
    Ok(DeviceChain::decode(&data, None).ok())
}

/// The own chain, writing its genesis first when there is none (an existing single-device profile becomes a chain
/// whose first device is this one).
pub fn own_chain_creating_genesis(
    conn: &Connection,
    identity: &Identity,
    name: &str,
    system: &str,
) -> Result<DeviceChain> {
    atomically(conn, |conn| {
        if let Some((data, _)) = stored_chain(conn, "WHERE own = 1", None)? {
            return DeviceChain::decode(&data, None).map_err(chain_error);
        }
        let chain = DeviceChain::genesis(identity, name, system, unix_now()).map_err(chain_error)?;
        write_chain(conn, &chain, true)?;
        Ok(chain)
    })
}

/// Joining: replaces the own chain with the profile's, which must authorize `local_key`.
pub fn adopt_own_chain(conn: &Connection, chain: &DeviceChain, local_key: &[u8; 32]) -> Result<()> {
    if !chain.authorizes(local_key) {
        return Err(StoreError::Invalid("a profile's chain that does not include this device"));
    }
    atomically(conn, |conn| {
        conn.execute("DELETE FROM device_chains WHERE own = 1 OR root_pk = ?1", [chain.root_key().to_vec()])?;
        write_chain(conn, chain, true)
    })
}

fn merge_into(
    conn: &Connection,
    chain: &DeviceChain,
    clause: &str,
    bind: Option<&[u8]>,
    own: bool,
) -> Result<ChainMerge> {
    atomically(conn, |conn| {
        let stored = match stored_chain(conn, clause, bind)? {
            Some((data, stored_own)) => {
                let stored = DeviceChain::decode(&data, Some(chain.root_key())).map_err(chain_error)?;
                if stored_own != own {
                    return Err(StoreError::Invalid("our own chain never arrives as a friend's"));
                }
                Some(stored)
            }
            None => None,
        };
        if stored.as_ref().is_some_and(|s| s.contains(chain)) {
            return Ok(ChainMerge::Unchanged);
        }
        let merged = match stored {
            Some(stored) => stored.merged(chain).map_err(chain_error)?,
            None => chain.clone(),
        };
        write_chain(conn, &merged, own)?;
        Ok(ChainMerge::Changed)
    })
}

/// A chain of the same root and genesis from one of our devices, or one this device built: stored as the union.
pub fn merge_own_chain(conn: &Connection, chain: &DeviceChain) -> Result<ChainMerge> {
    let own_root: Option<Vec<u8>> =
        conn.query_row("SELECT root_pk FROM device_chains WHERE own = 1", [], |r| r.get(0)).optional()?;
    if own_root.as_deref() != Some(chain.root_key().as_slice()) {
        return Err(StoreError::Invalid("not this person's chain"));
    }
    merge_into(conn, chain, "WHERE own = 1", None, true)
}

/// A CHAIN frame from a friend whose pinned root is `root`: kept only when a person in the list has that key, it
/// verifies from that root, and its genesis is the one already kept.
pub fn merge_friend_chain(conn: &Connection, data: &[u8], root: &[u8; 32]) -> Result<ChainMerge> {
    let known: i64 =
        conn.query_row("SELECT count(*) FROM friends WHERE identity_pk = ?1", [root.to_vec()], |r| r.get(0))?;
    if known == 0 {
        return Err(StoreError::NotFound);
    }
    if stored_chain(conn, "WHERE root_pk = ?1 AND own = 0", Some(root))?.is_some_and(|(d, _)| d == data) {
        return Ok(ChainMerge::Unchanged);
    }
    let chain = DeviceChain::decode(data, Some(root)).map_err(chain_error)?;
    merge_into(conn, &chain, "WHERE root_pk = ?1", Some(root), false)
}

/// Our Add by ID answered by a device other than its person's first: the row the answer made names that device until
/// its chain says whose it is. It moves to the root (and the first device's static key) only while it is that
/// device's row and nobody in the list holds the root; the chain is kept with it.
pub fn rekey_conversation(conn: &Connection, conversation: &str, device: &[u8; 32], chain: &DeviceChain) -> Result<()> {
    let root = *chain.root_key();
    let first = chain.device(&root).map(|d| d.static_key);
    let Some(first) = first.filter(|_| chain.authorizes(device) && *device != root) else {
        return Err(StoreError::Invalid("a chain that does not name this device"));
    };
    atomically(conn, |conn| {
        let count = |sql: &str, binds: &[&dyn rusqlite::ToSql]| conn.query_row(sql, binds, |r| r.get::<_, i64>(0));
        let mine = count(
            "SELECT count(*) FROM friends WHERE conversation_id = ?1 AND identity_pk = ?2",
            &[&conversation, &device.to_vec()],
        )?;
        let taken = count("SELECT count(*) FROM friends WHERE identity_pk = ?1", &[&root.to_vec()])?;
        if mine != 1 || taken != 0 {
            return Err(StoreError::Constraint);
        }
        conn.execute(
            "UPDATE friends SET identity_pk = ?1, static_pk = ?2 WHERE conversation_id = ?3",
            params![root.to_vec(), first.to_vec(), conversation],
        )?;
        merge_into(conn, chain, "WHERE root_pk = ?1", Some(&root), false).map(|_| ())
    })
}

pub fn chain_for_root(conn: &Connection, root: &[u8; 32]) -> Result<Option<DeviceChain>> {
    let Some((data, _)) = stored_chain(conn, "WHERE root_pk = ?1", Some(root))? else { return Ok(None) };
    Ok(DeviceChain::decode(&data, Some(root)).ok())
}

fn key(bytes: Vec<u8>) -> [u8; 32] {
    bytes.try_into().unwrap_or([0; 32])
}

/// The root an authorized device speaks for, in any kept chain.
pub fn root_for_device(conn: &Connection, device: &[u8; 32]) -> Result<Option<[u8; 32]>> {
    let root: Option<Vec<u8>> = conn
        .query_row("SELECT root_pk FROM chain_devices WHERE device_pk = ?1 AND state = 1", [device.to_vec()], |r| {
            r.get(0)
        })
        .optional()?;
    Ok(root.map(key))
}

pub fn is_revoked_device(conn: &Connection, device: &[u8; 32]) -> Result<bool> {
    let count: i64 = conn.query_row(
        "SELECT count(*) FROM chain_devices WHERE device_pk = ?1 AND state = 2",
        [device.to_vec()],
        |r| r.get(0),
    )?;
    Ok(count > 0)
}

pub fn static_key_for_device(conn: &Connection, device: &[u8; 32], root: &[u8; 32]) -> Result<Option<[u8; 32]>> {
    let value: Option<Vec<u8>> = conn
        .query_row(
            "SELECT static_pk FROM chain_devices WHERE device_pk = ?1 AND root_pk = ?2 AND state = 1",
            [device.to_vec(), root.to_vec()],
            |r| r.get(0),
        )
        .optional()?;
    Ok(value.map(key))
}

/// Every device of a kept chain: authorized first, the first device before the others, then by when added.
pub fn devices_of_root(conn: &Connection, root: &[u8; 32]) -> Result<Vec<DeviceRecord>> {
    let mut statement = conn.prepare(
        "SELECT root_pk, device_pk, static_pk, name, system, state, added_at, revoked_at, last_seen_at \
         FROM chain_devices WHERE root_pk = ?1 ORDER BY state <> 1, device_pk <> root_pk, added_at, device_pk",
    )?;
    let rows = statement.query_map([root.to_vec()], |r| {
        let (root_key, device_key) = (key(r.get(0)?), key(r.get(1)?));
        Ok(DeviceRecord {
            root_key,
            device_key,
            static_key: key(r.get(2)?),
            name: r.get::<_, Option<String>>(3)?.unwrap_or_default(),
            system: r.get::<_, Option<String>>(4)?.unwrap_or_default(),
            state: DeviceState::from_i64(r.get(5)?).unwrap_or(DeviceState::Void),
            added_at: r.get::<_, Option<f64>>(6)?.unwrap_or(0.0),
            revoked_at: r.get(7)?,
            last_seen_at: r.get(8)?,
            is_root: root_key == device_key,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

pub fn note_device_seen(conn: &Connection, device: &[u8; 32], at: f64) -> Result<()> {
    conn.execute("UPDATE chain_devices SET last_seen_at = ?1 WHERE device_pk = ?2", params![at, device.to_vec()])?;
    Ok(())
}

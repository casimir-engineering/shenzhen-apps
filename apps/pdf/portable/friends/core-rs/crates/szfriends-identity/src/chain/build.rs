//! The chain as a value (`SZFriendsDeviceChain.m`): decoding with every check, the canonical order, merging and the
//! builders. Encoding: `version u8 (1) | link count u16be | (length u16be | link)*`, parents first, ties by link hash,
//! so equal chains are equal bytes.

use std::collections::{HashMap, HashSet};

use super::link::{ChainLink, LinkFields, LinkKind};
use super::rules::{self, Set};
use super::{
    chain_label, device_consent, milliseconds, verify_device_consent, ChainDevice, ChainError, DeviceState,
    ENCODED_MAX, MAX_LINKS, NAME_MAX, PARENTS_MAX, RENAME_LIMIT, SYSTEM_MAX,
};
use crate::identity::Identity;

const VERSION: u8 = 1;

#[derive(Clone, Debug, PartialEq)]
pub struct DeviceChain {
    root_key: [u8; 32],
    links: Vec<ChainLink>,
    heads: Vec<[u8; 32]>,
    encoded: Vec<u8>,
    devices: Vec<ChainDevice>,
}

/// Kahn's order, smallest hash first among the links whose parents are placed; `None` when a parent is missing.
fn canonical_order(links: Vec<ChainLink>) -> Option<Vec<ChainLink>> {
    let hashes: HashSet<[u8; 32]> = links.iter().map(|l| l.hash).collect();
    if links.iter().any(|l| l.parents.iter().any(|p| !hashes.contains(p))) {
        return None;
    }
    let mut unique: HashMap<[u8; 32], ChainLink> = HashMap::new();
    for link in links {
        unique.insert(link.hash, link);
    }
    let mut waiting: Vec<ChainLink> = unique.into_values().collect();
    szfriends_wire::order::sort_by_key(&mut waiting, |l| l.hash);
    let mut placed: HashSet<[u8; 32]> = HashSet::new();
    let mut ordered = Vec::with_capacity(waiting.len());
    while !waiting.is_empty() {
        let next = waiting.iter().position(|l| l.parents.iter().all(|p| placed.contains(p)))?;
        let link = waiting.remove(next);
        placed.insert(link.hash);
        ordered.push(link);
    }
    Some(ordered)
}

impl DeviceChain {
    /// Every rule that needs other links, on links whose own signatures were checked, listed parents first.
    fn with_checked_links(input: Vec<ChainLink>) -> Result<Self, ChainError> {
        if input.is_empty() || input.len() > MAX_LINKS {
            return Err(ChainError::Full);
        }
        if input[0].kind != LinkKind::Genesis {
            return Err(ChainError::Malformed);
        }
        let mut index_of: HashMap<[u8; 32], usize> = HashMap::new();
        let mut static_of: HashMap<[u8; 32], [u8; 32]> = HashMap::new();
        let mut ancestors: Vec<Set> = Vec::with_capacity(input.len());
        for (i, link) in input.iter().enumerate() {
            let second_genesis = i > 0 && link.kind == LinkKind::Genesis;
            if index_of.contains_key(&link.hash) || second_genesis {
                return Err(if second_genesis { ChainError::WrongRoot } else { ChainError::Malformed });
            }
            let mut seen: Set = 0;
            for parent in &link.parents {
                let p = *index_of.get(parent).ok_or(ChainError::Malformed)?;
                seen |= (1 << p) | ancestors[p];
            }
            if let Some(static_key) = link.static_key {
                if static_of.get(&link.subject).is_some_and(|known| *known != static_key) {
                    return Err(ChainError::Malformed);
                }
                static_of.insert(link.subject, static_key);
            }
            if i > 0 {
                let seen_links = (0..i).filter(|a| rules::has(seen, *a)).map(|a| &input[a]);
                let (mut signer_added, mut subject_added, mut subject_revoked) = (false, false, false);
                for earlier in seen_links {
                    signer_added |= earlier.adds(&link.signer);
                    subject_added |= earlier.adds(&link.subject);
                    subject_revoked |= earlier.kind == LinkKind::Revoke && earlier.subject == link.subject;
                }
                if !signer_added {
                    return Err(ChainError::Unauthorized);
                }
                if link.kind == LinkKind::Revoke && !subject_added {
                    return Err(ChainError::Malformed);
                }
                if link.kind == LinkKind::Add && subject_revoked {
                    return Err(ChainError::RevokedDevice);
                }
            }
            index_of.insert(link.hash, i);
            ancestors.push(seen);
        }
        let links = canonical_order(input).ok_or(ChainError::Malformed)?;
        Self::from_ordered(links)
    }

    fn from_ordered(links: Vec<ChainLink>) -> Result<Self, ChainError> {
        let root_key = links[0].signer;
        let mut index_of: HashMap<[u8; 32], usize> = HashMap::new();
        let mut ancestors: Vec<Set> = Vec::with_capacity(links.len());
        let mut named: HashSet<[u8; 32]> = HashSet::new();
        let mut encoded = vec![VERSION];
        encoded.extend_from_slice(&(links.len() as u16).to_be_bytes());
        for (i, link) in links.iter().enumerate() {
            let mut seen: Set = 0;
            for parent in &link.parents {
                let p = index_of[parent];
                seen |= (1 << p) | ancestors[p];
                named.insert(*parent);
            }
            ancestors.push(seen);
            index_of.insert(link.hash, i);
            encoded.extend_from_slice(&(link.encoded.len() as u16).to_be_bytes());
            encoded.extend_from_slice(&link.encoded);
        }
        if encoded.len() > ENCODED_MAX {
            return Err(ChainError::Full);
        }
        let mut heads: Vec<[u8; 32]> = links.iter().map(|l| l.hash).filter(|h| !named.contains(h)).collect();
        heads.sort();
        let devices = rules::apply(&links, &ancestors, &root_key);
        Ok(Self { root_key, links, heads, encoded, devices })
    }

    /// Decodes and verifies `data`. With `expected_root`, a chain of another root fails `WrongRoot`; `None` takes the
    /// root from the genesis (a device joining a profile learns it here).
    pub fn decode(data: &[u8], expected_root: Option<&[u8; 32]>) -> Result<Self, ChainError> {
        if data.len() < 3 || data.len() > ENCODED_MAX || data[0] != VERSION {
            return Err(ChainError::Malformed);
        }
        let count = u16::from_be_bytes([data[1], data[2]]) as usize;
        if count == 0 || count > MAX_LINKS {
            return Err(ChainError::Full);
        }
        let mut root = expected_root.copied();
        let mut position = 3;
        let mut links = Vec::with_capacity(count);
        for i in 0..count {
            if data.len() - position < 2 {
                break;
            }
            let length = u16::from_be_bytes([data[position], data[position + 1]]) as usize;
            position += 2;
            if data.len() - position < length {
                break;
            }
            let link = ChainLink::decode(&data[position..position + length], root.as_ref())?;
            position += length;
            if i == 0 && link.kind != LinkKind::Genesis {
                return Err(ChainError::Malformed);
            }
            root.get_or_insert(link.signer);
            links.push(link);
        }
        if links.len() != count || position != data.len() {
            return Err(ChainError::Malformed);
        }
        Self::with_checked_links(links)
    }

    /// Genesis for an existing or new profile: `root` is this device's identity.
    pub fn genesis(root: &Identity, name: &str, system: &str, seconds: f64) -> Result<Self, ChainError> {
        let key = root.public_key();
        let fields = LinkFields {
            kind: LinkKind::Genesis,
            parents: &[],
            subject: key,
            static_key: Some(root.static_public_key()),
            consent: Some(device_consent(root, &key)),
            name: Some(name),
            system: Some(system),
            milliseconds: milliseconds(seconds),
        };
        Self::with_checked_links(vec![ChainLink::signed(fields, root, &key)?])
    }

    pub fn root_key(&self) -> &[u8; 32] {
        &self.root_key
    }

    pub fn genesis_hash(&self) -> [u8; 32] {
        self.links[0].hash
    }

    /// Canonical order: parents first, ties by link hash.
    pub fn links(&self) -> &[ChainLink] {
        &self.links
    }

    /// Links no other link names: the next link's parents.
    pub fn heads(&self) -> &[[u8; 32]] {
        &self.heads
    }

    pub fn encoded(&self) -> &[u8] {
        &self.encoded
    }

    /// Every device the chain ever added, earliest first, with its state.
    pub fn devices(&self) -> &[ChainDevice] {
        &self.devices
    }

    pub fn authorized_devices(&self) -> impl Iterator<Item = &ChainDevice> {
        self.devices.iter().filter(|d| d.state == DeviceState::Authorized)
    }

    pub fn device(&self, key: &[u8; 32]) -> Option<&ChainDevice> {
        self.devices.iter().find(|d| &d.device_key == key)
    }

    pub fn authorizes(&self, key: &[u8; 32]) -> bool {
        self.device(key).is_some_and(|d| d.state == DeviceState::Authorized)
    }

    pub fn revokes(&self, key: &[u8; 32]) -> bool {
        self.device(key).is_some_and(|d| d.state == DeviceState::Revoked)
    }

    pub fn contains_link(&self, hash: &[u8; 32]) -> bool {
        self.links.iter().any(|l| &l.hash == hash)
    }

    /// Every link of `other` is here: merging it would change nothing.
    pub fn contains(&self, other: &DeviceChain) -> bool {
        other.links.iter().all(|l| self.contains_link(&l.hash))
    }

    /// The union with `other`, verified again.
    pub fn merged(&self, other: &DeviceChain) -> Result<DeviceChain, ChainError> {
        if other.genesis_hash() != self.genesis_hash() {
            return Err(ChainError::WrongRoot);
        }
        if self.contains(other) {
            return Ok(self.clone());
        }
        if other.contains(self) {
            return Ok(other.clone());
        }
        let mut union = self.links.clone();
        union.extend(other.links.iter().filter(|l| !self.contains_link(&l.hash)).cloned());
        let ordered = canonical_order(union).ok_or(ChainError::Malformed)?;
        Self::with_checked_links(ordered)
    }

    fn appended(&self, fields: LinkFields<'_>, signer: &Identity) -> Result<DeviceChain, ChainError> {
        if !self.authorizes(&signer.public_key()) {
            return Err(ChainError::Unauthorized);
        }
        if self.links.len() >= MAX_LINKS {
            return Err(ChainError::Full);
        }
        let link = ChainLink::signed(fields, signer, &self.root_key)?;
        let mut links = self.links.clone();
        links.push(link);
        Self::with_checked_links(links)
    }

    fn parents(&self) -> Vec<[u8; 32]> {
        self.heads.iter().take(PARENTS_MAX).copied().collect()
    }

    /// Adds a device with its consent; refuses one already authorized or ever revoked.
    #[allow(clippy::too_many_arguments)]
    pub fn adding(
        &self,
        device_key: &[u8; 32],
        static_key: &[u8; 32],
        consent: &[u8; 64],
        name: &str,
        system: &str,
        signer: &Identity,
        seconds: f64,
    ) -> Result<DeviceChain, ChainError> {
        if self.links.iter().any(|l| l.kind == LinkKind::Revoke && &l.subject == device_key) {
            return Err(ChainError::RevokedDevice);
        }
        if let Some(known) = self.device(device_key) {
            if known.state == DeviceState::Authorized || &known.static_key != static_key {
                return Err(ChainError::Refused);
            }
        }
        if !verify_device_consent(consent, device_key, static_key, &self.root_key) {
            return Err(ChainError::Forged);
        }
        let parents = self.parents();
        let fields = LinkFields {
            kind: LinkKind::Add,
            parents: &parents,
            subject: *device_key,
            static_key: Some(*static_key),
            consent: Some(*consent),
            name: Some(name),
            system: Some(system),
            milliseconds: milliseconds(seconds),
        };
        self.appended(fields, signer)
    }

    pub fn revoking(&self, device_key: &[u8; 32], signer: &Identity, seconds: f64) -> Result<DeviceChain, ChainError> {
        let device = self.device(device_key).ok_or(ChainError::Refused)?;
        if device.state == DeviceState::Revoked {
            return Ok(self.clone());
        }
        let parents = self.parents();
        let fields = LinkFields {
            kind: LinkKind::Revoke,
            parents: &parents,
            subject: *device_key,
            static_key: None,
            consent: None,
            name: None,
            system: None,
            milliseconds: milliseconds(seconds),
        };
        self.appended(fields, signer)
    }

    pub fn renaming(
        &self,
        name: &str,
        system: &str,
        signer: &Identity,
        seconds: f64,
    ) -> Result<DeviceChain, ChainError> {
        let key = signer.public_key();
        let (name, system) = (chain_label(name, NAME_MAX), chain_label(system, SYSTEM_MAX));
        if self.device(&key).is_some_and(|d| d.name == name && d.system == system) {
            return Ok(self.clone());
        }
        if self.links.len() >= RENAME_LIMIT {
            return Err(ChainError::Full);
        }
        let parents = self.parents();
        let fields = LinkFields {
            kind: LinkKind::Rename,
            parents: &parents,
            subject: key,
            static_key: None,
            consent: None,
            name: Some(&name),
            system: Some(&system),
            milliseconds: milliseconds(seconds),
        };
        self.appended(fields, signer)
    }
}

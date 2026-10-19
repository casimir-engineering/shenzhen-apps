//! Which links count, and so which devices speak for the person (`SZFriendsDeviceChainRules.m`, ADR 0012 § Rules). A
//! pure function of the set of links: every holder of the same links computes the same devices.
//!
//! 1. A revocation r of device X is void when a concurrent revocation r' (one that did not see r) removed r's signer,
//!    unless r' was signed by X, or by a device X added (directly or through others) by adds r did not see.
//! 2. Starting from every revocation not void by 1: a genesis always counts; an add or rename counts when its signer
//!    had an add that counts among the links it saw, and no counted revocation of its signer missed it. A revocation
//!    is dropped when its signer had no counting add among the links it saw, or had been revoked there; repeat.
//! 3. Revoked: the subjects of the revocations left. Authorized: subjects of adds that count, unless revoked.
//!
//! A chain holds at most 128 links, so a set of link indexes is one `u128`.

use std::collections::HashMap;

use super::link::{ChainLink, LinkKind};
use super::{ChainDevice, DeviceState};

pub(crate) type Set = u128;

pub(crate) fn has(set: Set, index: usize) -> bool {
    set & (1u128 << index) != 0
}

fn indexes(set: Set) -> impl Iterator<Item = usize> {
    (0..128).filter(move |i| has(set, *i))
}

/// Whether `device`'s authority came from `origin` through adds `revocation` did not see.
fn derives_unseen(
    device: &[u8; 32],
    origin: &[u8; 32],
    revocation: usize,
    links: &[ChainLink],
    ancestors: &[Set],
) -> bool {
    let mut reached = vec![*device];
    let mut frontier = vec![*device];
    while let Some(current) = frontier.pop() {
        if &current == origin {
            return true;
        }
        for (a, add) in links.iter().enumerate() {
            if add.kind != LinkKind::Add || add.subject != current {
                continue;
            }
            if a == revocation || has(ancestors[revocation], a) {
                continue;
            }
            if !reached.contains(&add.signer) {
                reached.push(add.signer);
                frontier.push(add.signer);
            }
        }
    }
    false
}

fn statically_counted_revocations(links: &[ChainLink], ancestors: &[Set]) -> Set {
    let mut counted = 0;
    for (r, revocation) in links.iter().enumerate() {
        if revocation.kind != LinkKind::Revoke {
            continue;
        }
        let mut voided = false;
        for (o, other) in links.iter().enumerate() {
            if voided {
                break;
            }
            if o == r || other.kind != LinkKind::Revoke {
                continue;
            }
            if other.subject != revocation.signer || has(ancestors[o], r) {
                continue;
            }
            voided = !derives_unseen(&other.signer, &revocation.subject, r, links, ancestors);
        }
        if !voided {
            counted |= 1 << r;
        }
    }
    counted
}

fn had_counted_add(signer: &[u8; 32], seen: Set, links: &[ChainLink], effective: Set) -> bool {
    indexes(seen).any(|a| {
        let add = &links[a];
        has(effective, a) && !matches!(add.kind, LinkKind::Revoke | LinkKind::Rename) && &add.subject == signer
    })
}

fn effective_links(links: &[ChainLink], ancestors: &[Set], revocations: Set) -> Set {
    let mut effective: Set = 0;
    for (i, link) in links.iter().enumerate() {
        if link.kind == LinkKind::Genesis {
            effective |= 1 << i;
            continue;
        }
        if link.kind == LinkKind::Revoke || !had_counted_add(&link.signer, ancestors[i], links, effective) {
            continue;
        }
        let missed = indexes(revocations).any(|r| links[r].subject == link.signer && !has(ancestors[r], i));
        if !missed {
            effective |= 1 << i;
        }
    }
    effective
}

fn revocation_stands(r: usize, links: &[ChainLink], ancestors: &[Set], revocations: Set, effective: Set) -> bool {
    let revocation = &links[r];
    if !had_counted_add(&revocation.signer, ancestors[r], links, effective) {
        return false;
    }
    !indexes(ancestors[r]).any(|earlier| has(revocations, earlier) && links[earlier].subject == revocation.signer)
}

/// One that saw the other is later, whatever the clocks say; concurrent renames fall to the clock, then the hash.
fn is_later(links: &[ChainLink], ancestors: &[Set], a: usize, b: usize) -> bool {
    if has(ancestors[a], b) {
        return true;
    }
    if has(ancestors[b], a) {
        return false;
    }
    if links[a].milliseconds != links[b].milliseconds {
        return links[a].milliseconds > links[b].milliseconds;
    }
    links[a].hash > links[b].hash
}

fn devices(
    links: &[ChainLink],
    ancestors: &[Set],
    effective: Set,
    revocations: Set,
    root: &[u8; 32],
) -> Vec<ChainDevice> {
    let mut order: Vec<[u8; 32]> = Vec::new();
    let mut first_add: HashMap<[u8; 32], usize> = HashMap::new();
    let mut counted_add: HashMap<[u8; 32], usize> = HashMap::new();
    let mut label: HashMap<[u8; 32], usize> = HashMap::new();
    let mut revoked_at: HashMap<[u8; 32], f64> = HashMap::new();
    for (i, link) in links.iter().enumerate() {
        let subject = link.subject;
        let counts = has(effective, i);
        if link.kind == LinkKind::Revoke {
            if has(revocations, i) {
                let date = link.date();
                revoked_at.entry(subject).and_modify(|d| *d = d.min(date)).or_insert(date);
            }
            continue;
        }
        if link.kind != LinkKind::Rename && !first_add.contains_key(&subject) {
            first_add.insert(subject, i);
            order.push(subject);
        }
        if counts && link.kind != LinkKind::Rename {
            counted_add.entry(subject).or_insert(i);
        }
        if counts && label.get(&subject).is_none_or(|&held| is_later(links, ancestors, i, held)) {
            label.insert(subject, i);
        }
    }
    order
        .into_iter()
        .map(|key| {
            let first = &links[first_add[&key]];
            let added = counted_add.get(&key).map_or(first, |&i| &links[i]);
            let named = label.get(&key).map_or(added, |&i| &links[i]);
            let state = if revoked_at.contains_key(&key) {
                DeviceState::Revoked
            } else if counted_add.contains_key(&key) {
                DeviceState::Authorized
            } else {
                DeviceState::Void
            };
            ChainDevice {
                device_key: key,
                static_key: first.static_key.expect("an add carries a static key"),
                name: named.name.clone().unwrap_or_default(),
                system: named.system.clone().unwrap_or_default(),
                added_at: added.date(),
                revoked_at: revoked_at.get(&key).copied(),
                state,
                is_root: &key == root,
            }
        })
        .collect()
}

/// The devices under the rules, for `links` in an order where parents come first, `ancestors[i]` every ancestor of
/// link i.
pub(crate) fn apply(links: &[ChainLink], ancestors: &[Set], root: &[u8; 32]) -> Vec<ChainDevice> {
    let mut revocations = statically_counted_revocations(links, ancestors);
    let mut effective;
    loop {
        effective = effective_links(links, ancestors, revocations);
        let dropped: Set = indexes(revocations)
            .filter(|&r| !revocation_stands(r, links, ancestors, revocations, effective))
            .fold(0, |set, r| set | (1 << r));
        if dropped == 0 {
            break;
        }
        revocations &= !dropped;
    }
    devices(links, ancestors, effective, revocations, root)
}

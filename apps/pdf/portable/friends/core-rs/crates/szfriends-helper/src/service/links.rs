//! Download links in the Rust helper (`SZFriendsLinkService.m`, PROTOCOL.md § Links): `make_download_link` and
//! `revoke_link`, what the online thread serves (the shelf), the tombstones the host is told, and the sweep of links
//! that expired. A link serves the file from where it is, while its size, dates and identity still hold (where none
//! of the platform's copy-on-write clones are made); the SHA-256 decides when only the change time moved.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};
use szfriends_core::intents::{FileRef, IntentError};
use szfriends_core::presentation::{Audience, SnapshotBuilder};

use szfriends_core::store::{
    link_file_hashes, link_tombstone_hash, unix_now, DownloadLinkRecord, SourceStamp, StoreError,
};
use szfriends_online::links::{DownloadLink, LinkFiles, Tombstone};

use super::{Input, State};
use crate::server::Reply;

/// How often links past their expiry are let go.
const SWEEP_SECONDS: f64 = 60.0;

/// What the online thread serves, kept up to date by the service's thread.
#[derive(Clone, Debug, Default)]
pub struct LinkShelf {
    links: Arc<Mutex<Vec<DownloadLink>>>,
    stamps: Arc<Mutex<HashMap<[u8; 16], SourceStamp>>>,
    tombstones: Arc<Mutex<Vec<Tombstone>>>,
}

impl LinkFiles for LinkShelf {
    fn links(&self) -> Vec<DownloadLink> {
        self.links.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn changed(&self, link: &DownloadLink) -> bool {
        let Some(recorded) = self.stamps.lock().unwrap_or_else(|e| e.into_inner()).get(&link.link_id).copied() else {
            return true;
        };
        let Ok(now) = SourceStamp::of(&link.path) else { return true };
        if now.size != recorded.size || now.mtime_ns != recorded.mtime_ns {
            return true;
        }
        // Only the change time or the file's identity moved (a copy over it, a metadata change): the bytes decide.
        now != recorded && link_file_hashes(&link.path).map_or(true, |(_, sha256, _)| sha256 != link.sha256)
    }

    fn tombstones(&self) -> Vec<Tombstone> {
        self.tombstones.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

fn served(record: &DownloadLinkRecord, sender_name: &str, friends_id: &str) -> Option<DownloadLink> {
    let path = record.snapshot_path.as_ref().or(record.source_path.as_ref())?;
    Some(DownloadLink {
        link_id: record.link_id,
        secret: record.secret,
        path: PathBuf::from(path),
        name: record.file_name.clone(),
        size: record.size,
        sha256: record.sha256,
        blake2b: record.blake2b,
        media_type: record.uniform_type.clone().unwrap_or_else(|| "application/octet-stream".into()),
        expires: record.expires_at,
        sender_name: sender_name.to_owned(),
        sender_friends_id: friends_id.to_owned(),
        thumbnail: record.thumbnail_png.clone(),
    })
}

/// The page's URL for a link: the host's link origin, `/d#`, and the version byte, id and secret in base64url.
fn link_url(origin: &str, record: &DownloadLinkRecord) -> String {
    let mut payload = vec![1u8];
    payload.extend_from_slice(&record.link_id);
    payload.extend_from_slice(&record.secret);
    format!("{origin}/d#{}", szfriends_online::b64::encode_url(&payload))
}

fn tombstones_of(state: &State) -> Vec<Tombstone> {
    let ended = state.store.link_tombstones(unix_now());
    ended
        .into_iter()
        .map(|t| Tombstone { hash: t.link_hash, reason: t.reason.as_str().into(), until: t.until })
        .collect()
}

impl State {
    /// The shelf from the store: every link held, the stamps they were made with, the tombstones.
    pub(crate) fn refresh_links(&mut self) {
        let profile = self.profile_facts();
        let (name, friends_id) = (profile.name.unwrap_or_default(), profile.friends_id);
        let records = self.store.download_links();
        let links: Vec<DownloadLink> = records.iter().filter_map(|r| served(r, &name, &friends_id)).collect();
        let stamps = records.iter().map(|r| (r.link_id, SourceStamp::of_record(r))).collect();
        *self.links.links.lock().unwrap_or_else(|e| e.into_inner()) = links;
        *self.links.stamps.lock().unwrap_or_else(|e| e.into_inner()) = stamps;
        *self.links.tombstones.lock().unwrap_or_else(|e| e.into_inner()) = tombstones_of(self);
    }

    /// Hashes the file off the service's thread, then saves the link and answers with its URL.
    pub(crate) fn make_download_link(&mut self, file: FileRef, days: u32, audience: Audience, reply: Reply) {
        let Some(origin) = self.online.as_ref().filter(|o| o.is_available()).and_then(|o| o.link_origin()) else {
            return reply.error("unavailable", None, json!({}));
        };
        let input = self.input.clone();
        let spawned = std::thread::Builder::new().name("szfriends-link-hash".into()).spawn(move || {
            let path = PathBuf::from(&file.path);
            let read = SourceStamp::of(&path).and_then(|stamp| Ok((stamp, link_file_hashes(&path)?)));
            let done = move |state: &mut State| match read {
                Ok((stamp, (size, sha256, blake2b))) if size == stamp.size => {
                    let name = file.display_name.clone().filter(|n| !n.is_empty());
                    let name = name.or_else(|| path.file_name().map(|n| n.to_string_lossy().into_owned()));
                    let record = new_record(&path, name.unwrap_or_default(), stamp, sha256, blake2b, days);
                    state.save_link(record, &origin, audience, reply);
                }
                // The file moved while it was read, or cannot be read: the same refusal as a file that is gone.
                _ => reply.error("file_unreadable", None, json!({})),
            };
            let _ = input.send(Input::Deferred(Box::new(done)));
        });
        if spawned.is_err() {
            // The reply went with the closure; the client hears `internal` when it is dropped.
        }
    }

    fn save_link(&mut self, record: DownloadLinkRecord, origin: &str, audience: Audience, reply: Reply) {
        match self.store.save_download_link(&record, unix_now()) {
            Ok(()) => {}
            Err(StoreError::Constraint) => return reply.error("too_many_links", None, json!({})),
            Err(_) => return reply.error("internal", None, json!({})),
        }
        self.refresh_links();
        if let Some(online) = &self.online {
            online.register_links();
        }
        let message = SnapshotBuilder::new(audience, None).download_link_made_message(record.expires_at);
        let id = szfriends_online::b64::encode_url(&record.link_id);
        reply.ok(json!({ "url": link_url(origin, &record), "link_id": id, "message": message }));
        self.changed();
    }

    /// Ends one link at once: its tombstone goes to the host before the link is let go there.
    pub(crate) fn revoke_link(&mut self, link_id: &[u8; 16]) -> Result<Value, IntentError> {
        match self.store.remove_download_link(link_id, unix_now()) {
            Ok(_) => {}
            Err(StoreError::NotFound) => return Err(IntentError::new("not_found")),
            Err(_) => return Err(IntentError::new("internal")),
        }
        self.refresh_links();
        let hash = link_tombstone_hash(link_id);
        let ended: Vec<Tombstone> = tombstones_of(self).into_iter().filter(|t| t.hash == hash).collect();
        if let Some(online) = &self.online {
            online.end_link(*link_id, ended);
        }
        self.changed();
        Ok(json!({}))
    }

    /// A finished download counts on the link's row.
    pub(crate) fn link_downloaded(&mut self, link_id: &[u8; 16]) {
        if self.store.count_download_of_link(link_id).is_ok() {
            self.refresh_links();
            self.changed();
        }
    }

    /// Links past their expiry go, and the host hears why (once a minute at most).
    pub(crate) fn sweep_links(&mut self) {
        let now = unix_now();
        if now < self.links_swept_at + SWEEP_SECONDS {
            return;
        }
        self.links_swept_at = now;
        let Ok(expired) = self.store.remove_download_links_expired(now) else { return };
        if expired.is_empty() {
            return;
        }
        self.refresh_links();
        let hashes: Vec<[u8; 32]> = expired.iter().map(|l| link_tombstone_hash(&l.link_id)).collect();
        let ended: Vec<Tombstone> = tombstones_of(self).into_iter().filter(|t| hashes.contains(&t.hash)).collect();
        if let Some(online) = &self.online {
            online.send_tombstones(ended);
        }
        self.changed();
    }
}

fn new_record(
    path: &std::path::Path,
    name: String,
    stamp: SourceStamp,
    sha256: [u8; 32],
    blake2b: [u8; 32],
    days: u32,
) -> DownloadLinkRecord {
    let (mut link_id, mut secret) = ([0u8; 16], [0u8; 32]);
    szfriends_core::crypto::random_bytes(&mut link_id);
    szfriends_core::crypto::random_bytes(&mut secret);
    let now = unix_now();
    DownloadLinkRecord {
        link_id,
        secret,
        file_name: name,
        uniform_type: None,
        size: stamp.size,
        sha256,
        blake2b,
        snapshot_path: None,
        source_path: Some(path.to_string_lossy().into_owned()),
        source_mtime_ns: stamp.mtime_ns,
        source_ctime_ns: stamp.ctime_ns,
        source_inode: stamp.inode,
        source_device: stamp.device,
        thumbnail_png: None,
        created_at: now,
        expires_at: now + f64::from(days) * 86_400.0,
        downloads: 0,
    }
}

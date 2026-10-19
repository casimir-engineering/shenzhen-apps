//! Download links in the store (`SZFriendsStoreLinks.m`): saved up to the host's limit, counted, revoked and expired
//! into tombstones kept 31 days and at most 500, in the helper's own `link_tombstones` encoding; and a source's stamp.

use std::path::PathBuf;

use szfriends_core::store::links::{LINK_TOMBSTONES_MAX, LINK_TOMBSTONE_LIFETIME};
use szfriends_core::store::{
    link_file_hashes, link_tombstone_hash, DownloadLinkRecord, EndReason, SourceStamp, Store, StoreError,
    DOWNLOAD_LINKS_MAX,
};

struct Scratch(PathBuf);

impl Scratch {
    fn new(label: &str) -> Self {
        let mut random = [0u8; 8];
        szfriends_core::crypto::random_bytes(&mut random);
        let dir = std::env::temp_dir().join(format!("szf-links-{label}-{}", hex::encode(random)));
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn link(n: u16, now: f64, expires_in: f64) -> DownloadLinkRecord {
    let mut link_id = [0u8; 16];
    link_id[..2].copy_from_slice(&n.to_be_bytes());
    DownloadLinkRecord {
        link_id,
        secret: [7; 32],
        file_name: format!("file {n}.pdf"),
        uniform_type: None,
        size: 5,
        sha256: [1; 32],
        blake2b: [2; 32],
        snapshot_path: None,
        source_path: Some("/files/a.pdf".into()),
        source_mtime_ns: 1,
        source_ctime_ns: 2,
        source_inode: 3,
        source_device: 4,
        thumbnail_png: None,
        created_at: now,
        expires_at: now + expires_in,
        downloads: 0,
    }
}

#[test]
fn links_are_saved_counted_revoked_and_expired_into_tombstones() {
    let scratch = Scratch::new("store");
    let mut store = Store::open(scratch.0.join("state")).unwrap();
    let now = 1_800_000_000.0;
    for n in 0..DOWNLOAD_LINKS_MAX as u16 {
        store.save_download_link(&link(n, now, 3600.0 + f64::from(n)), now).unwrap();
    }
    assert_eq!(store.save_download_link(&link(999, now, 3600.0), now), Err(StoreError::Constraint), "the host's limit");
    store.count_download_of_link(&link(3, now, 0.0).link_id).unwrap();
    assert_eq!(store.download_link(&link(3, now, 0.0).link_id).unwrap().downloads, 1);
    let revoked = store.remove_download_link(&link(1, now, 0.0).link_id, now).unwrap();
    assert_eq!(revoked.file_name, "file 1.pdf");
    assert_eq!(store.remove_download_link(&link(1, now, 0.0).link_id, now), Err(StoreError::NotFound));
    let later = now + 3600.0 + 10.5;
    let expired = store.remove_download_links_expired(later).unwrap();
    assert_eq!(expired.len(), 10, "the ten that expired by then (the revoked one is gone already)");
    assert_eq!(store.download_links().len(), DOWNLOAD_LINKS_MAX - 11);
    let tombstones = store.link_tombstones(later);
    assert_eq!(tombstones.len(), 11);
    let first = tombstones.iter().find(|t| t.link_hash == link_tombstone_hash(&revoked.link_id)).unwrap();
    assert_eq!((first.reason, first.until), (EndReason::Revoked, (now + LINK_TOMBSTONE_LIFETIME).floor()));
    let gone = link(0, now, 3600.0);
    let second = tombstones.iter().find(|t| t.link_hash == link_tombstone_hash(&gone.link_id)).unwrap();
    assert_eq!((second.reason, second.until), (EndReason::Expired, gone.expires_at + LINK_TOMBSTONE_LIFETIME));
    assert!(store.link_tombstones(now + 40.0 * 86_400.0).is_empty(), "31 days, then gone");
    // The blob is the helper's: 41 bytes each.
    let blob: Vec<u8> = store
        .connection()
        .query_row("SELECT value FROM settings WHERE key = 'link_tombstones'", [], |r| r.get(0))
        .unwrap();
    assert_eq!(blob.len(), 11 * 41);
    assert_eq!(blob[10 * 41 + 32], 1, "latest end first: the revoked one, ending soonest, last");
}

#[test]
fn tombstones_keep_the_latest_five_hundred() {
    let scratch = Scratch::new("max");
    let mut store = Store::open(scratch.0.join("state")).unwrap();
    let now = 1_800_000_000.0;
    for round in 0..11u16 {
        for n in 0..DOWNLOAD_LINKS_MAX as u16 {
            store.save_download_link(&link(round * 100 + n, now, 60.0 + f64::from(round)), now).unwrap();
        }
        store.remove_download_links_expired(now + 61.0 + f64::from(round)).unwrap();
    }
    assert_eq!(store.link_tombstones(now).len(), LINK_TOMBSTONES_MAX);
}

#[test]
fn a_source_stamp_and_its_hashes() {
    let scratch = Scratch::new("stamp");
    let path = scratch.0.join("a.pdf");
    std::fs::write(&path, b"hello").unwrap();
    let stamp = SourceStamp::of(&path).unwrap();
    assert_eq!(stamp.size, 5);
    assert_eq!(SourceStamp::of(&path).unwrap(), stamp);
    let (size, sha256, blake2b) = link_file_hashes(&path).unwrap();
    assert_eq!(size, 5);
    assert_eq!(hex::encode(sha256), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
    assert_eq!(blake2b, szfriends_core::crypto::blake2b::<32>(None, &[b"hello"]));
    assert!(SourceStamp::of(&scratch.0).is_err(), "a folder is no file");
}

//! Download links (`SZFriendsStoreLinks.m`, PROTOCOL.md § Links): each link this person made, with what it serves (a
//! snapshot in the state directory, or the original while its size, dates and identity still hold), and the
//! tombstones of links that ended: the link id's hash and why, for 31 days, at most 500, in the `link_tombstones`
//! setting as the helper keeps them (32-byte hash, reason 1 revoked or 2 expired, until as u64 big-endian seconds).

use rusqlite::{params, Connection, OptionalExtension, Row};
use sha2::{Digest, Sha256};

use super::{Result, Store, StoreError};

/// The Friends host's limit on live download links per identity (`too_many_links`).
pub const DOWNLOAD_LINKS_MAX: usize = 50;
pub const LINK_TOMBSTONE_LIFETIME: f64 = 31.0 * 86_400.0;
pub const LINK_TOMBSTONES_MAX: usize = 500;
pub const LINK_THUMBNAIL_MAX_BYTES: usize = 48_000;
const TOMBSTONES_KEY: &str = "link_tombstones";
const TOMBSTONE_BYTES: usize = 41;
const COLUMNS: &str = "link_id, secret, file_name, uniform_type, size, sha256, blake2b, snapshot_path, source_path, \
                       source_mtime_ns, source_ctime_ns, source_inode, source_device, thumbnail_png, created_at, \
                       expires_at, downloads";

/// One download link as the store holds it.
#[derive(Clone, Debug, PartialEq)]
pub struct DownloadLinkRecord {
    pub link_id: [u8; 16],
    pub secret: [u8; 32],
    pub file_name: String,
    pub uniform_type: Option<String>,
    pub size: u64,
    pub sha256: [u8; 32],
    pub blake2b: [u8; 32],
    /// A copy in the state directory, or (exactly one of the two) the original and what identifies its bytes.
    pub snapshot_path: Option<String>,
    pub source_path: Option<String>,
    pub source_mtime_ns: i64,
    pub source_ctime_ns: i64,
    pub source_inode: u64,
    pub source_device: i64,
    pub thumbnail_png: Option<Vec<u8>>,
    pub created_at: f64,
    pub expires_at: f64,
    pub downloads: u64,
}

/// Why a link ended, as the host tells whoever opens it afterwards.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EndReason {
    Revoked,
    Expired,
}

impl EndReason {
    pub fn as_str(self) -> &'static str {
        match self {
            EndReason::Revoked => "revoked",
            EndReason::Expired => "expired",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct LinkTombstone {
    pub link_hash: [u8; 32],
    pub reason: EndReason,
    pub until: f64,
}

/// `SZFriendsLinkTombstoneHash`: SHA-256 of "SZFriends link tombstone v1" and the link id.
pub fn link_tombstone_hash(link_id: &[u8; 16]) -> [u8; 32] {
    Sha256::new().chain_update(b"SZFriends link tombstone v1").chain_update(link_id).finalize().into()
}

fn fixed<const N: usize>(bytes: Vec<u8>) -> rusqlite::Result<[u8; N]> {
    bytes.try_into().map_err(|_| rusqlite::Error::InvalidQuery)
}

fn row(row: &Row) -> rusqlite::Result<DownloadLinkRecord> {
    Ok(DownloadLinkRecord {
        link_id: fixed(row.get(0)?)?,
        secret: fixed(row.get(1)?)?,
        file_name: row.get(2)?,
        uniform_type: row.get(3)?,
        size: row.get::<_, i64>(4)?.max(0) as u64,
        sha256: fixed(row.get(5)?)?,
        blake2b: fixed(row.get(6)?)?,
        snapshot_path: row.get(7)?,
        source_path: row.get(8)?,
        source_mtime_ns: row.get::<_, Option<i64>>(9)?.unwrap_or(0),
        source_ctime_ns: row.get::<_, Option<i64>>(10)?.unwrap_or(0),
        source_inode: row.get::<_, Option<i64>>(11)?.unwrap_or(0) as u64,
        source_device: row.get::<_, Option<i64>>(12)?.unwrap_or(0),
        thumbnail_png: row.get(13)?,
        created_at: row.get(14)?,
        expires_at: row.get(15)?,
        downloads: row.get::<_, i64>(16)?.max(0) as u64,
    })
}

fn rows(conn: &Connection, tail: &str, binds: impl rusqlite::Params) -> Result<Vec<DownloadLinkRecord>> {
    let mut statement = conn.prepare(&format!("SELECT {COLUMNS} FROM links {tail}"))?;
    let found = statement.query_map(binds, row)?.collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(found)
}

fn tombstones_from(blob: Option<Vec<u8>>, now: f64) -> Vec<LinkTombstone> {
    let blob = blob.unwrap_or_default();
    blob.chunks_exact(TOMBSTONE_BYTES)
        .map(|record| LinkTombstone {
            link_hash: record[..32].try_into().expect("32 bytes"),
            reason: if record[32] == 1 { EndReason::Revoked } else { EndReason::Expired },
            until: u64::from_be_bytes(record[33..41].try_into().expect("8 bytes")) as f64,
        })
        .filter(|t| t.until > now)
        .collect()
}

fn tombstone_blob(conn: &Connection) -> Option<Vec<u8>> {
    conn.query_row("SELECT value FROM settings WHERE key = ?1", [TOMBSTONES_KEY], |r| r.get::<_, Vec<u8>>(0))
        .optional()
        .ok()
        .flatten()
}

/// Adds tombstones inside the caller's transaction, dropping those past their time and, beyond the maximum, those
/// ending soonest.
fn add_tombstones(conn: &Connection, ended: &[(&DownloadLinkRecord, f64)], reason: EndReason, now: f64) -> Result<()> {
    if ended.is_empty() {
        return Ok(());
    }
    let mut list = tombstones_from(tombstone_blob(conn), now);
    for (link, until) in ended {
        if *until > now {
            list.push(LinkTombstone { link_hash: link_tombstone_hash(&link.link_id), reason, until: *until });
        }
    }
    list.sort_by(|a, b| b.until.total_cmp(&a.until));
    let mut out = Vec::with_capacity(list.len().min(LINK_TOMBSTONES_MAX) * TOMBSTONE_BYTES);
    for tombstone in list.iter().take(LINK_TOMBSTONES_MAX) {
        out.extend_from_slice(&tombstone.link_hash);
        out.push(if tombstone.reason == EndReason::Revoked { 1 } else { 2 });
        out.extend_from_slice(&(tombstone.until.max(0.0).floor() as u64).to_be_bytes());
    }
    conn.execute(
        "INSERT INTO settings (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![TOMBSTONES_KEY, out],
    )?;
    Ok(())
}

fn valid(link: &DownloadLinkRecord) -> bool {
    let one_source = link.snapshot_path.as_deref().is_some_and(|p| !p.is_empty())
        != link.source_path.as_deref().is_some_and(|p| !p.is_empty());
    !link.file_name.is_empty()
        && one_source
        && link.size <= i64::MAX as u64
        && link.thumbnail_png.as_ref().is_none_or(|t| !t.is_empty() && t.len() <= LINK_THUMBNAIL_MAX_BYTES)
}

impl Store {
    /// Saves a new link; `Constraint` while [`DOWNLOAD_LINKS_MAX`] links are live.
    pub fn save_download_link(&mut self, link: &DownloadLinkRecord, now: f64) -> Result<()> {
        if !valid(link) {
            return Err(StoreError::Invalid("malformed download link"));
        }
        self.write(|conn| {
            let live: i64 = conn.query_row("SELECT count(*) FROM links WHERE expires_at > ?1", [now], |r| r.get(0))?;
            if live as usize >= DOWNLOAD_LINKS_MAX {
                return Err(StoreError::Constraint);
            }
            conn.execute(
                &format!("INSERT INTO links ({COLUMNS}) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"),
                params![
                    link.link_id.to_vec(),
                    link.secret.to_vec(),
                    link.file_name,
                    link.uniform_type,
                    link.size as i64,
                    link.sha256.to_vec(),
                    link.blake2b.to_vec(),
                    link.snapshot_path,
                    link.source_path,
                    link.source_mtime_ns,
                    link.source_ctime_ns,
                    link.source_inode as i64,
                    link.source_device,
                    link.thumbnail_png,
                    link.created_at,
                    link.expires_at,
                    link.downloads as i64,
                ],
            )?;
            Ok(())
        })
    }

    pub fn download_link(&self, link_id: &[u8; 16]) -> Option<DownloadLinkRecord> {
        rows(&self.conn, "WHERE link_id = ?1", [link_id.to_vec()]).ok()?.into_iter().next()
    }

    /// Every link, newest first.
    pub fn download_links(&self) -> Vec<DownloadLinkRecord> {
        rows(&self.conn, "ORDER BY created_at DESC, link_id", []).unwrap_or_default()
    }

    /// Revoke: the link goes, and its tombstone stays 31 days from now.
    pub fn remove_download_link(&mut self, link_id: &[u8; 16], now: f64) -> Result<DownloadLinkRecord> {
        self.write(|conn| {
            let removed = rows(conn, "WHERE link_id = ?1", [link_id.to_vec()])?.into_iter().next();
            let removed = removed.ok_or(StoreError::NotFound)?;
            conn.execute("DELETE FROM links WHERE link_id = ?1", [link_id.to_vec()])?;
            add_tombstones(conn, &[(&removed, now + LINK_TOMBSTONE_LIFETIME)], EndReason::Revoked, now)?;
            Ok(removed)
        })
    }

    /// Links past their expiry go, each leaving a tombstone 31 days past its expiry.
    pub fn remove_download_links_expired(&mut self, now: f64) -> Result<Vec<DownloadLinkRecord>> {
        self.write(|conn| {
            let removed = rows(conn, "WHERE expires_at <= ?1", [now])?;
            if !removed.is_empty() {
                conn.execute("DELETE FROM links WHERE expires_at <= ?1", [now])?;
                let ended: Vec<_> = removed.iter().map(|l| (l, l.expires_at + LINK_TOMBSTONE_LIFETIME)).collect();
                add_tombstones(conn, &ended, EndReason::Expired, now)?;
            }
            Ok(removed)
        })
    }

    pub fn link_tombstones(&self, now: f64) -> Vec<LinkTombstone> {
        tombstones_from(tombstone_blob(&self.conn), now)
    }

    pub fn count_download_of_link(&mut self, link_id: &[u8; 16]) -> Result<()> {
        self.write(|conn| {
            match conn.execute("UPDATE links SET downloads = downloads + 1 WHERE link_id = ?1", [link_id.to_vec()])? {
                1 => Ok(()),
                _ => Err(StoreError::NotFound),
            }
        })
    }
}

/// What identifies the bytes of a file served from where it is: its size and modification time, and on Unix its
/// change time, inode and device. A link records it when made and serves the file only while it still holds.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SourceStamp {
    pub size: u64,
    pub mtime_ns: i64,
    pub ctime_ns: i64,
    pub inode: u64,
    pub device: i64,
}

impl SourceStamp {
    /// A regular file's stamp (not a link, not a folder).
    pub fn of(path: &std::path::Path) -> std::io::Result<Self> {
        let metadata = std::fs::symlink_metadata(path)?;
        if !metadata.is_file() {
            return Err(std::io::Error::other("not a regular file"));
        }
        let mtime_ns = metadata
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map_or(0, |d| i64::try_from(d.as_nanos()).unwrap_or(i64::MAX));
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            let ctime_ns = metadata.ctime().saturating_mul(1_000_000_000).saturating_add(metadata.ctime_nsec());
            Ok(Self { size: metadata.len(), mtime_ns, ctime_ns, inode: metadata.ino(), device: metadata.dev() as i64 })
        }
        #[cfg(not(unix))]
        Ok(Self { size: metadata.len(), mtime_ns, ..Self::default() })
    }

    pub fn of_record(link: &DownloadLinkRecord) -> Self {
        Self {
            size: link.size,
            mtime_ns: link.source_mtime_ns,
            ctime_ns: link.source_ctime_ns,
            inode: link.source_inode,
            device: link.source_device,
        }
    }
}

/// A file's size, SHA-256 and BLAKE2b-256, read once.
pub fn link_file_hashes(path: &std::path::Path) -> std::io::Result<(u64, [u8; 32], [u8; 32])> {
    use blake2::digest::{Update, VariableOutput};
    use std::io::Read;
    let mut file = std::fs::File::open(path)?;
    let (mut sha, mut blake) = (Sha256::new(), blake2::Blake2bVar::new(32).expect("32-byte output"));
    let (mut buffer, mut size) = (vec![0u8; 1 << 16], 0u64);
    loop {
        let got = file.read(&mut buffer)?;
        if got == 0 {
            break;
        }
        Digest::update(&mut sha, &buffer[..got]);
        blake.update(&buffer[..got]);
        size += got as u64;
    }
    let mut blake2b = [0u8; 32];
    blake.finalize_variable(&mut blake2b).map_err(|_| std::io::Error::other("digest"))?;
    Ok((size, sha.finalize().into(), blake2b))
}

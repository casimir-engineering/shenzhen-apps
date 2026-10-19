//! A download link's file over its data channel, the opener's side (`SZFriendsLinkDownload` in
//! `SZFriendsLinkTransfer.m`; PROTOCOL.md § Links, Browser downloads): the metadata record, then chunks in order while
//! this side grants credit, each hashed as it arrives; the last bytes reach the sink only once the whole file's SHA-256
//! matches the metadata. What a dropped connection had received carries over into the next one.

use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use szfriends_online::b64;
use szfriends_online::links::wire::{open_record, record_type, seal_record, CHUNK_BYTES};
use szfriends_online::transport::StreamWriter;
use zeroize::Zeroizing;

use super::{LinkMetadata, Outcome, SinkEvent};

/// Chunks granted ahead, and how often the grant moves.
const CREDIT_WINDOW: u64 = 64;
const CREDIT_STEP: u64 = 16;
const NAME_MAX: usize = 255;
const SIZE_MAX: u64 = (1 << 53) - 1;

/// What one download has received, kept across the connections that carry it.
#[derive(Clone, Debug, Default)]
pub struct Progress {
    pub metadata: Option<LinkMetadata>,
    /// The next chunk's index: the first not yet received.
    pub next: u64,
    pub received: u64,
    hash: Sha256,
}

/// What a record did to the download.
#[derive(Debug, PartialEq, Eq)]
pub enum Step {
    Continue,
    Ended(Outcome),
}

/// One connection's part of a download.
pub struct Download {
    writer: StreamWriter,
    key: Zeroizing<[u8; 32]>,
    controls: u64,
    metadata_here: bool,
    /// The file was asked for on this connection: from now on a drop counts as lost, to be carried on.
    pub started: bool,
}

impl std::fmt::Debug for Download {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Download").field("started", &self.started).finish()
    }
}

/// The metadata record's plaintext: u32be JSON length, the JSON, then a thumbnail this side does not keep.
pub fn parse_metadata(plain: &[u8]) -> Option<LinkMetadata> {
    let length = u32::from_be_bytes(plain.get(..4)?.try_into().ok()?) as usize;
    let json: Value = serde_json::from_slice(plain.get(4..4 + length)?).ok()?;
    let name = json.get("name")?.as_str().filter(|n| (1..=NAME_MAX).contains(&n.chars().count()))?;
    let size = json.get("size")?.as_u64().filter(|s| *s <= SIZE_MAX)?;
    let sha256 = b64::decode_array::<32>(json.get("sha256"))?;
    let text = |key: &str| json.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
    let from = json.get("from").and_then(|from| {
        let key = b64::decode_array::<32>(from.get("identity_key"))?;
        let friends_id = from.get("friends_id")?.as_str()?.to_owned();
        let blake2b = b64::decode_array::<32>(from.get("blake2b"))?;
        let signature = b64::decode_array::<64>(from.get("sig"))?;
        Some((key, friends_id, blake2b, signature))
    });
    Some(LinkMetadata {
        name: name.to_owned(),
        size,
        sha256,
        media_type: text("type"),
        sender_name: text("sender"),
        from,
    })
}

impl Download {
    pub fn new(writer: StreamWriter, key: Zeroizing<[u8; 32]>) -> Self {
        Self { writer, key, controls: 0, metadata_here: false, started: false }
    }

    fn control(&mut self, message: Value) {
        let plain = message.to_string();
        if let Some(record) = seal_record(&self.key, record_type::CONTROL, self.controls, plain.as_bytes()) {
            self.controls += 1;
            self.writer.write_message(&record);
        }
    }

    /// The channel goes a moment after the last control record (done, cancel) left on it.
    pub fn close(&self) {
        self.writer.drain(std::time::Duration::from_millis(500));
        self.writer.close();
    }

    /// Nothing more is wanted: the sender stops at once.
    pub fn cancel(&mut self) {
        self.control(json!({ "t": "cancel" }));
    }

    /// One record from the sender.
    pub fn record(&mut self, progress: &mut Progress, record: &[u8], sink: &dyn Fn(SinkEvent)) -> Step {
        if record.first() == Some(&record_type::END) {
            let end = open_record(&self.key, &[record_type::END], 0, record)
                .and_then(|(_, plain)| serde_json::from_slice::<Value>(&plain).ok());
            let reason = end.as_ref().and_then(|e| e.get("reason")).and_then(Value::as_str);
            return Step::Ended(match (end.is_some(), reason) {
                (false, _) => Outcome::Failed,
                (true, Some("changed")) => Outcome::Changed,
                (true, _) => Outcome::Ended,
            });
        }
        if !self.metadata_here {
            self.metadata_here = true;
            let opened = open_record(&self.key, &[record_type::METADATA], 0, record);
            let Some(metadata) = opened.and_then(|(_, plain)| parse_metadata(&plain)) else {
                return Step::Ended(Outcome::Failed);
            };
            match &progress.metadata {
                // Carrying on: the same file, or nothing.
                Some(earlier) if earlier.size != metadata.size || earlier.sha256 != metadata.sha256 => {
                    return Step::Ended(Outcome::Failed);
                }
                Some(_) => {
                    let next = progress.next;
                    self.control(json!({ "t": "start", "from": next, "upto": next + CREDIT_WINDOW }));
                }
                None => {
                    progress.metadata = Some(metadata.clone());
                    sink(SinkEvent::Metadata(Box::new(metadata)));
                    self.control(json!({ "t": "start", "upto": CREDIT_WINDOW }));
                }
            }
            self.started = true;
            return Step::Continue;
        }
        let size = progress.metadata.as_ref().map_or(0, |m| m.size);
        let kinds = [record_type::CHUNK, record_type::FINAL];
        let Some((kind, plain)) = open_record(&self.key, &kinds, progress.next, record) else {
            return Step::Ended(Outcome::Failed);
        };
        let last = kind == record_type::FINAL;
        let after = progress.received + plain.len() as u64;
        let fits =
            plain.len() <= CHUNK_BYTES && if last { after == size } else { plain.len() == CHUNK_BYTES && after < size };
        if !fits {
            return Step::Ended(Outcome::Failed);
        }
        let offset = progress.received;
        progress.received = after;
        progress.next += 1;
        progress.hash.update(&plain);
        if last {
            let digest: [u8; 32] = progress.hash.clone().finalize().into();
            if Some(digest) != progress.metadata.as_ref().map(|m| m.sha256) {
                return Step::Ended(Outcome::Failed);
            }
            sink(SinkEvent::Bytes { offset, data: plain });
            sink(SinkEvent::Finished);
            self.control(json!({ "t": "done", "ok": true }));
            return Step::Ended(Outcome::Done);
        }
        sink(SinkEvent::Bytes { offset, data: plain });
        if progress.next % CREDIT_STEP == 0 {
            let upto = progress.next + CREDIT_WINDOW;
            self.control(json!({ "t": "credit", "upto": upto }));
        }
        Step::Continue
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metadata_with_and_without_who_sent_it() {
        let json = json!({"name": "Site photos.pdf", "size": 3, "sha256": b64::encode_url(&[1; 32]),
            "type": "application/pdf", "sender": "Mei",
            "from": {"identity_key": b64::encode_url(&[2; 32]), "friends_id": "brave-otter",
                     "blake2b": b64::encode_url(&[3; 32]), "sig": b64::encode_url(&[4; 64])}})
        .to_string();
        let mut plain = (json.len() as u32).to_be_bytes().to_vec();
        plain.extend_from_slice(json.as_bytes());
        plain.extend_from_slice(b"\x89PNG");
        let metadata = parse_metadata(&plain).unwrap();
        assert_eq!(
            (metadata.name.as_str(), metadata.size, metadata.sender_name.as_str()),
            ("Site photos.pdf", 3, "Mei")
        );
        assert_eq!(metadata.from, Some(([2; 32], "brave-otter".into(), [3; 32], [4; 64])));
        assert!(parse_metadata(&plain[..10]).is_none(), "cut short");
        let nameless = json!({"name": "", "size": 3, "sha256": b64::encode_url(&[1; 32])}).to_string();
        let mut plain = (nameless.len() as u32).to_be_bytes().to_vec();
        plain.extend_from_slice(nameless.as_bytes());
        assert!(parse_metadata(&plain).is_none(), "a name is required");
    }
}

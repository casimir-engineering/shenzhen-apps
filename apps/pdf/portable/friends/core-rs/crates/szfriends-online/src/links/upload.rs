//! A download link's file over its data channel, the sender's side (`SZFriendsLinkTransfer.m`): the metadata record
//! first, then chunks only while the opener's credit allows, so neither side holds more than the window whatever the
//! file's size. A start with "from" carries on from that chunk: the bytes before it are hashed again, so the final
//! chunk goes only when everything the opener holds is the file the link was made for. Runs on a thread of its own.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::Value;
use sha2::{Digest, Sha256};
use szfriends_identity::Identity;
use zeroize::Zeroizing;

use super::wire::{open_record, record_type, seal_record, Metadata, CHUNK_BYTES, CREDIT_MAX};
use super::{DownloadLink, LinkEvent};
use crate::transport::{ChannelStream, StreamInput};

const SENDER_DOMAIN: &str = "SZFriends link sender v1";
/// How long the opener may take to say start before the channel is let go.
const START_TIMEOUT: Duration = Duration::from_secs(15 * 60);

/// The metadata record for `link`, with "from" signed by this identity.
pub fn metadata(identity: &Identity, link: &DownloadLink) -> Metadata {
    let texts = [link.name.as_str(), link.sender_friends_id.as_str(), link.sender_name.as_str()];
    let signed = Metadata::signed_bytes(&link.link_id, &link.sha256, &link.blake2b, link.size, texts);
    let signature = identity.sign(&signed, SENDER_DOMAIN);
    Metadata {
        name: link.name.clone(),
        size: link.size,
        media_type: link.media_type.clone(),
        sha256: link.sha256,
        sender: link.sender_name.clone(),
        thumbnail: link.thumbnail.clone(),
        from: Some((identity.public_key(), link.sender_friends_id.clone(), link.blake2b, signature)),
    }
}

pub fn spawn(
    stream: ChannelStream,
    link: DownloadLink,
    metadata: Metadata,
    key: Zeroizing<[u8; 32]>,
    finished: Arc<Mutex<Vec<LinkEvent>>>,
    on_end: Box<dyn FnOnce() + Send>,
) {
    let spawned = std::thread::Builder::new().name("szfriends-link-upload".into()).spawn(move || {
        let id = link.link_id;
        let downloaded =
            Upload { stream: &stream, link, key, next: 0, credit: 0, controls: 0, hash: Sha256::new() }.run(&metadata);
        stream.writer.close();
        if downloaded {
            finished.lock().unwrap_or_else(|e| e.into_inner()).push(LinkEvent::Downloaded(id));
        }
        on_end();
    });
    let _ = spawned;
}

struct Upload<'a> {
    stream: &'a ChannelStream,
    link: DownloadLink,
    key: Zeroizing<[u8; 32]>,
    next: u64,
    credit: u64,
    controls: u64,
    hash: Sha256,
}

impl Upload<'_> {
    fn chunks(&self) -> u64 {
        self.link.size.div_ceil(CHUNK_BYTES as u64).max(1)
    }

    /// `true` when the opener said the download completed.
    fn run(mut self, metadata: &Metadata) -> bool {
        let Ok(mut file) = File::open(&self.link.path) else {
            self.end("changed");
            return false;
        };
        let Some(plain) = metadata.record_plaintext() else { return false };
        let Some(record) = seal_record(&self.key, record_type::METADATA, 0, &plain) else { return false };
        if !self.stream.writer.write_message(&record) {
            return false;
        }
        let mut started = false;
        let mut sent_final = false;
        loop {
            // Send what the credit allows, reading the opener's controls between chunks.
            while started && !sent_final && self.next < self.credit {
                match self.chunk(&mut file) {
                    Some(true) => sent_final = true,
                    Some(false) => {}
                    None => return false,
                }
                while let Ok(input) = self.stream.incoming.try_recv() {
                    match self.control(input, &mut file, &mut started, sent_final) {
                        Control::Continue => {}
                        Control::Done(ok) => return ok,
                    }
                }
            }
            let wait = if started { Duration::from_secs(60) } else { START_TIMEOUT };
            let Ok(input) = self.stream.incoming.recv_timeout(wait) else { return false };
            match self.control(input, &mut file, &mut started, sent_final) {
                Control::Continue => {}
                Control::Done(ok) => return ok,
            }
        }
    }

    fn control(&mut self, input: StreamInput, file: &mut File, started: &mut bool, sent_final: bool) -> Control {
        let StreamInput::Data(record) = input else { return Control::Done(false) };
        let opened = open_record(&self.key, &[record_type::CONTROL], self.controls, &record);
        let Some(message) = opened.and_then(|(_, plain)| serde_json::from_slice::<Value>(&plain).ok()) else {
            return Control::Done(false); // anything else from the opener breaks the exchange
        };
        self.controls += 1;
        let kind = message.get("t").and_then(Value::as_str).unwrap_or("");
        let upto = message.get("upto").and_then(Value::as_u64);
        match (kind, upto) {
            ("start" | "credit", Some(upto)) => {
                if kind == "start" && !*started {
                    if let Some(from) = message.get("from") {
                        if !self.resume_from(from, file) {
                            return Control::Done(false);
                        }
                    }
                }
                // Never more than the window the opener could possibly have asked for, whatever it says.
                self.credit = self.credit.max(upto.min(self.next + CREDIT_MAX));
                *started = true;
                Control::Continue
            }
            ("done", _) => Control::Done(message.get("ok") == Some(&Value::Bool(true)) && sent_final),
            ("cancel", _) => Control::Done(false),
            _ => Control::Continue,
        }
    }

    /// A start that carries on from chunk `from`: the bytes before it are hashed again.
    fn resume_from(&mut self, from: &Value, file: &mut File) -> bool {
        let Some(first) = from.as_u64().filter(|f| *f < self.chunks()) else { return false };
        if first == 0 {
            return true;
        }
        self.next = first;
        let mut remaining = first * CHUNK_BYTES as u64;
        let mut buffer = vec![0u8; 1 << 20];
        if file.seek(SeekFrom::Start(0)).is_err() {
            return false;
        }
        while remaining > 0 {
            let want = remaining.min(buffer.len() as u64) as usize;
            if file.read_exact(&mut buffer[..want]).is_err() {
                self.end("changed");
                return false;
            }
            self.hash.update(&buffer[..want]);
            remaining -= want as u64;
        }
        true
    }

    /// One chunk: `Some(true)` for the final one, `None` when the exchange ends.
    fn chunk(&mut self, file: &mut File) -> Option<bool> {
        let offset = self.next * CHUNK_BYTES as u64;
        let left = self.link.size.saturating_sub(offset);
        let is_final = left <= CHUNK_BYTES as u64;
        let mut bytes = vec![0u8; left.min(CHUNK_BYTES as u64) as usize];
        if file.seek(SeekFrom::Start(offset)).is_err() || file.read_exact(&mut bytes).is_err() {
            self.end("changed"); // shorter than when the link was made
            return None;
        }
        self.hash.update(&bytes);
        if is_final {
            // The last bytes go only when everything sent is the file the link was made for.
            let digest: [u8; 32] = std::mem::take(&mut self.hash).finalize().into();
            if digest != self.link.sha256 {
                self.end("changed");
                return None;
            }
        }
        let kind = if is_final { record_type::FINAL } else { record_type::CHUNK };
        let record = seal_record(&self.key, kind, self.next, &bytes)?;
        if !self.stream.writer.write_message(&record) {
            return None;
        }
        self.next += 1;
        Some(is_final)
    }

    fn end(&self, reason: &str) {
        let plain = serde_json::json!({ "reason": reason }).to_string();
        if let Some(record) = seal_record(&self.key, record_type::END, 0, plain.as_bytes()) {
            self.stream.writer.write_message(&record);
        }
    }
}

enum Control {
    Continue,
    Done(bool),
}

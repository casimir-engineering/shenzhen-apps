//! Opening a download link from an app (`SZFriendsLinkOpening.m`, the opener's side of `SZFriendsLinkSetup.m`;
//! PROTOCOL.md § Links, Browser downloads): the same exchange the link page runs, through a guest connection of its own
//! to the Friends host (`/v1?guest=1`, HOST-PROTOCOL-ONLINE.md § Download links), then the file over a data channel,
//! direct first and through the relay when no channel opens within 12 seconds. A download whose connection drops
//! carries on over a new setup from the first chunk not yet received, and gives up after 3 drops in a row that brought
//! nothing new. Runs on a thread of its own; what arrives goes to the sink, which files it in the store.

mod attempt;
mod download;
mod setup;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use download::Progress;

/// Who sent a link: their identity key, Friends ID, the file's BLAKE2b and the signature over them.
pub type Sender = ([u8; 32], String, [u8; 32], [u8; 64]);

/// What the sender's metadata says, and who signed it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LinkMetadata {
    pub name: String,
    pub size: u64,
    pub sha256: [u8; 32],
    pub media_type: String,
    pub sender_name: String,
    pub from: Option<Sender>,
}

/// How an opening ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The whole file arrived and its SHA-256 matched.
    Done,
    /// Nobody answered: the sender's computer is not connected, or nobody holds the link.
    Unavailable,
    /// The sender said the link was revoked or expired, or the host knew it ended.
    Ended,
    /// The sender's file changed after the link was made.
    Changed,
    /// No path opened, or what arrived did not check.
    Failed,
}

/// What reaches the sink, in order: the metadata once, the bytes at their offsets, then the end.
#[derive(Debug)]
pub enum SinkEvent {
    Metadata(Box<LinkMetadata>),
    Bytes {
        offset: u64,
        data: Vec<u8>,
    },
    /// Every byte arrived and the SHA-256 matched.
    Finished,
    /// It stopped before that; whatever arrived is to be thrown away.
    Stopped(Outcome),
}

pub type Sink = Box<dyn Fn(SinkEvent) + Send>;

/// The Friends host a guest connection goes to.
#[derive(Clone, Debug)]
pub struct GuestHost {
    /// The host's WebSocket URL from the signed list (`wss://…/v1`, or `ws://` on loopback in tests).
    pub url: String,
    /// Its `stun:` URIs from the signed list.
    pub stun: Vec<String>,
    /// Tests: the PEM certificates a `wss://` test host chains to.
    pub roots: Option<Vec<u8>>,
    /// Tests: peer connections on 127.0.0.1 only.
    pub loopback: bool,
}

/// Drops in a row that brought nothing new before the download gives up.
const RESUMES_WITHOUT_PROGRESS: u32 = 3;

/// Starts opening the link `link_id` with `secret`; `false` when no thread could be made. Setting `abort` stops it
/// (the sink refused something); the sink hears `Stopped` unless the file arrived whole.
pub fn spawn(link_id: [u8; 16], secret: [u8; 32], host: GuestHost, sink: Sink, abort: Arc<AtomicBool>) -> bool {
    let spawned = std::thread::Builder::new().name("szfriends-link-open".into()).spawn(move || {
        let outcome = run(link_id, &secret, &host, &sink, &abort);
        if outcome != Outcome::Done {
            sink(SinkEvent::Stopped(outcome));
        }
    });
    spawned.is_ok()
}

fn run(link_id: [u8; 16], secret: &[u8; 32], host: &GuestHost, sink: &Sink, abort: &AtomicBool) -> Outcome {
    let mut progress = Progress::default();
    let (mut stalls, mut resumed_at) = (0, 0);
    let mut generation = 0;
    loop {
        if abort.load(Ordering::SeqCst) {
            return Outcome::Failed;
        }
        generation += 1;
        match setup::Setup::new(link_id, secret, host, generation).run(&mut progress, sink, abort) {
            setup::Ended::Outcome(outcome) => return outcome,
            setup::Ended::Lost => {
                stalls = if progress.next > resumed_at { 0 } else { stalls + 1 };
                resumed_at = progress.next;
                if stalls >= RESUMES_WITHOUT_PROGRESS {
                    return Outcome::Failed;
                }
            }
        }
    }
}

//! One file pulled from every device that holds it at once (ADR 0018 § 9.6), in the Rust helper: Get again from a
//! friend's devices (AGAIN 4 and 5), and a copy from the person's own devices (SYNC 7 and 8) together with the friend
//! who sent the file. WP6's planner (`transfer::pull`) gives each holder blocks by its measured speed; this file asks
//! for them, takes what arrives into one copy by blocks (`transfer::block_copy`, which resumes from its map after a
//! cut or a restart), and drops a holder that leaves, whose blocks the others then serve.
//!
//! Holders must hold the same file: each serves only after checking its bytes against the file's digest (a stale
//! version is answered NONE), and one whose tree differs from the copy's is not asked again. Only on sessions that
//! negotiated fast transfers, and only while copies go by blocks (`State::copies_by_blocks`); otherwise the
//! requesters of `again.rs` and the sync exchange copy as before, from one holder.

use std::collections::BTreeMap;
use std::time::Duration;

use szfriends_core::session::monotonic_now;
use szfriends_core::store::sync_files::SyncFile;
use szfriends_core::sync::{AgainFile, AgainMessage};
use szfriends_core::transfer::block_copy::{map_of, BlockCopy, CopyPart};
use szfriends_core::transfer::copies::CopyMessage;
use szfriends_core::transfer::pull::{Pull, PullAction};
use szfriends_core::transfer::scheduler::Config;
use szfriends_core::transfer::{frames, Geometry};
use szfriends_core::wire::{tag, Frame, FrameType, RouteMethod};

use super::{hex, State};

/// What a pull copies: a file a friend sent (Get again), or one of the person's files another device holds.
#[derive(Debug, Clone)]
pub enum Origin {
    Again(AgainFile),
    Own(SyncFile),
}

/// How a holder is asked.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Via {
    Again,
    Sync,
}

#[derive(Debug)]
struct Holder {
    via: Via,
    route: RouteMethod,
    /// Its BLOCKS FOLLOW named the copy's tree: it serves.
    up: bool,
    /// It answered NONE, or its tree is not the copy's: not asked again in this pull.
    out: bool,
    /// Blocks it completed.
    delivered: u32,
}

#[derive(Debug)]
pub struct PullCopy {
    pub transfer_id: String,
    origin: Origin,
    copy: BlockCopy,
    pull: Option<Pull>,
    root: Option<([u8; 32], u8)>,
    holders: BTreeMap<u64, Holder>,
    /// Blocks asked of a holder before the planner knew the tree, one each, so every holder sends its tree.
    probes: u32,
}

/// The pull running now (one file at a time, as the requesters copy).
#[derive(Debug, Default)]
pub struct PullArea {
    pub current: Option<PullCopy>,
    /// Files no holder could give just now, and when they may be tried again.
    not_before: BTreeMap<String, std::time::Instant>,
    /// When a running background copy last looked for a Get again waiting behind it.
    checked_at: Option<std::time::Instant>,
}

/// How often a copy running by itself looks for a Get again the person asked for meanwhile.
const PREEMPT_CHECK: Duration = Duration::from_millis(250);

/// What runs now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Running {
    /// Get again, or a copy the person asked for with Get.
    Asked,
    /// A copy between own devices that runs by itself.
    Background,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Decision {
    Keep,
    /// The background copy steps aside for a Get again the person asked for.
    Preempt,
    StartAgain,
    StartOwn,
}

/// The order people wait in: a Get again they asked for first, then copies from their own devices (asked for before
/// those that copy by themselves, which `files_wanted` already orders); a Get again asked while a copy runs by
/// itself pre-empts it. `own` is `Some(asked)` when an own-device copy waits.
fn decide(running: Option<Running>, again_waiting: bool, own: Option<bool>) -> Decision {
    match running {
        Some(Running::Background) if again_waiting => Decision::Preempt,
        Some(_) => Decision::Keep,
        None if again_waiting => Decision::StartAgain,
        None if own.is_some() => Decision::StartOwn,
        None => Decision::Keep,
    }
}

/// A file no holder could give is tried again after this long.
const NOT_NOW: Duration = Duration::from_secs(5);
/// A copy from the person's own devices asks the friend who sent the file too from this size: every file, now that
/// both helpers free a friend's one-file-at-a-time slot as soon as a copy by blocks is acknowledged (WP4).
const FRIEND_HELPS_FROM: u64 = 0;

impl Origin {
    fn transfer_id(&self) -> &str {
        match self {
            Self::Again(f) => &f.transfer_id,
            Self::Own(f) => &f.transfer_id,
        }
    }

    fn size_digest(&self) -> (u64, Option<[u8; 32]>) {
        match self {
            Self::Again(f) => (f.size, f.digest.clone().try_into().ok()),
            Self::Own(f) => (f.size, f.digest.clone().try_into().ok()),
        }
    }

    /// The friend who sent it, when they can give it again (a file the person received, not one they sent; for a
    /// copy from the person's own devices, only a large one).
    fn friend_conversation(&self) -> Option<&str> {
        match self {
            Self::Again(f) => Some(&f.conversation_id),
            Self::Own(f) => (!f.outgoing && f.size >= FRIEND_HELPS_FROM).then_some(f.conversation_id.as_str()),
        }
    }
}

impl State {
    /// Whether copies on this session are the pull's to make (fast transfers and copies by blocks).
    pub(crate) fn pulls_copies(&self, id: u64) -> bool {
        self.copies_by_blocks && self.fast_session(id)
    }

    /// Starts the next pull when none runs, and asks every holder that can serve it now.
    pub(crate) fn reconsider_pulls(&mut self) {
        if !self.copies_by_blocks {
            return;
        }
        self.preempt_for_asked();
        if self.pulls.current.is_none() {
            self.start_pull();
        }
        self.attach_holders();
        self.drive_pull();
    }

    /// What could be pulled now, by who waits on it: a Get again the person asked a friend for, and the first copy
    /// from the person's own devices (asked for with Get, or copying by itself).
    fn candidates(&mut self) -> (Option<AgainFile>, Option<(SyncFile, bool)>) {
        let now = std::time::Instant::now();
        self.pulls.not_before.retain(|_, at| *at > now);
        let waiting = |id: &str| self.pulls.not_before.contains_key(id);
        let ids: Vec<u64> = self.sessions.map.keys().copied().collect();
        let again = ids.into_iter().filter(|id| self.pulls_copies(*id)).find_map(|id| {
            let conversation = self.again_session_conversation(id)?;
            AgainFile::asked(&self.store, &conversation).into_iter().find(|f| !waiting(&f.transfer_id))
        });
        let own = self.devices.engine.files_wanted(&self.store).into_iter().find(|file| {
            !waiting(&file.transfer_id)
                && self
                    .devices
                    .exchanges
                    .iter()
                    .any(|(id, e)| self.pulls_copies(*id) && file.holders.contains(e.peer_key()))
        });
        let own = own.map(|file| {
            let asked = self.devices.engine.is_file_requested(&self.store, &file.transfer_id);
            (file, asked)
        });
        (again, own)
    }

    /// A Get again the person asked for, waiting behind a copy that runs by itself: the copy steps aside (what
    /// arrived stays in its map, its holders stop) and is pulled again afterwards. Looked at four times a second.
    fn preempt_for_asked(&mut self) {
        let Some(current) = self.pulls.current.as_ref() else { return };
        let running = match &current.origin {
            Origin::Own(file) if !self.devices.engine.is_file_requested(&self.store, &file.transfer_id) => {
                Running::Background
            }
            _ => Running::Asked,
        };
        let now = std::time::Instant::now();
        // Only a copy running by itself can step aside; the lookup it needs runs at most four times a second.
        if running == Running::Asked || self.pulls.checked_at.is_some_and(|at| now.duration_since(at) < PREEMPT_CHECK) {
            return;
        }
        self.pulls.checked_at = Some(now);
        let (again, _) = self.candidates();
        if decide(Some(running), again.is_some(), None) != Decision::Preempt {
            return;
        }
        let Some(current) = self.pulls.current.take() else { return };
        if let Some(wire) = super::unhex(&current.transfer_id) {
            let blocks = Geometry::new(current.copy_size(), current.copy.shift()).map_or(1, |g| g.blocks);
            for (holder, state) in &current.holders {
                if !state.out {
                    for frame in frames::have(&wire, &[(0, blocks)], &[]) {
                        self.send_on(*holder, &frame);
                    }
                }
            }
        }
        current.copy.pause();
        self.changed();
    }

    fn start_pull(&mut self) {
        let (again, own) = self.candidates();
        let asked_own = own.as_ref().map(|(_, asked)| *asked);
        let origin = match decide(None, again.is_some(), asked_own) {
            Decision::StartAgain => again.map(Origin::Again),
            Decision::StartOwn => own.map(|(file, _)| Origin::Own(file)),
            Decision::Keep | Decision::Preempt => None,
        };
        let Some(origin) = origin else { return };
        let (size, Some(digest)) = origin.size_digest() else { return };
        let again_path = self.devices.engine.again_partial_path(origin.transfer_id());
        let Some(partial) = again_path.parent().map(std::path::Path::to_path_buf) else { return };
        if std::fs::create_dir_all(&partial).is_err() {
            return;
        }
        let path = partial.join(format!("pull-{}", origin.transfer_id()));
        let Ok(copy) = BlockCopy::open(size, digest, path.clone(), map_of(&path)) else { return };
        self.pulls.current = Some(PullCopy {
            transfer_id: origin.transfer_id().to_owned(),
            origin,
            copy,
            pull: None,
            root: None,
            holders: BTreeMap::new(),
            probes: 0,
        });
    }

    /// Every live session that can serve the file and is not asked yet gets its first WANT BLOCKS: one block, so it
    /// answers with its tree.
    fn attach_holders(&mut self) {
        let Some(current) = self.pulls.current.as_ref() else { return };
        let mut found: Vec<(u64, Via)> = Vec::new();
        if let Origin::Own(file) = &current.origin {
            for (id, exchange) in &self.devices.exchanges {
                if self.pulls_copies(*id) && file.holders.contains(exchange.peer_key()) {
                    found.push((*id, Via::Sync));
                }
            }
        }
        if let Some(friend) = current.origin.friend_conversation().map(str::to_owned) {
            let ids: Vec<u64> = self.sessions.map.keys().copied().collect();
            for id in ids {
                if self.pulls_copies(id) && self.again_session_conversation(id).as_deref() == Some(friend.as_str()) {
                    found.push((id, Via::Again));
                }
            }
        }
        for (id, via) in found {
            let Some(current) = self.pulls.current.as_mut() else { return };
            if current.holders.contains_key(&id) {
                continue;
            }
            let route = self.sessions.map.get(&id).map_or(RouteMethod::Lan, |s| s.meta.race_route(&s.channel));
            let missing = current.copy.missing();
            let probe = nth_block(&missing, current.probes).unwrap_or(0);
            current.probes += 1;
            current.holders.insert(id, Holder { via, route, up: false, out: false, delivered: 0 });
            let shift = current.copy.shift();
            let transfer = current.transfer_id.clone();
            self.ask_holder(id, via, &transfer, shift, vec![(probe, 1)]);
        }
    }

    fn ask_holder(&mut self, id: u64, via: Via, transfer: &str, shift: u8, ranges: Vec<(u32, u32)>) {
        let message = CopyMessage::WantBlocks { id: transfer.to_owned(), shift, ranges };
        let frame = match via {
            Via::Again => message.encode_again().map(|m| Frame::new(FrameType::Again).with(tag::AGAIN, m)),
            Via::Sync => message.encode_sync().map(|m| Frame::new(FrameType::Sync).with(tag::SYNC, m)),
        };
        if let Some(frame) = frame {
            self.send_on(id, &frame);
        }
    }

    /// The planner's decisions, sent: WANT BLOCKS to the holders it gave blocks, HAVE to those it took them from.
    fn drive_pull(&mut self) {
        let now = monotonic_now();
        let Some(current) = self.pulls.current.as_mut() else { return };
        let Some(pull) = current.pull.as_mut() else { return };
        pull.tick(now);
        let actions = pull.take_actions();
        let (transfer, shift) = (current.transfer_id.clone(), current.copy.shift());
        for action in actions {
            match action {
                PullAction::Want { source, ranges } => {
                    let via = self.pulls.current.as_ref().and_then(|c| c.holders.get(&source)).map(|h| h.via);
                    if let Some(via) = via {
                        self.ask_holder(source, via, &transfer, shift, ranges);
                    }
                }
                PullAction::Have { source, ranges } => {
                    if let Some(wire) = super::unhex(&transfer) {
                        for frame in frames::have(&wire, &ranges, &[]) {
                            self.send_on(source, &frame);
                        }
                    }
                }
            }
        }
    }
}

impl PullCopy {
    fn copy_size(&self) -> u64 {
        self.origin.size_digest().0
    }
}

/// The `n`th block of `ranges` (wrapping), so each holder's first ask is a different block.
fn nth_block(ranges: &[(u32, u32)], n: u32) -> Option<u32> {
    let total: u64 = ranges.iter().map(|(_, c)| u64::from(*c)).sum();
    if total == 0 {
        return None;
    }
    let mut left = u64::from(n) % total;
    for &(first, count) in ranges {
        if left < u64::from(count) {
            return Some(first + left as u32);
        }
        left -= u64::from(count);
    }
    None
}

/// A holder's answer to a pull.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PullAnswer {
    /// BLOCKS FOLLOW: its tree.
    Follow([u8; 32], u8),
    /// NONE: it does not have the file (or not this version of it).
    Gone,
    /// NONE "not now".
    NotNow,
}

/// AGAIN messages of a pull.
pub(crate) fn again_pull_message(message: &AgainMessage) -> Option<(String, PullAnswer)> {
    match message {
        AgainMessage::BlocksFollow { id, root, shift } => Some((id.clone(), PullAnswer::Follow(*root, *shift))),
        AgainMessage::None { id, reason: 0 } => Some((id.clone(), PullAnswer::Gone)),
        AgainMessage::None { id, .. } => Some((id.clone(), PullAnswer::NotNow)),
        _ => None,
    }
}

/// SYNC messages of a pull: BLOCKS FOLLOW (8) or NONE (6).
pub(crate) fn sync_pull_message(message: &[u8]) -> Option<(String, PullAnswer)> {
    if let Some(CopyMessage::BlocksFollow { id, root, shift }) = CopyMessage::decode_sync(message) {
        return Some((id, PullAnswer::Follow(root, shift)));
    }
    let (&kind, rest) = message.split_first()?;
    let (&length, rest) = rest.split_first()?;
    (kind == 6 && rest.len() == usize::from(length))
        .then(|| (String::from_utf8_lossy(rest).into_owned(), PullAnswer::Gone))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_get_again_the_person_asked_for_goes_before_copies_waiting_in_line() {
        // A copy between own devices waits in line, then the person asks a friend for a file again: Get again starts.
        assert_eq!(decide(None, true, Some(false)), Decision::StartAgain);
        assert_eq!(decide(None, true, Some(true)), Decision::StartAgain);
        assert_eq!(decide(None, false, Some(false)), Decision::StartOwn);
        // A copy running by itself steps aside for it; one the person asked for (Get) or a Get again runs on.
        assert_eq!(decide(Some(Running::Background), true, Some(false)), Decision::Preempt);
        assert_eq!(decide(Some(Running::Asked), true, Some(false)), Decision::Keep);
        assert_eq!(decide(Some(Running::Background), false, Some(false)), Decision::Keep);
        assert_eq!(decide(None, false, None), Decision::Keep);
    }
}

#[path = "pulls_answers.rs"]
mod answers;

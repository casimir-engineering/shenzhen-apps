//! A pull's holders answering (pulls.rs): their trees and refusals, the parts they send, a pull that completes or
//! gives up, and what the rows show meanwhile.

use super::*;

impl State {
    /// AGAIN or SYNC messages for the file being pulled: BLOCKS FOLLOW (a holder's tree) or NONE (it cannot serve).
    /// `true` when it was one.
    pub(crate) fn pull_message(&mut self, id: u64, transfer: &str, answer: PullAnswer) -> bool {
        let Some(current) = self.pulls.current.as_mut().filter(|c| c.transfer_id == transfer) else { return false };
        let Some(holder) = current.holders.get_mut(&id) else { return false };
        current.heard_at = std::time::Instant::now();
        let now = monotonic_now();
        let follow = match answer {
            PullAnswer::Follow(root, shift) => Some((root, shift)),
            PullAnswer::Gone | PullAnswer::NotNow => None,
        };
        match follow {
            None => {
                holder.out = true;
                // The friend who sent it no longer has it: Get again ends, as from one holder.
                if holder.via == Via::Again && answer == PullAnswer::Gone {
                    if let Origin::Again(_) = current.origin {
                        let _ = szfriends_core::sync::set_again_state(
                            &self.store,
                            transfer,
                            szfriends_core::presentation::AgainState::Gone,
                        );
                        if let Some(current) = self.pulls.current.take() {
                            current.copy.discard();
                        }
                        self.changed();
                        self.reconsider_pulls();
                        return true;
                    }
                }
                if let Some(pull) = current.pull.as_mut() {
                    pull.source_down(id, now);
                }
                if current.holders.values().all(|h| h.out) {
                    self.pull_gives_up();
                    return true;
                }
            }
            Some((root, shift)) => {
                if current.root.is_none() && current.copy.follow(root, shift) {
                    current.root = Some((root, shift));
                }
                if current.root == Some((root, shift)) {
                    holder.up = true;
                    let route = holder.route;
                    if let Some(pull) = current.pull.as_mut() {
                        pull.source_up(id, route, now);
                    }
                } else {
                    holder.out = true; // another tree: not this file
                }
            }
        }
        self.pull_progressed();
        true
    }

    /// HASHES and PART frames for the file being pulled; `true` when they were.
    pub(crate) fn pull_frame(&mut self, id: u64, frame: &Frame) -> bool {
        let Some(transfer) = frame.get(tag::ID).map(hex) else { return false };
        let Some(current) = self.pulls.current.as_mut().filter(|c| c.transfer_id == transfer) else { return false };
        if !current.holders.get(&id).is_some_and(|h| h.up && !h.out) {
            let state = current.holders.get(&id).map(|h| (h.up, h.out));
            crate::log!(
                "pull {}: {:?} from #{id} left aside (holder up/out {state:?})",
                &transfer[..transfer.len().min(8)],
                frame.frame_type
            );
            return false;
        }
        current.heard_at = std::time::Instant::now();
        let now = monotonic_now();
        if let Some(pull) = current.pull.as_mut() {
            pull.heard(id, now);
        }
        match frame.frame_type {
            FrameType::Hashes => {
                let (index, hashes) = (frame.integer(tag::INDEX).unwrap_or(0) as u32, frame.get(tag::HASHES));
                match current.copy.hashes(index, hashes.unwrap_or_default()) {
                    None => {
                        current.holders.get_mut(&id).expect("checked").out = true;
                        if let Some(pull) = current.pull.as_mut() {
                            pull.source_down(id, now);
                        }
                    }
                    // Done now, or known already: a resumed copy's map holds its leaves, so its HASHES add nothing
                    // and answer "not done", and without this its pull never got a planner and asked one block at a
                    // time, a probe each, for ever (the own-device copy stall, 2026-11-28).
                    Some(done) if current.pull.is_none() && (done || current.copy.leaves_known()) => {
                        // The tree is known: the planner starts with what is missing and every holder that serves it.
                        let (_, shift) = current.root.expect("followed");
                        let Some(geometry) = Geometry::new(current.copy_size(), shift) else { return true };
                        let missing = current.copy.missing();
                        let mut pull = Pull::new(geometry, &missing, Config::default(), now);
                        let mut serving = 0;
                        for (holder, state) in current.holders.iter().filter(|(_, h)| h.up && !h.out) {
                            pull.source_up(*holder, state.route, now);
                            serving += 1;
                        }
                        crate::log!(
                            "pull {}: tree known, {} blocks missing, {serving} holders serving",
                            &current.transfer_id[..current.transfer_id.len().min(8)],
                            missing.iter().map(|r| u64::from(r.1)).sum::<u64>()
                        );
                        current.pull = Some(pull);
                    }
                    Some(_) => {}
                }
            }
            FrameType::Part => {
                let (offset, data) =
                    (frame.integer(tag::OFFSET).unwrap_or(0), frame.get(tag::DATA).unwrap_or_default());
                let part = current.copy.part(offset, data);
                let since = current.logged.0.elapsed().as_secs_f64();
                if since >= 2.0 {
                    let received = current.copy.received_bytes();
                    crate::log!(
                        "pull {} after {:.1} s: {:.1} MB of {:.1} MB here ({:.2} MB/s lately), {} WANTs for {} blocks",
                        &current.transfer_id[..current.transfer_id.len().min(8)],
                        current.started.elapsed().as_secs_f64(),
                        received as f64 / 1e6,
                        current.copy.size() as f64 / 1e6,
                        received.saturating_sub(current.logged.1) as f64 / 1e6 / since,
                        current.wants,
                        current.asked_blocks
                    );
                    current.logged = (std::time::Instant::now(), received);
                }
                match part {
                    CopyPart::Written(block) => {
                        current.holders.get_mut(&id).expect("checked").delivered += 1;
                        if let Some(pull) = current.pull.as_mut() {
                            pull.arrived(id, block, now);
                        }
                        // The holder's own window moves on its HAVE.
                        for frame in frames::have(frame.get(tag::ID).unwrap_or_default(), &[(block, 1)], &[]) {
                            self.send_on(id, &frame);
                        }
                    }
                    CopyPart::Corrupt(block) => {
                        if let Some(pull) = current.pull.as_mut() {
                            pull.failed(block, now);
                        }
                    }
                    CopyPart::Complete => {
                        current.holders.get_mut(&id).expect("checked").delivered += 1;
                        let wire = frame.get(tag::ID).unwrap_or_default().to_vec();
                        return self.pull_complete(id, &wire);
                    }
                    CopyPart::Pending | CopyPart::Late | CopyPart::Refused => {}
                }
            }
            _ => return false,
        }
        self.pull_progressed();
        true
    }

    pub(super) fn pull_progressed(&mut self) {
        self.drive_pull();
        self.changed();
    }

    /// Every block is here: the whole file checked against its digest, then kept; every holder hears to stop.
    pub(super) fn pull_complete(&mut self, id: u64, wire: &[u8]) -> bool {
        let Some(current) = self.pulls.current.take() else { return true };
        let blocks = current.pull.as_ref().map_or(1, |p| p.geometry().blocks);
        for (holder, state) in &current.holders {
            if !state.out {
                for frame in frames::have(wire, &[(0, blocks)], &[]) {
                    self.send_on(*holder, &frame);
                }
            }
        }
        let _ = id;
        let transfer = current.transfer_id.clone();
        let shares: Vec<String> = current
            .holders
            .values()
            .map(|h| {
                format!(
                    "{} {}{}",
                    if h.via == Via::Again { "friend" } else { "own device" },
                    h.delivered,
                    if h.out { " (out)" } else { "" }
                )
            })
            .collect();
        let seconds = current.started.elapsed().as_secs_f64().max(0.001);
        let megabytes = current.copy.size() as f64 / 1e6;
        crate::log!(
            "pulled a file from {} holders, blocks each: {}; {megabytes:.1} MB in {seconds:.1} s, {:.2} MB/s",
            current.holders.len(),
            shares.join(", "),
            megabytes / seconds
        );
        match current.copy.finish() {
            Some(path) => {
                let adopted = match &current.origin {
                    Origin::Again(file) => self.devices.engine.adopt_again_file(&self.store, file, &path).is_ok(),
                    Origin::Own(_) => self.devices.engine.adopt_copied_file(&self.store, &transfer, &path).is_ok(),
                };
                if !adopted {
                    crate::log!("a file pulled from its holders could not be kept");
                }
            }
            None => crate::log!("a file pulled from its holders did not check"),
        }
        // A copy of the same file by one holder (a session without fast transfers) has nothing left to do.
        for requester in self.again.requesters.values_mut() {
            requester.stop_copy(&transfer);
        }
        for exchange in self.devices.exchanges.values_mut() {
            exchange.stop_copy(&transfer);
        }
        self.pump_sync();
        self.changed();
        self.reconsider_pulls();
        true
    }

    /// A session ended: a holder of the pull leaves, and its blocks go to the others.
    pub(crate) fn pull_session_closed(&mut self, id: u64) {
        let Some(current) = self.pulls.current.as_mut() else { return };
        if current.holders.remove(&id).is_some() {
            if let Some(pull) = current.pull.as_mut() {
                pull.source_down(id, monotonic_now());
            }
            if current.holders.values().all(|h| h.out) {
                self.pull_gives_up();
            }
        }
        self.drive_pull();
    }

    /// Nobody left to ask: what arrived waits in its map, and the file is tried again later.
    pub(super) fn pull_gives_up(&mut self) {
        if let Some(current) = self.pulls.current.take() {
            self.pulls.not_before.insert(current.transfer_id.clone(), std::time::Instant::now() + NOT_NOW);
            current.copy.pause();
        }
        self.changed();
    }

    /// The pull's timers (silent holders, the endgame).
    pub(crate) fn pull_due(&self) -> Option<Duration> {
        self.pulls.current.as_ref()?.pull.as_ref()?.next_timer()
    }

    /// What the item shows while the pull runs.
    pub(crate) fn pull_fraction(&self, transfer: &str) -> Option<f64> {
        let current = self.pulls.current.as_ref().filter(|c| c.transfer_id == transfer)?;
        let size = current.copy_size();
        Some(if size > 0 { current.copy.received_bytes() as f64 / size as f64 } else { 0.0 })
    }
}

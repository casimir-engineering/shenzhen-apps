//! A pull's holders answering (pulls.rs): their trees and refusals, the parts they send, a pull that completes or
//! gives up, and what the rows show meanwhile.

use super::*;

impl State {
    /// AGAIN or SYNC messages for the file being pulled: BLOCKS FOLLOW (a holder's tree) or NONE (it cannot serve).
    /// `true` when it was one.
    pub(crate) fn pull_message(&mut self, id: u64, transfer: &str, answer: PullAnswer) -> bool {
        let Some(current) = self.pulls.current.as_mut().filter(|c| c.transfer_id == transfer) else { return false };
        let Some(holder) = current.holders.get_mut(&id) else { return false };
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
            return false;
        }
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
                    Some(true) if current.pull.is_none() => {
                        // The tree is known: the planner starts with what is missing and every holder that serves it.
                        let (_, shift) = current.root.expect("followed");
                        let Some(geometry) = Geometry::new(current.copy_size(), shift) else { return true };
                        let mut pull = Pull::new(geometry, &current.copy.missing(), Config::default(), now);
                        for (holder, state) in current.holders.iter().filter(|(_, h)| h.up && !h.out) {
                            pull.source_up(*holder, state.route, now);
                        }
                        current.pull = Some(pull);
                    }
                    Some(_) => {}
                }
            }
            FrameType::Part => {
                let (offset, data) =
                    (frame.integer(tag::OFFSET).unwrap_or(0), frame.get(tag::DATA).unwrap_or_default());
                match current.copy.part(offset, data) {
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
        crate::log!("pulled a file from {} holders, blocks each: {}", current.holders.len(), shares.join(", "));
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

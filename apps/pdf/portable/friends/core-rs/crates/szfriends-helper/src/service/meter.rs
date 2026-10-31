//! Counting what each route carries for each transfer (szfriends-core's `transfer::meter`, PROTOCOL.md § Fast
//! transfers, Progress by route): every PART and CHUNK a session sends or receives, by its transfer and the session's
//! route, and what a snapshot reads of it.

use std::cell::RefCell;

use szfriends_core::presentation::ItemFacts;
use szfriends_core::session::monotonic_now;
use szfriends_core::transfer::RouteMeter;
use szfriends_core::wire::{tag, Frame, FrameType, RouteMethod};

use super::{hex, State};

/// Counts a PART's or a CHUNK's file bytes for its transfer on `route`; any other frame counts nothing.
pub(crate) fn count(meter: &RefCell<RouteMeter>, frame: &Frame, route: RouteMethod) {
    if !matches!(frame.frame_type, FrameType::Part | FrameType::Chunk) {
        return;
    }
    let (Some(id), Some(data)) = (frame.get(tag::ID), frame.get(tag::DATA)) else { return };
    meter.borrow_mut().carried(&hex(id), route, data.len() as u64, monotonic_now().as_secs_f64());
}

impl State {
    /// A transfer's routes, speed and time left as the meter has them, and the computers it comes from at once.
    pub(crate) fn meter_facts(&self, item: &mut ItemFacts, transfer_id: &str) {
        // One of our files going by blocks shows what its receiver acknowledged, not only what the store recorded.
        if item.outgoing && item.state() == szfriends_core::presentation::TransferState::Sending {
            let sends = self.sessions.map.values().filter_map(|s| s.block_senders.get(transfer_id));
            let acknowledged = sends.map(|send| item.file_size.saturating_sub(send.serve.remaining_bytes())).max();
            item.bytes_done = item.bytes_done.max(acknowledged.unwrap_or(0));
        }
        // A copy pulled here (from our other computers, or Get again) counts what the pull has, not the record's.
        let done = match self.pull_fraction(transfer_id) {
            Some(fraction) => (fraction * item.file_size as f64) as u64,
            None => item.bytes_done,
        };
        let remaining = item.file_size.saturating_sub(done);
        let reading = self.meter.borrow_mut().reading(transfer_id, remaining, monotonic_now().as_secs_f64());
        if let Some(reading) = reading {
            let view = Self::view_route;
            item.route_bytes = reading.route_bytes.iter().map(|(r, b)| (view(*r), *b)).collect();
            item.active_routes = reading.active.iter().map(|r| view(*r)).collect();
            if reading.bytes_per_second > 0.0 {
                item.bytes_per_second = reading.bytes_per_second;
            }
            item.seconds_left = reading.seconds_left;
        }
        (item.holders, item.own_holders) = self.pulls.holders(transfer_id);
    }
}

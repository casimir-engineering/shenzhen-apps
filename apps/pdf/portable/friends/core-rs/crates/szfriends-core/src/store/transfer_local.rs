//! What this person does to a transfer on this device: decline an offer, or cancel a transfer in either direction
//! (decline_offer, cancel_transfer). The peer's answers are in `transfers.rs`.

use super::transfers::{apply_event, load, TransferEvent, TransferRecord, TransferState};
use super::{Result, Store, StoreError};

impl Store {
    /// Declines a friend's offer that waits for this person.
    pub fn decline_transfer(&mut self, transfer_id: &str) -> Result<TransferRecord> {
        self.write(|conn| {
            let record = load(conn, transfer_id)?.ok_or(StoreError::NotFound)?;
            if record.outgoing || record.state != TransferState::WaitingForYou {
                return Err(StoreError::Stale);
            }
            apply_event(conn, transfer_id, TransferEvent::Declined, None)?;
            load(conn, transfer_id)?.ok_or(StoreError::NotFound)
        })
    }

    /// Withdraws an offer of ours or stops a transfer still moving, either way; a finished one stays finished.
    pub fn cancel_transfer(&mut self, transfer_id: &str) -> Result<TransferRecord> {
        let record = self.write(|conn| {
            apply_event(conn, transfer_id, TransferEvent::Cancelled, None)?;
            load(conn, transfer_id)?.ok_or(StoreError::NotFound)
        })?;
        if let Some(path) = record.staged_path.as_ref().filter(|_| record.outgoing) {
            let _ = std::fs::remove_file(path);
        }
        Ok(record)
    }
}

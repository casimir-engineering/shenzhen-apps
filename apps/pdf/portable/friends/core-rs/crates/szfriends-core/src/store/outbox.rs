//! The outbox (`SZFriendsOutbox`, brief § Outbox and delivery): everything waiting to reach a friend, and the state
//! machine it moves through. Delivered means the recipient's helper acknowledged after its own commit. Retries are
//! idempotent: each entry keeps its random id and the recipient deduplicates. Nothing waits forever without saying so:
//! an entry unsent 30 days after it was queued (or last retried) fails as "not_delivered_30_days".

use rusqlite::{params, Connection, OptionalExtension, Row};

use super::people::{insert_item, Direction, Item, ItemKind};
use super::transfers::{apply_event as move_transfer, TransferEvent};
use super::{is_valid_identifier, unix_now, Result, Store, StoreError};

pub const OUTBOX_EXPIRY_SECONDS: f64 = 30.0 * 24.0 * 60.0 * 60.0;
pub const FAILURE_NOT_DELIVERED_30_DAYS: &str = "not_delivered_30_days";
pub const FAILURE_REFUSED: &str = "refused";
pub const FAILURE_SOURCE_MISSING: &str = "source_missing";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OutboxState {
    Queued = 0,
    Connecting = 1,
    Sending = 2,
    Delivered = 3,
    Failed = 4,
}

impl OutboxState {
    pub fn from_i64(value: i64) -> Option<Self> {
        [Self::Queued, Self::Connecting, Self::Sending, Self::Delivered, Self::Failed]
            .into_iter()
            .find(|s| *s as i64 == value)
    }

    fn live(self) -> bool {
        matches!(self, Self::Queued | Self::Connecting | Self::Sending)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OutboxKind {
    Request = 0,
    Message = 1,
    /// The item id is the transfer id; the entry moves its transfer.
    Offer = 2,
    Answer = 3,
    PresenceSecret = 4,
}

impl OutboxKind {
    fn from_i64(value: i64) -> Self {
        match value {
            0 => Self::Request,
            1 => Self::Message,
            2 => Self::Offer,
            3 => Self::Answer,
            _ => Self::PresenceSecret,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OutboxEvent {
    RouteAvailable = 0,
    SessionEstablished = 1,
    Written = 2,
    Acknowledged = 3,
    SessionLost = 4,
    Refused = 5,
    SourceMissing = 6,
    Retry = 7,
    Expired = 8,
}

impl OutboxEvent {
    pub const ALL: [Self; 9] = [
        Self::RouteAvailable,
        Self::SessionEstablished,
        Self::Written,
        Self::Acknowledged,
        Self::SessionLost,
        Self::Refused,
        Self::SourceMissing,
        Self::Retry,
        Self::Expired,
    ];

    /// The whole policy in one place (`SZFriendsOutboxNextState`): `state` unchanged when the event does not apply.
    /// An acknowledgement makes any state Delivered: the recipient committed it, whatever we believed meanwhile.
    pub fn next_state(self, state: OutboxState) -> OutboxState {
        use OutboxState::*;
        let waiting = matches!(state, Queued | Connecting);
        match self {
            Self::RouteAvailable if state == Queued => Connecting,
            Self::SessionEstablished | Self::Written if waiting => Sending,
            Self::Acknowledged => Delivered,
            Self::SessionLost if matches!(state, Connecting | Sending) => Queued,
            Self::Refused | Self::SourceMissing | Self::Expired if state.live() => Failed,
            Self::Retry if state == Failed => Queued,
            _ => state,
        }
    }

    fn failure_reason(self) -> Option<&'static str> {
        match self {
            Self::Refused => Some(FAILURE_REFUSED),
            Self::SourceMissing => Some(FAILURE_SOURCE_MISSING),
            Self::Expired => Some(FAILURE_NOT_DELIVERED_30_DAYS),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct OutboxEntry {
    pub entry_id: String,
    pub conversation_id: String,
    pub kind: OutboxKind,
    pub state: OutboxState,
    pub created_at: f64,
    pub queued_at: f64,
    pub attempts: i64,
    pub item_id: Option<String>,
    pub client_token: Option<String>,
    pub failure_reason: Option<String>,
    /// Opaque bytes the service needs to rebuild the frame later; the outbox never reads them.
    pub payload: Option<Vec<u8>>,
}

const COLUMNS: &str =
    "entry_id, conversation_id, kind, state, created_at, queued_at, attempts, item_id, client_token, failure_reason, \
     payload";

fn entry_from_row(row: &Row) -> rusqlite::Result<OutboxEntry> {
    Ok(OutboxEntry {
        entry_id: row.get(0)?,
        conversation_id: row.get(1)?,
        kind: OutboxKind::from_i64(row.get(2)?),
        state: OutboxState::from_i64(row.get(3)?).unwrap_or(OutboxState::Failed),
        created_at: row.get(4)?,
        queued_at: row.get(5)?,
        attempts: row.get(6)?,
        item_id: row.get(7)?,
        client_token: row.get(8)?,
        failure_reason: row.get(9)?,
        payload: row.get(10)?,
    })
}

fn entries(conn: &Connection, tail: &str, binds: &[&dyn rusqlite::ToSql]) -> Result<Vec<OutboxEntry>> {
    let mut statement = conn.prepare(&format!("SELECT {COLUMNS} FROM outbox {tail}"))?;
    let rows = statement.query_map(binds, entry_from_row)?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

/// `sender`: `None` for this device's own events; otherwise the conversation a peer's frame arrived on, which must
/// own the entry, so one friend's ACK never marks another friend's message delivered.
fn apply(conn: &Connection, entry_id: &str, event: OutboxEvent, sender: Option<&str>, now: f64) -> Result<()> {
    let Some(entry) = entries(conn, "WHERE entry_id = ?1", &[&entry_id])?.pop() else {
        return Err(StoreError::NotFound);
    };
    if sender.is_some_and(|sender| sender.is_empty() || sender != entry.conversation_id) {
        return Err(StoreError::Invalid("not this friend's entry"));
    }
    let next = event.next_state(entry.state);
    let counts = event == OutboxEvent::Written && entry.state.live();
    if next == entry.state && !counts {
        return Ok(());
    }
    let reason = if next == OutboxState::Failed { event.failure_reason() } else { None };
    let restart = event == OutboxEvent::Retry && next == OutboxState::Queued;
    conn.execute(
        "UPDATE outbox SET state = ?1, attempts = attempts + ?2, failure_reason = ?3, \
         queued_at = CASE WHEN ?4 THEN ?5 ELSE queued_at END, updated_at = ?5 WHERE entry_id = ?6",
        params![next as i64, i64::from(counts), reason, restart, now, entry_id],
    )?;
    let (Some(transfer), true) = (entry.item_id.as_deref(), entry.kind == OutboxKind::Offer && next != entry.state)
    else {
        return Ok(());
    };
    let follow = match next {
        OutboxState::Delivered => Some((TransferEvent::OfferDelivered, None)),
        OutboxState::Failed => Some((TransferEvent::Failed, reason)),
        _ if restart => Some((TransferEvent::Retry, None)),
        _ => None,
    };
    if let Some((transfer_event, reason)) = follow {
        // A transfer that has moved on (accepted before the offer's ACK, cancelled meanwhile) simply does not follow.
        match move_transfer(conn, transfer, transfer_event, reason) {
            Ok(_) | Err(StoreError::Stale) | Err(StoreError::NotFound) => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

impl Store {
    /// The entry and the history item it delivers, in one transaction. New entries start Queued; an existing id is
    /// refused (Constraint).
    pub fn enqueue(&mut self, entry: &OutboxEntry, item: Option<&Item>) -> Result<OutboxEntry> {
        let valid = is_valid_identifier(&entry.entry_id)
            && is_valid_identifier(&entry.conversation_id)
            && entry.item_id.as_deref().is_none_or(is_valid_identifier)
            && entry.client_token.as_ref().is_none_or(|t| !t.is_empty() && t.len() <= 64);
        if !valid {
            return Err(StoreError::Invalid("bad outbox entry"));
        }
        self.write(|conn| {
            if let Some(item) = item {
                insert_item(conn, item)?;
            }
            let known: i64 = conn.query_row(
                "SELECT count(*) FROM friends WHERE conversation_id = ?1",
                [&entry.conversation_id],
                |r| r.get(0),
            )?;
            if known == 0 {
                return Err(StoreError::NotFound);
            }
            conn.execute(
                &format!("INSERT INTO outbox ({COLUMNS}, updated_at) VALUES (?1,?2,?3,?4,?5,?5,0,?6,?7,NULL,?8,?9)"),
                params![
                    entry.entry_id,
                    entry.conversation_id,
                    entry.kind as i64,
                    OutboxState::Queued as i64,
                    entry.created_at,
                    entry.item_id,
                    entry.client_token,
                    entry.payload,
                    unix_now()
                ],
            )?;
            Ok(OutboxEntry {
                state: OutboxState::Queued,
                queued_at: entry.created_at,
                attempts: 0,
                failure_reason: None,
                ..entry.clone()
            })
        })
    }

    pub fn outbox_entry(&self, entry_id: &str) -> Result<Option<OutboxEntry>> {
        Ok(entries(&self.conn, "WHERE entry_id = ?1", &[&entry_id])?.pop())
    }

    /// Every entry one intent created, oldest first.
    pub fn outbox_entries_with_client_token(&self, token: &str) -> Result<Vec<OutboxEntry>> {
        entries(&self.conn, "WHERE client_token = ?1 ORDER BY created_at, entry_id", &[&token])
    }

    /// Queued, Connecting and Sending entries for one friend, oldest first: what to send when a session goes live.
    pub fn pending_outbox(&self, conversation_id: &str) -> Result<Vec<OutboxEntry>> {
        entries(
            &self.conn,
            "WHERE conversation_id = ?1 AND state IN (0, 1, 2) ORDER BY created_at, entry_id",
            &[&conversation_id],
        )
    }

    /// This device's own event (route found, written, session lost, Try again...).
    pub fn apply_outbox_event(&mut self, entry_id: &str, event: OutboxEvent) -> Result<()> {
        let now = unix_now();
        self.write(|conn| apply(conn, entry_id, event, None, now))
    }

    /// An event a peer caused (an ACK, a refusal), from the conversation the frame arrived on.
    pub fn apply_outbox_event_from(&mut self, entry_id: &str, event: OutboxEvent, conversation_id: &str) -> Result<()> {
        let now = unix_now();
        self.write(|conn| apply(conn, entry_id, event, Some(conversation_id), now))
    }

    /// Withdraws an outgoing message still Queued or Connecting and never written, deleting its entry and marking the
    /// history item cancelled in one transaction. Once written it may already be on the friend's device: Stale.
    pub fn cancel_message(&mut self, item_id: &str, conversation_id: &str) -> Result<()> {
        self.write(|conn| {
            let cancelled: Option<i64> = conn
                .query_row(
                    "SELECT cancelled FROM messages WHERE conversation_id = ?1 AND item_id = ?2 AND direction = ?3 \
                     AND kind = ?4",
                    params![conversation_id, item_id, Direction::Outgoing as i64, ItemKind::Message as i64],
                    |r| r.get(0),
                )
                .optional()?;
            match cancelled {
                None => return Err(StoreError::NotFound),
                Some(1) => return Ok(()),
                Some(_) => {}
            }
            let tail = "WHERE conversation_id = ?1 AND item_id = ?2 AND kind = ?3";
            let entry = entries(conn, tail, &[&conversation_id, &item_id, &(OutboxKind::Message as i64)])?.pop();
            let Some(entry) = entry.filter(|e| matches!(e.state, OutboxState::Queued | OutboxState::Connecting)) else {
                return Err(StoreError::Stale);
            };
            if entry.attempts > 0 {
                return Err(StoreError::Stale);
            }
            conn.execute("DELETE FROM outbox WHERE entry_id = ?1", [&entry.entry_id])?;
            conn.execute(
                "UPDATE messages SET cancelled = 1 WHERE conversation_id = ?1 AND item_id = ?2",
                [conversation_id, item_id],
            )?;
            Ok(())
        })
    }

    /// Fails every entry still unsent 30 days after it was queued, and returns them.
    pub fn expire_outbox(&mut self, now: f64) -> Result<Vec<OutboxEntry>> {
        let cutoff = now - OUTBOX_EXPIRY_SECONDS;
        self.write(|conn| {
            let due = entries(
                conn,
                "WHERE state IN (0, 1, 2) AND queued_at <= ?1 ORDER BY created_at, entry_id",
                &[&cutoff],
            )?;
            let mut expired = Vec::new();
            for entry in due {
                apply(conn, &entry.entry_id, OutboxEvent::Expired, None, now)?;
                expired.extend(entries(conn, "WHERE entry_id = ?1", &[&entry.entry_id])?);
            }
            Ok(expired)
        })
    }
}

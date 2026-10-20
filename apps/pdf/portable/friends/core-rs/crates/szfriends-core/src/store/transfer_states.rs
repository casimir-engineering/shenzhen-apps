//! The transfer state machine (`SZFriendsTransferNextState`): a transfer's states and the events that move it.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransferState {
    Queued = 0,
    Offered = 1,
    WaitingForYou = 2,
    Sending = 3,
    Receiving = 4,
    Delivered = 5,
    Received = 6,
    Declined = 7,
    Cancelled = 8,
    Failed = 9,
}

impl TransferState {
    pub const ALL: [Self; 10] = [
        Self::Queued,
        Self::Offered,
        Self::WaitingForYou,
        Self::Sending,
        Self::Receiving,
        Self::Delivered,
        Self::Received,
        Self::Declined,
        Self::Cancelled,
        Self::Failed,
    ];

    pub fn from_i64(value: i64) -> Option<Self> {
        Self::ALL.into_iter().find(|s| *s as i64 == value)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransferEvent {
    OfferDelivered = 0,
    Accepted = 1,
    Declined = 2,
    Cancelled = 3,
    Verified = 4,
    Failed = 5,
    Retry = 6,
}

impl TransferEvent {
    pub const ALL: [Self; 7] = [
        Self::OfferDelivered,
        Self::Accepted,
        Self::Declined,
        Self::Cancelled,
        Self::Verified,
        Self::Failed,
        Self::Retry,
    ];

    /// `SZFriendsTransferNextState`: `state` unchanged when the event does not apply (an acceptance of an offer no
    /// longer offered, a cancel after the file arrived, which cannot be retracted).
    pub fn next_state(self, outgoing: bool, state: TransferState) -> TransferState {
        use TransferState::*;
        let unanswered = if outgoing { matches!(state, Queued | Offered) } else { state == WaitingForYou };
        let moving = if outgoing { Sending } else { Receiving };
        match self {
            Self::OfferDelivered if outgoing && state == Queued => Offered,
            Self::Accepted if unanswered => moving,
            Self::Declined if unanswered => Declined,
            Self::Cancelled if unanswered || state == moving => Cancelled,
            Self::Verified if state == moving => {
                if outgoing {
                    Delivered
                } else {
                    Received
                }
            }
            // An incoming offer nobody accepted has nothing that can fail; the sender withdraws it with CANCEL.
            Self::Failed if (outgoing && unanswered) || state == moving => Failed,
            Self::Retry if state == Failed => {
                if outgoing {
                    Queued
                } else {
                    Receiving
                }
            }
            _ => state,
        }
    }
}

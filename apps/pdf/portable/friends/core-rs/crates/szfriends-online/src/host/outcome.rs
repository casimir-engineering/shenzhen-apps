//! What the check-in client tells its owner, back on the owner's thread (`client.rs`).

use super::attestation::Attestation;
use super::list::HostList;

/// What the owner hears.
#[derive(Debug)]
pub enum HostOutcome {
    /// Online messages may be sent now, or no longer.
    Available(bool),
    /// The host reserved this Friends ID for this person, with its attestation when one checked out.
    Reserved(String, Option<Attestation>),
    /// The ID from before joining a profile: whether a host confirmed its release (`release.rs`).
    PreJoinReleased(bool),
    /// A newer signed host list took the old one's place.
    ListChanged(HostList),
    /// Time to publish this device's record: the owner seals one and calls `publish`.
    PublishDue,
    Incoming {
        sid: String,
        via: Via,
        link_id: Option<[u8; 16]>,
        payload: Vec<u8>,
    },
    Opened {
        token: u64,
        sid: Option<String>,
        owner_online: bool,
        link_ended: Option<String>,
    },
    Payload {
        sid: String,
        payload: Vec<u8>,
    },
    SidEnded {
        sid: String,
    },
    Relay {
        token: u64,
        credentials: Option<crate::transport::RelayCredentials>,
    },
    Records {
        token: u64,
        blobs: Option<Vec<Vec<u8>>>,
    },
    LinkRegistered {
        link_id: [u8; 16],
        ok: bool,
    },
    /// Another of the person's computers removed this one (reservation.rs): no host takes it again.
    Removed,
}

/// How a caller named this helper in an open.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Via {
    Rendezvous,
    FriendsId,
    Link,
    Join,
}

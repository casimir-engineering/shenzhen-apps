//! The online transport (`SZFriendsOnlineTransport.h`): Internet connections to a peer over the helper's pinned
//! WebRTC stack, data channels only, under the pre-authentication rule (ADR 0009 § Who may reach the stack): a
//! connection exists only toward a peer the signalling established, and applies only what that signalling
//! authenticated. Fingerprints travel inside the authenticated exchange beside each description and must match the
//! SDP's; remote candidates come only from the same exchange.

pub mod candidate;
pub mod connection;
pub mod description;
pub mod stream;

use szfriends_wire::route::RouteMethod;

pub use connection::{ConnEvent, Connection};
pub use stream::{ChannelStream, StreamInput, StreamWriter};

/// Largest data-channel message (every browser accepts 64 KiB).
pub const MESSAGE_MAX: usize = 65536;

/// Why the connection exists; it fixes the gating rule and which local candidates may be sent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Purpose {
    Friend = 1,
    FirstContact = 2,
    Link = 3,
}

/// The offerer creates the offer and the data channel and is the ADR 0001 initiator; the answerer applies the offer
/// before it gathers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Offerer = 1,
    Answerer = 2,
}

impl Role {
    pub fn other(self) -> Self {
        match self {
            Self::Offerer => Self::Answerer,
            Self::Answerer => Self::Offerer,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    Direct = 1,
    ProbeHandover = 2,
    Relay = 3,
}

impl Kind {
    pub fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            1 => Some(Self::Direct),
            2 => Some(Self::ProbeHandover),
            3 => Some(Self::Relay),
            _ => None,
        }
    }
}

/// Which technique carried a path or produced a candidate. Recorded by number in the technique log: never renumber.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Technique {
    #[default]
    None = 0,
    HostIpv6 = 1,
    HostPrivate = 2,
    ServerReflexive = 3,
    PeerReflexive = 4,
    PortMapping = 5,
    PredictedPort = 6,
    ProbeHandover = 7,
    TcpSimultaneousOpen = 8,
    Relay = 9,
}

impl Technique {
    pub fn from_byte(byte: u8) -> Option<Self> {
        Some(match byte {
            0 => Self::None,
            1 => Self::HostIpv6,
            2 => Self::HostPrivate,
            3 => Self::ServerReflexive,
            4 => Self::PeerReflexive,
            5 => Self::PortMapping,
            6 => Self::PredictedPort,
            7 => Self::ProbeHandover,
            8 => Self::TcpSimultaneousOpen,
            9 => Self::Relay,
            _ => return None,
        })
    }
}

/// A connected path: the session's route class (Relay for the relay technique, Internet for every other).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Route {
    pub technique: Technique,
    pub ipv6: bool,
}

impl Route {
    pub const NONE: Route = Route { technique: Technique::None, ipv6: false };

    pub fn method(&self) -> RouteMethod {
        match self.technique {
            Technique::None => RouteMethod::None,
            Technique::Relay => RouteMethod::Relay,
            _ => RouteMethod::Internet,
        }
    }
}

/// TURN credentials from the host's `relay_credentials_result`, with the TURN over UDP URI from the signed list.
#[derive(Clone, Debug, PartialEq)]
pub struct RelayCredentials {
    pub turn_uri: String,
    pub username: String,
    pub credential: String,
    /// Unix seconds: an allocation must start before this.
    pub expires: f64,
}

/// What the order asks for.
#[derive(Clone, Debug)]
pub struct Request {
    pub purpose: Purpose,
    pub role: Role,
    pub kind: Kind,
    /// The peer as the signalling established it: an identity key (32 bytes) or a link id (16).
    pub peer: Vec<u8>,
    /// The host's STUN URI from the signed list; none gathers no server-reflexive candidate.
    pub stun_uri: Option<String>,
    pub relay: Option<RelayCredentials>,
    /// The exact local UDP port to bind (a probe handover's); 0 lets the system choose.
    pub local_port: u16,
    /// Answerer only: the authenticated offer and the offerer's fingerprint.
    pub remote_offer: Option<(String, [u8; 32])>,
}

/// None is shown to people; the order maps them to its next phase.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OnlineError {
    NotAuthorized = 1,
    DescriptionInvalid = 2,
    FingerprintMismatch = 3,
    CandidateRefused = 4,
    ConnectivityFailed = 5,
    RelayRefused = 6,
    PeerClosed = 7,
    Unavailable = 8,
}

/// How the transport binds: the testing configuration binds every peer connection to 127.0.0.1 and accepts loopback
/// candidates both ways, the only way two peer connections on one computer meet without leaving it.
#[derive(Clone, Debug, Default)]
pub struct TransportConfig {
    pub bind_address: Option<String>,
    pub allow_loopback: bool,
    /// Tests of links on one computer: links may then use loopback host candidates and a local relay's private
    /// relayed address.
    pub links_use_local_addresses: bool,
}

impl TransportConfig {
    pub fn loopback() -> Self {
        Self { bind_address: Some("127.0.0.1".into()), allow_loopback: true, links_use_local_addresses: false }
    }
}

/// Configures the stack once per process, before any peer connection exists.
pub fn configure_stack() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| szfriends_datachannel_sys::set_thread_pool_size(1));
}

/// Releases stack objects on the stack's release thread: deleting a connection blocks until its transports stop, which
/// must happen neither on the owner's thread nor on one of the stack's.
pub(crate) fn teardown<T: Send + 'static>(item: T) {
    szfriends_datachannel_sys::release_in_background(item);
}

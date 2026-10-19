//! The NAT techniques (ADR 0011; `service/online/nat/`): STUN, the two-port classifier, hard-NAT probing and router
//! port mapping. Every one sends only to addresses the caller names (the host from the signed list, the gateway, the
//! peer from authenticated signalling), checks what comes back strictly, and logs no address, port or key. Tests run
//! them on loopback only, through each one's loopback-only mode, which can narrow where packets go but never widen it.

pub mod classifier;
pub mod endpoint;
pub mod prober;
pub mod stun;

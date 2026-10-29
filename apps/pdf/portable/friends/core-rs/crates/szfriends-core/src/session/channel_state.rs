//! What a channel learned and agreed: its role and pattern, the peer's identity, certificate, attestation and token,
//! the handshake hash, and the capabilities both sides have (channel.rs).

use super::*;

impl SecureChannel {
    pub fn is_initiator(&self) -> bool {
        matches!(self.role, Role::Initiator { .. })
    }

    pub fn pattern(&self) -> Pattern {
        self.pattern
    }

    pub fn is_established(&self) -> bool {
        self.state == State::Established
    }

    pub fn is_closed(&self) -> bool {
        self.state == State::Closed
    }

    /// The route the initiator declared (the session race and the chunk sizes use it).
    pub fn initiator_route(&self) -> RouteMethod {
        self.initiator_route
    }

    /// Ed25519 identity key from the peer's certificate; `None` for NN.
    pub fn remote_identity(&self) -> Option<&[u8; 32]> {
        self.remote_identity.as_ref()
    }

    /// The verified 96-byte certificate the peer presented; `None` for NN.
    pub fn remote_certificate(&self) -> Option<&[u8]> {
        self.remote_certificate.as_deref()
    }

    /// The peer's attestation, unverified.
    pub fn remote_attestation(&self) -> Option<&[u8]> {
        self.remote_attestation.as_deref()
    }

    pub fn remote_static(&self) -> Option<&[u8; 32]> {
        self.remote_static.as_ref()
    }

    /// Responder: the token an IK callback presented.
    pub fn presented_token(&self) -> Option<&[u8]> {
        self.presented_token.as_deref()
    }

    /// Responder: the lane token IK message 1 presented (ADR 0018 § 6). The driver admits the lane into the group it
    /// names once the session is live, or closes it with CLOSE `LaneRefused`; a lane never enters the session race.
    pub fn presented_lane(&self) -> Option<&[u8; 16]> {
        self.presented_lane.as_ref()
    }

    pub fn handshake_hash(&self) -> Option<&[u8; 64]> {
        self.handshake_hash.as_ref()
    }

    pub fn negotiated_minor(&self) -> u16 {
        self.negotiated_minor
    }

    /// The capability bits the peer's handshake set.
    pub fn remote_capabilities(&self) -> u32 {
        self.remote_capabilities
    }

    /// The session's Noise cipher: AES-256-GCM only on an AES lane (ADR 0018 § 9.2).
    pub fn cipher(&self) -> NoiseCipher {
        self.cipher
    }

    /// A fast session where both sides also set `bit`.
    pub(super) fn fast_with(&self, bit: u32) -> bool {
        self.fast_transfers() && self.config.capabilities & bit != 0 && self.remote_capabilities & bit != 0
    }

    /// ADR 0018 § 9.2: this group's lanes run AES-256-GCM (both sides have hardware AES and set bit 1).
    pub fn aes_lanes(&self) -> bool {
        self.fast_with(szfriends_wire::consts::CAPABILITY_AES_LANES)
    }

    /// ADR 0018 § 9.4: the codec this session's compressed PARTs use, zstd when both sides read it (bit 2), else LZ4
    /// (bit 4). Only Bluetooth and relay lanes send them compressed.
    pub fn part_codec(&self) -> Option<u8> {
        if !self.fast_transfers() {
            return None;
        }
        crate::transfer::compress::codec_for(self.config.capabilities & self.remote_capabilities)
    }

    /// Whether a PART compressed with `codec` may arrive on this session: both sides set its bit.
    pub fn reads_codec(&self, codec: u8) -> bool {
        let bit = crate::transfer::compress::codec_bit(codec);
        bit != 0 && self.fast_with(bit)
    }

    /// ADR 0018 § 1: this session runs fast transfers when its negotiated minor is 4 or more and both sides set bit 0.
    /// Otherwise nothing of them is sent, and nothing of them is accepted.
    pub fn fast_transfers(&self) -> bool {
        let bit = szfriends_wire::consts::CAPABILITY_FAST_TRANSFERS;
        self.negotiated_minor >= szfriends_wire::consts::FAST_TRANSFERS_MINOR
            && self.config.capabilities & bit != 0
            && self.remote_capabilities & bit != 0
    }

    /// ADR 0018 § 3: Pieces in WANT and HAVE go to this peer (both set capability bit 3 on a fast session).
    pub fn pieces(&self) -> bool {
        let bit = szfriends_wire::consts::CAPABILITY_PIECES;
        self.fast_transfers() && self.config.capabilities & bit != 0 && self.remote_capabilities & bit != 0
    }

    /// ADR 0019: BOOST may go to this peer and come from it (both set capability bit 5 on a fast session).
    pub fn direct_wifi_boost(&self) -> bool {
        self.fast_with(szfriends_wire::consts::CAPABILITY_DIRECT_WIFI_BOOST)
    }

    pub fn rekeys(&self) -> (u64, u64) {
        (self.rekeys_sent, self.rekeys_received)
    }
}

//! Handshake payloads (`SZFriendsHandshakePayload`): frame fields without a type byte. Which message carries what:
//!
//! - NN 1 (initiator, plaintext) and NN 2 (responder): minor range, capabilities.
//! - XX 1 (initiator, plaintext): nothing. XX 2 (responder): certificate, range, capabilities, and on a public entry
//!   the profile. XX 3 (initiator): certificate, range, capabilities, route class.
//! - IK 1 (initiator): certificate, range, capabilities, route class, and the token when calling back after Add by
//!   ID. IK 2 (responder): certificate, range, capabilities.
//!
//! Every payload that carries a certificate may also carry the sender's host-issued Friends ID attestation.

use crate::consts::SESSION_MINOR;
use crate::error::WireError;
use crate::fields::{self, Fields};
use crate::rules::HANDSHAKE_PAYLOAD;
use crate::types::tag;

#[derive(Clone, Default, PartialEq, Eq)]
pub struct HandshakePayload {
    pub certificate: Option<Vec<u8>>,
    pub request_token: Option<Vec<u8>>,
    /// Opaque here; the helper checks it against the pinned host keys.
    pub attestation: Option<Vec<u8>>,
    /// `(min, max)`; only both tags together count as a range.
    pub minor_range: Option<(u16, u16)>,
    /// Capability bits (`consts::CAPABILITY_*`); unknown bits ignored.
    pub capabilities: u32,
    pub route_class: Option<u8>,
    /// IK message 1 of a lane (ADR 0018 § 6): the token tying it to a live session's handshake hash.
    pub lane: Option<Vec<u8>>,
    /// Profile fields only (name, Friends ID, picture set and index, own picture).
    pub profile: Fields,
}

impl HandshakePayload {
    /// This build's range (0 to the session minor), no capabilities: the channel sets the ones its config allows.
    pub fn local() -> Self {
        Self { minor_range: Some((0, SESSION_MINOR)), ..Self::default() }
    }

    pub fn encode(&self) -> Result<Vec<u8>, WireError> {
        let mut out = Fields::new();
        for (&profile_tag, value) in &self.profile {
            if !tag::is_profile(profile_tag) {
                return Err(WireError::FieldNotDefined(profile_tag));
            }
            out.insert(profile_tag, value.clone());
        }
        if let Some(certificate) = &self.certificate {
            out.insert(tag::CERTIFICATE, certificate.clone());
        }
        if let Some(token) = &self.request_token {
            out.insert(tag::TOKEN, token.clone());
        }
        if let Some(attestation) = &self.attestation {
            out.insert(tag::ATTESTATION, attestation.clone());
        }
        // Capabilities travel with the range, as the Objective-C encoder writes them.
        if let Some((min, max)) = self.minor_range {
            out.insert(tag::MINOR_MIN, fields::integer(min.into(), tag::MINOR_MIN)?);
            out.insert(tag::MINOR_MAX, fields::integer(max.into(), tag::MINOR_MAX)?);
            out.insert(tag::CAPABILITIES, fields::integer(self.capabilities.into(), tag::CAPABILITIES)?);
        }
        if let Some(route) = self.route_class {
            out.insert(tag::ROUTE_CLASS, vec![route]);
        }
        if let Some(lane) = &self.lane {
            out.insert(tag::LANE, lane.clone());
        }
        let mut output = Vec::new();
        fields::append(&mut output, &out, HANDSHAKE_PAYLOAD)?;
        Ok(output)
    }

    /// Unknown tags are ignored; duplicates and out-of-limit values fail.
    pub fn decode(data: &[u8]) -> Result<Self, WireError> {
        let mut decoded = fields::decode(data, 0, HANDSHAKE_PAYLOAD)?;
        let number = |fields: &Fields, t: u8| fields.get(&t).and_then(|v| fields::read_integer(v, t));
        let minor_range = match (number(&decoded, tag::MINOR_MIN), number(&decoded, tag::MINOR_MAX)) {
            (Some(min), Some(max)) => Some((min as u16, max as u16)),
            _ => None,
        };
        let capabilities = number(&decoded, tag::CAPABILITIES).unwrap_or(0) as u32;
        let route_class = number(&decoded, tag::ROUTE_CLASS).map(|r| r as u8);
        Ok(Self {
            certificate: decoded.remove(&tag::CERTIFICATE),
            request_token: decoded.remove(&tag::TOKEN),
            attestation: decoded.remove(&tag::ATTESTATION),
            minor_range,
            capabilities,
            route_class,
            lane: decoded.remove(&tag::LANE),
            profile: decoded.into_iter().filter(|(t, _)| tag::is_profile(*t)).collect(),
        })
    }
}

impl std::fmt::Debug for HandshakePayload {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HandshakePayload")
            .field("certificate", &self.certificate.is_some())
            .field("request_token", &self.request_token.is_some())
            .field("attestation", &self.attestation.is_some())
            .field("minor_range", &self.minor_range)
            .field("capabilities", &self.capabilities)
            .field("route_class", &self.route_class)
            .field("lane", &self.lane.is_some())
            .field("profile_tags", &self.profile.keys().collect::<Vec<_>>())
            .finish()
    }
}

/// The minor version both sides speak (the lower maximum), or `None` when the ranges do not overlap or one is
/// inverted.
pub fn negotiate_minor(local: (u16, u16), remote: (u16, u16)) -> Option<u16> {
    if local.0 > local.1 || remote.0 > remote.1 {
        return None;
    }
    let low = local.0.max(remote.0);
    let high = local.1.min(remote.1);
    (low <= high).then_some(high)
}

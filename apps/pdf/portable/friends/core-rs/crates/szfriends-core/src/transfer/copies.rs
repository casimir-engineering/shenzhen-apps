//! The two messages ADR 0018 § 4 adds to file copies between one person's devices (SYNC) and to Get again (AGAIN),
//! carried inside those frames' own fields, so neither frame changes; sent only on sessions that negotiated fast
//! transfers. After BLOCKS FOLLOW the serving side sends HASHES and PARTs on the session as for an offer.
//!
//! ```text
//! SYNC  7 WANT BLOCKS    id length u8 | id | shift u8 | ranges (u32be first, u32be count)*
//! SYNC  8 BLOCKS FOLLOW  id length u8 | id | root (32) | shift u8
//! AGAIN 4 WANT BLOCKS    id (16) | shift u8 | ranges (u32be first, u32be count)*
//! AGAIN 5 BLOCKS FOLLOW  id (16) | root (32) | shift u8
//! ```
//!
//! SYNC names a transfer by its id as text, AGAIN by its 16 bytes, as their other messages do; ranges follow
//! `szfriends_wire::ranges` (ascending, not overlapping, at least one, at most 8,000).

use szfriends_wire::ranges;

use super::tree::Leaf;

pub const SYNC_WANT_BLOCKS: u8 = 7;
pub const SYNC_BLOCKS_FOLLOW: u8 = 8;
pub const AGAIN_WANT_BLOCKS: u8 = 4;
pub const AGAIN_BLOCKS_FOLLOW: u8 = 5;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CopyMessage {
    WantBlocks { id: String, shift: u8, ranges: Vec<(u32, u32)> },
    BlocksFollow { id: String, root: Leaf, shift: u8 },
}

impl CopyMessage {
    pub fn id(&self) -> &str {
        match self {
            Self::WantBlocks { id, .. } | Self::BlocksFollow { id, .. } => id,
        }
    }

    fn body(&self, out: &mut Vec<u8>) -> Option<()> {
        match self {
            Self::WantBlocks { shift, ranges: wanted, .. } => {
                let mut fields = ranges::encode(wanted);
                if fields.len() != 1 {
                    return None;
                }
                out.push(*shift);
                out.append(&mut fields[0]);
            }
            Self::BlocksFollow { root, shift, .. } => {
                out.extend_from_slice(root);
                out.push(*shift);
            }
        }
        Some(())
    }

    fn decode_body(kind: u8, id: String, rest: &[u8], want: u8, follow: u8) -> Option<Self> {
        if kind == want {
            let (&shift, bytes) = rest.split_first()?;
            let wanted = ranges::decode(bytes).filter(|r| !r.is_empty())?;
            Some(Self::WantBlocks { id, shift, ranges: wanted })
        } else if kind == follow && rest.len() == 33 {
            Some(Self::BlocksFollow { id, root: rest[..32].try_into().ok()?, shift: rest[32] })
        } else {
            None
        }
    }

    /// The SYNC payload; `None` for an id longer than 64 bytes or more ranges than one message holds.
    pub fn encode_sync(&self) -> Option<Vec<u8>> {
        let kind = match self {
            Self::WantBlocks { .. } => SYNC_WANT_BLOCKS,
            Self::BlocksFollow { .. } => SYNC_BLOCKS_FOLLOW,
        };
        let id = self.id().as_bytes();
        if id.is_empty() || id.len() > 64 {
            return None;
        }
        let mut out = vec![kind, id.len() as u8];
        out.extend_from_slice(id);
        self.body(&mut out)?;
        Some(out)
    }

    pub fn decode_sync(data: &[u8]) -> Option<Self> {
        let (&kind, rest) = data.split_first()?;
        let (&length, rest) = rest.split_first()?;
        let length = usize::from(length);
        if length == 0 || length > 64 || rest.len() < length {
            return None;
        }
        let id = std::str::from_utf8(&rest[..length]).ok()?.to_owned();
        Self::decode_body(kind, id, &rest[length..], SYNC_WANT_BLOCKS, SYNC_BLOCKS_FOLLOW)
    }

    /// The AGAIN payload; `None` for an id that is not 16 bytes of lowercase hex.
    pub fn encode_again(&self) -> Option<Vec<u8>> {
        let kind = match self {
            Self::WantBlocks { .. } => AGAIN_WANT_BLOCKS,
            Self::BlocksFollow { .. } => AGAIN_BLOCKS_FOLLOW,
        };
        let id = self.id();
        if id.len() != 32 || id.bytes().any(|b| b.is_ascii_uppercase()) {
            return None;
        }
        let mut out = vec![kind];
        out.extend_from_slice(&hex::decode(id).ok()?);
        self.body(&mut out)?;
        Some(out)
    }

    pub fn decode_again(data: &[u8]) -> Option<Self> {
        let (&kind, rest) = data.split_first()?;
        let id = hex::encode(rest.get(..16)?);
        Self::decode_body(kind, id, &rest[16..], AGAIN_WANT_BLOCKS, AGAIN_BLOCKS_FOLLOW)
    }
}

/// A lane's token (ADR 0018 § 6): keyed BLAKE2b-128 with the first session's handshake hash as the key, over
/// `"SZFriends lane v1" || u8 index`.
pub fn lane_token(handshake_hash: &[u8; 64], index: u8) -> [u8; 16] {
    use blake2::digest::{KeyInit, Mac};
    let mut mac = <blake2::Blake2bMac<blake2::digest::consts::U16> as KeyInit>::new_from_slice(handshake_hash)
        .expect("64-byte key");
    mac.update(b"SZFriends lane v1");
    mac.update(&[index]);
    mac.finalize().into_bytes().into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn copy_messages_round_trip_and_refuse_bad_ranges() {
        let id = "00112233445566778899aabbccddeeff".to_owned();
        let want = CopyMessage::WantBlocks { id: id.clone(), shift: 20, ranges: vec![(3, 4), (9, 1)] };
        let follow = CopyMessage::BlocksFollow { id, root: [9; 32], shift: 21 };
        for message in [&want, &follow] {
            assert_eq!(CopyMessage::decode_sync(&message.encode_sync().unwrap()).as_ref(), Some(message));
            assert_eq!(CopyMessage::decode_again(&message.encode_again().unwrap()).as_ref(), Some(message));
        }
        let mut bytes = want.encode_again().unwrap();
        bytes.truncate(18);
        assert_eq!(CopyMessage::decode_again(&bytes), None, "no ranges");
        assert_eq!(CopyMessage::decode_again(&[1; 30]), None, "another kind");
    }
}

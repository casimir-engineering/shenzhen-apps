//! Presence tags (ADR 0004): what a device advertises nearby so friends recognise it and strangers cannot follow it.
//! Callback tags for Add by ID are the same function over the request's callback secret.

pub const WINDOW_SECONDS: i64 = 900;
pub const TAG_LEN: usize = 8;
pub const SECRET_LEN: usize = 32;
const CONTEXT: &[u8] = b"SZFriends presence v1";

/// `w = floor(unix seconds / 900)`.
pub fn window_index(unix_seconds: f64) -> i64 {
    (unix_seconds / WINDOW_SECONDS as f64).floor() as i64
}

/// First 8 bytes of BLAKE2b-256 keyed with the 32-byte secret over `"SZFriends presence v1" || u64be(w)`. A 32-byte
/// digest truncated, as ADR 0004 says: an 8-byte BLAKE2b would be a different function. A malformed secret gives
/// random bytes, which match nobody and reveal nothing.
pub fn tag(secret: &[u8], window: i64) -> [u8; TAG_LEN] {
    let mut out = [0u8; TAG_LEN];
    if secret.len() != SECRET_LEN {
        crate::random_bytes(&mut out);
        return out;
    }
    let digest = crate::blake2b::<32>(Some(secret), &[CONTEXT, &(window as u64).to_be_bytes()]);
    out.copy_from_slice(&digest[..TAG_LEN]);
    out
}

/// The tags a matcher accepts at `window`: w-1, w and w+1, tolerating 15 minutes of clock skew.
pub fn tags_to_match(secret: &[u8], window: i64) -> [[u8; TAG_LEN]; 3] {
    [tag(secret, window.wrapping_sub(1)), tag(secret, window), tag(secret, window.wrapping_add(1))]
}

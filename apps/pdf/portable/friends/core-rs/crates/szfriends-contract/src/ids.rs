//! Identifier rules (PROTOCOL.md § Framing).

/// A client frame's `id`: 1 to 32 printable ASCII characters.
pub fn client_frame_id_is_valid(id: &str) -> bool {
    (1..=32).contains(&id.len()) && id.bytes().all(|b| (0x20..0x7f).contains(&b))
}

/// Opaque ids the helper issues (conversation, item, transfer, subscription, nearby, scope): 1 to 64 characters from
/// `[A-Za-z0-9_-]`. Clients never parse or construct them.
pub fn opaque_id_is_valid(id: &str) -> bool {
    (1..=64).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

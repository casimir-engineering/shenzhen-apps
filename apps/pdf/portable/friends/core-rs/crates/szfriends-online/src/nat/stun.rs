//! STUN Binding messages (RFC 8489, the Binding method only; `SZFriendsNATStun.m`) for the sockets that live outside
//! the peer connection: the two-port classifier and the hard-NAT prober. Parsing is strict because these bytes
//! arrive before anyone is authenticated: a message is accepted only whole (header length equal to the datagram,
//! attributes inside it, padding to four bytes, a FINGERPRINT that checks if present and is last), never longer than
//! [`MESSAGE_MAX`]. The first instance of an attribute counts; attributes after MESSAGE-INTEGRITY other than
//! FINGERPRINT are ignored. A malformed address or error code rejects the whole message.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use hmac::{Hmac, Mac};
use sha1::Sha1;

pub const HEADER_LENGTH: usize = 20;
pub const MESSAGE_MAX: usize = 548;
pub const TRANSACTION_LENGTH: usize = 12;
/// "<their ufrag>:<our ufrag>" with ufrags of at most 16 characters.
pub const USERNAME_MAX: usize = 33;

pub const BINDING_REQUEST: u16 = 0x0001;
pub const BINDING_SUCCESS: u16 = 0x0101;
pub const BINDING_ERROR: u16 = 0x0111;

const MAGIC_COOKIE: u32 = 0x2112_a442;
const FINGERPRINT_XOR: u32 = 0x5354_554e;
const ATTR_MAPPED_ADDRESS: u16 = 0x0001;
const ATTR_USERNAME: u16 = 0x0006;
const ATTR_MESSAGE_INTEGRITY: u16 = 0x0008;
const ATTR_ERROR_CODE: u16 = 0x0009;
const ATTR_XOR_MAPPED_ADDRESS: u16 = 0x0020;
const ATTR_USE_CANDIDATE: u16 = 0x0025;
const ATTR_FINGERPRINT: u16 = 0x8028;
const INTEGRITY_LENGTH: usize = 20;
const USERNAME_READ_MAX: usize = 513;

/// A parsed message; `username` borrows the parsed buffer.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Message<'a> {
    pub kind: u16,
    pub transaction: [u8; TRANSACTION_LENGTH],
    /// XOR-MAPPED-ADDRESS, or MAPPED-ADDRESS when no XOR form came.
    pub mapped: Option<SocketAddr>,
    pub username: Option<&'a [u8]>,
    /// Offset of the MESSAGE-INTEGRITY attribute's header.
    pub integrity_offset: Option<usize>,
    pub fingerprint: bool,
    pub use_candidate: bool,
    pub error_code: u16,
}

fn read16(p: &[u8]) -> u16 {
    u16::from_be_bytes([p[0], p[1]])
}

fn read32(p: &[u8]) -> u32 {
    u32::from_be_bytes([p[0], p[1], p[2], p[3]])
}

/// CRC-32 (ISO-HDLC, as zlib), for FINGERPRINT.
pub fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for &byte in bytes {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xedb8_8320 & 0u32.wrapping_sub(crc & 1));
        }
    }
    !crc
}

fn parse_address(value: &[u8], xored: bool, header: &[u8]) -> Option<SocketAddr> {
    if value.len() < 4 || value[0] != 0 {
        return None;
    }
    let mut port = read16(&value[2..]);
    if xored {
        port ^= (MAGIC_COOKIE >> 16) as u16;
    }
    let xor = |i: usize| if xored { header[4 + i] } else { 0 };
    match (value[1], value.len()) {
        (0x01, 8) => {
            let raw: [u8; 4] = std::array::from_fn(|i| value[4 + i] ^ xor(i));
            Some(SocketAddr::new(IpAddr::V4(Ipv4Addr::from(raw)), port))
        }
        (0x02, 20) => {
            let raw: [u8; 16] = std::array::from_fn(|i| value[4 + i] ^ xor(i));
            Some(SocketAddr::new(IpAddr::V6(Ipv6Addr::from(raw)), port))
        }
        _ => None,
    }
}

/// `None` for anything but one whole, well-formed STUN message of at most [`MESSAGE_MAX`] bytes.
pub fn parse(bytes: &[u8]) -> Option<Message<'_>> {
    let length = bytes.len();
    if !(HEADER_LENGTH..=MESSAGE_MAX).contains(&length) || bytes[0] & 0xc0 != 0 || read32(&bytes[4..]) != MAGIC_COOKIE {
        return None;
    }
    let body = usize::from(read16(&bytes[2..]));
    if body % 4 != 0 || body + HEADER_LENGTH != length {
        return None;
    }
    let mut message = Message { kind: read16(bytes), ..Message::default() };
    message.transaction.copy_from_slice(&bytes[8..20]);
    let (mut saw_xor, mut saw_mapped, mut saw_username, mut saw_error) = (false, false, false, false);
    let mut at = HEADER_LENGTH;
    while at < length {
        if length - at < 4 || message.fingerprint {
            return None;
        }
        let kind = read16(&bytes[at..]);
        let value_length = usize::from(read16(&bytes[at + 2..]));
        let padded = (value_length + 3) & !3;
        if padded > length - at - 4 {
            return None;
        }
        let value = &bytes[at + 4..at + 4 + value_length];
        if kind == ATTR_FINGERPRINT {
            if value_length != 4 || read32(value) != crc32(&bytes[..at]) ^ FINGERPRINT_XOR {
                return None;
            }
            message.fingerprint = true;
        } else if message.integrity_offset.is_some() {
            // RFC 8489 § 14.5: everything between MESSAGE-INTEGRITY and FINGERPRINT is ignored.
        } else if kind == ATTR_MESSAGE_INTEGRITY {
            if value_length != INTEGRITY_LENGTH {
                return None;
            }
            message.integrity_offset = Some(at);
        } else if kind == ATTR_XOR_MAPPED_ADDRESS && !saw_xor {
            saw_xor = true;
            message.mapped = Some(parse_address(value, true, bytes)?);
        } else if kind == ATTR_MAPPED_ADDRESS && !saw_mapped {
            saw_mapped = true;
            let parsed = parse_address(value, false, bytes)?;
            if !saw_xor {
                message.mapped = Some(parsed);
            }
        } else if kind == ATTR_USERNAME && !saw_username {
            saw_username = true;
            if value_length == 0 || value_length > USERNAME_READ_MAX {
                return None;
            }
            message.username = Some(value);
        } else if kind == ATTR_USE_CANDIDATE {
            if value_length != 0 {
                return None;
            }
            message.use_candidate = true;
        } else if kind == ATTR_ERROR_CODE && !saw_error {
            saw_error = true;
            if value_length < 4 {
                return None;
            }
            let (class, number) = (u16::from(value[2] & 7), u16::from(value[3]));
            if !(3..=6).contains(&class) || number > 99 {
                return None;
            }
            message.error_code = class * 100 + number;
        }
        at += 4 + padded;
    }
    Some(message)
}

fn integrity(bytes: &[u8], offset: usize, key: &[u8]) -> [u8; INTEGRITY_LENGTH] {
    let mut header = [0u8; HEADER_LENGTH];
    header.copy_from_slice(&bytes[..HEADER_LENGTH]);
    let adjusted = (offset - HEADER_LENGTH + 4 + INTEGRITY_LENGTH) as u16;
    header[2..4].copy_from_slice(&adjusted.to_be_bytes());
    let mut mac = <Hmac<Sha1> as Mac>::new_from_slice(key).expect("any key length");
    mac.update(&header);
    mac.update(&bytes[HEADER_LENGTH..offset]);
    mac.finalize().into_bytes().into()
}

/// MESSAGE-INTEGRITY (HMAC-SHA1 under the short-term key), compared in constant time.
pub fn check_integrity(bytes: &[u8], message: &Message<'_>, key: &[u8]) -> bool {
    let Some(offset) = message.integrity_offset else { return false };
    if key.is_empty() || offset + 4 + INTEGRITY_LENGTH > bytes.len() {
        return false;
    }
    let expected = integrity(bytes, offset, key);
    let got = &bytes[offset + 4..offset + 4 + INTEGRITY_LENGTH];
    expected.iter().zip(got).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0
}

fn append(out: &mut Vec<u8>, kind: u16, value: &[u8]) {
    out.extend_from_slice(&kind.to_be_bytes());
    out.extend_from_slice(&(value.len() as u16).to_be_bytes());
    out.extend_from_slice(value);
    out.resize(out.len() + ((4 - value.len() % 4) % 4), 0);
}

fn header(kind: u16, transaction: &[u8; TRANSACTION_LENGTH]) -> Vec<u8> {
    let mut out = Vec::with_capacity(128);
    out.extend_from_slice(&kind.to_be_bytes());
    out.extend_from_slice(&[0, 0]);
    out.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
    out.extend_from_slice(transaction);
    out
}

/// MESSAGE-INTEGRITY when keyed, then FINGERPRINT, each over the header as it will be sent.
fn finish(mut out: Vec<u8>, key: Option<&[u8]>) -> Vec<u8> {
    if let Some(key) = key.filter(|k| !k.is_empty()) {
        let offset = out.len();
        let mac = integrity(&out, offset, key);
        append(&mut out, ATTR_MESSAGE_INTEGRITY, &mac);
    }
    let length = (out.len() + 8 - HEADER_LENGTH) as u16;
    out[2..4].copy_from_slice(&length.to_be_bytes());
    let crc = crc32(&out) ^ FINGERPRINT_XOR;
    append(&mut out, ATTR_FINGERPRINT, &crc.to_be_bytes());
    out
}

/// A Binding request with FINGERPRINT; with a username and key, USERNAME and MESSAGE-INTEGRITY too (and
/// USE-CANDIDATE first when `nominate`). `None` for a username longer than [`USERNAME_MAX`].
pub fn binding_request(
    transaction: &[u8; TRANSACTION_LENGTH],
    credentials: Option<(&str, &[u8])>,
    nominate: bool,
) -> Option<Vec<u8>> {
    let mut out = header(BINDING_REQUEST, transaction);
    if nominate {
        credentials?;
        append(&mut out, ATTR_USE_CANDIDATE, &[]);
    }
    if let Some((username, _)) = credentials {
        if username.is_empty() || username.len() > USERNAME_MAX {
            return None;
        }
        append(&mut out, ATTR_USERNAME, username.as_bytes());
    }
    Some(finish(out, credentials.map(|(_, key)| key)))
}

/// A Binding success response with XOR-MAPPED-ADDRESS, MESSAGE-INTEGRITY when keyed, and FINGERPRINT.
pub fn binding_success(transaction: &[u8; TRANSACTION_LENGTH], mapped: SocketAddr, key: Option<&[u8]>) -> Vec<u8> {
    let mut out = header(BINDING_SUCCESS, transaction);
    let mut value = vec![0u8, 0];
    value.extend_from_slice(&(mapped.port() ^ (MAGIC_COOKIE >> 16) as u16).to_be_bytes());
    match mapped.ip() {
        IpAddr::V4(v4) => {
            value[1] = 1;
            value.extend_from_slice(&v4.octets());
        }
        IpAddr::V6(v6) => {
            value[1] = 2;
            value.extend_from_slice(&v6.octets());
        }
    }
    for i in 4..value.len() {
        value[i] ^= out[i]; // header bytes 4..: cookie || transaction
    }
    append(&mut out, ATTR_XOR_MAPPED_ADDRESS, &value);
    finish(out, key)
}

pub fn random_transaction() -> [u8; TRANSACTION_LENGTH] {
    let mut transaction = [0u8; TRANSACTION_LENGTH];
    szfriends_crypto::random_bytes(&mut transaction);
    transaction
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requests_and_answers_round_trip_with_integrity() {
        let t = random_transaction();
        let request = binding_request(&t, Some(("abcd:efgh", b"password-password-1234")), true).unwrap();
        let parsed = parse(&request).unwrap();
        assert_eq!(parsed.kind, BINDING_REQUEST);
        assert!(parsed.use_candidate && parsed.fingerprint);
        assert_eq!(parsed.username, Some(&b"abcd:efgh"[..]));
        assert!(check_integrity(&request, &parsed, b"password-password-1234"));
        assert!(!check_integrity(&request, &parsed, b"other"));
        for mapped in ["192.0.2.7:4000", "[2001:db8::5]:65535"] {
            let mapped: SocketAddr = mapped.parse().unwrap();
            let answer = binding_success(&t, mapped, None);
            let parsed = parse(&answer).unwrap();
            assert_eq!(parsed.mapped, Some(mapped));
            assert_eq!(parsed.transaction, t);
        }
        let mut broken = binding_request(&t, None, false).unwrap();
        let last = broken.len() - 1;
        broken[last] ^= 1;
        assert!(parse(&broken).is_none());
        assert_eq!(crc32(b"123456789"), 0xcbf4_3926);
    }
}

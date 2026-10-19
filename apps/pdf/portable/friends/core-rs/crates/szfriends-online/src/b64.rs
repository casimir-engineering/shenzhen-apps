//! Base64 as the host protocol and the links use it: base64url without padding in canonical form (HOST-PROTOCOL.md
//! § Transport: the URL alphabet only, unused trailing bits zero), and standard base64 with padding for the TURN REST
//! credential, which the host computes and libjuice sends as it is.

const URL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const STANDARD: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn encode_with(bytes: &[u8], alphabet: &[u8; 64], pad: bool) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        let symbols = chunk.len() + 1;
        for i in 0..4 {
            if i < symbols {
                out.push(alphabet[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else if pad {
                out.push('=');
            }
        }
    }
    out
}

/// Base64url without padding.
pub fn encode_url(bytes: &[u8]) -> String {
    encode_with(bytes, URL, false)
}

/// Standard base64 with padding (RFC 4648 § 4).
pub fn encode_standard(bytes: &[u8]) -> String {
    encode_with(bytes, STANDARD, true)
}

/// Strict base64url: no padding, the URL alphabet only, no length of 1 mod 4, unused trailing bits zero, so one string
/// names one byte sequence. `length` 0 accepts any length.
pub fn decode_url(text: &str, length: usize) -> Option<Vec<u8>> {
    if text.len() % 4 == 1 {
        return None;
    }
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let (mut buffer, mut bits) = (0u32, 0u32);
    for c in text.bytes() {
        let value = URL.iter().position(|&a| a == c)? as u32;
        buffer = (buffer << 6) | value;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    if bits > 0 && buffer != 0 {
        return None;
    }
    (length == 0 || out.len() == length).then_some(out)
}

/// A JSON value that is a canonical base64url string of exactly `length` bytes (any length for 0).
pub fn decode_value(value: Option<&serde_json::Value>, length: usize) -> Option<Vec<u8>> {
    decode_url(value?.as_str()?, length)
}

/// The same, as an array.
pub fn decode_array<const N: usize>(value: Option<&serde_json::Value>) -> Option<[u8; N]> {
    decode_value(value, N)?.try_into().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_and_refuses_what_is_not_canonical() {
        for length in 0..40 {
            let bytes: Vec<u8> = (0..length).map(|i| (i * 37 + 11) as u8).collect();
            let text = encode_url(&bytes);
            assert!(!text.contains('='));
            assert_eq!(decode_url(&text, 0).unwrap(), bytes);
        }
        assert_eq!(encode_standard(b"ab"), "YWI=");
        assert_eq!(encode_url(&[0xfb, 0xff]), "-_8");
        // "-_9" decodes to the same bytes with a stray bit set: refused.
        assert!(decode_url("-_9", 0).is_none());
        assert!(decode_url("YWI=", 0).is_none());
        assert!(decode_url("Y", 0).is_none());
        assert!(decode_url("AAAA", 2).is_none());
    }
}

//! Session descriptions and ICE server URLs (`SZFriendsOnlineDescription.m`): what the transport accepts from the
//! authenticated exchange and hands to the stack. The fingerprint check here is half of rule 4 in
//! `SZFriendsOnlineTransport.h`; libdatachannel's DTLS verification against the applied SDP is the other half.

use super::{OnlineError, RelayCredentials};
use crate::signal::items::PAYLOAD_MAX;

/// Credentials and host names in a TURN URI are short; anything longer is not from the signed host list.
const URI_FIELD_MAX: usize = 512;

/// A checked description: at most 4,096 bytes of printable ASCII, v=0, exactly one media section and it a data
/// channel, ICE credentials, and at least one a=fingerprint, every one SHA-256 and all equal. Candidates are taken
/// out of the SDP so they pass the same rules as trickled ones.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Description {
    /// Without candidate or end-of-candidates lines, CRLF endings.
    pub sdp: String,
    pub candidates: Vec<String>,
    pub fingerprint: [u8; 32],
    pub mid: String,
}

/// "AB:CD:..." (32 pairs) to bytes.
pub fn fingerprint_from_hex(hex: &str) -> Option<[u8; 32]> {
    let pairs: Vec<&str> = hex.split(':').collect();
    if pairs.len() != 32 {
        return None;
    }
    let mut out = [0u8; 32];
    for (byte, pair) in out.iter_mut().zip(pairs) {
        if pair.len() != 2 || !pair.bytes().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        *byte = u8::from_str_radix(pair, 16).ok()?;
    }
    Some(out)
}

impl Description {
    pub fn parse(sdp: &str) -> Result<Self, OnlineError> {
        let printable = sdp.bytes().all(|c| c == b'\r' || c == b'\n' || (0x20..=0x7e).contains(&c));
        if sdp.is_empty() || sdp.len() > PAYLOAD_MAX || !printable {
            return Err(OnlineError::DescriptionInvalid);
        }
        let (mut kept, mut candidates) = (Vec::new(), Vec::new());
        let (mut fingerprint, mut mid): (Option<[u8; 32]>, Option<String>) = (None, None);
        let (mut sections, mut ufrag, mut password) = (0, false, false);
        let normalized = sdp.replace("\r\n", "\n");
        for line in normalized.split('\n') {
            if line.is_empty() {
                continue;
            }
            if let Some(candidate) = line.strip_prefix("a=candidate:") {
                candidates.push(format!("candidate:{candidate}"));
                continue;
            }
            if line == "a=end-of-candidates" {
                continue;
            }
            if line.starts_with("m=") {
                sections += 1;
                if !line.starts_with("m=application ") || !line.ends_with(" webrtc-datachannel") {
                    return Err(OnlineError::DescriptionInvalid);
                }
            } else if let Some(value) = line.strip_prefix("a=fingerprint:") {
                let parsed = value
                    .get(..8)
                    .filter(|p| p.eq_ignore_ascii_case("sha-256 "))
                    .and_then(|_| fingerprint_from_hex(&value[8..]));
                match (parsed, fingerprint) {
                    (Some(p), None) => fingerprint = Some(p),
                    (Some(p), Some(f)) if p == f => {}
                    _ => return Err(OnlineError::FingerprintMismatch),
                }
            } else if let Some(value) = line.strip_prefix("a=mid:") {
                mid.get_or_insert_with(|| value.to_owned());
            } else if line.starts_with("a=ice-ufrag:") {
                ufrag = true;
            } else if line.starts_with("a=ice-pwd:") {
                password = true;
            }
            kept.push(line);
        }
        let mid = mid.filter(|m| !m.is_empty() && m.len() <= 32);
        if kept.first() != Some(&"v=0") || sections != 1 || !ufrag || !password || mid.is_none() {
            return Err(OnlineError::DescriptionInvalid);
        }
        let fingerprint = fingerprint.ok_or(OnlineError::FingerprintMismatch)?;
        let mut sdp = kept.join("\r\n");
        sdp.push_str("\r\n");
        Ok(Self { sdp, candidates, fingerprint, mid: mid.expect("checked") })
    }
}

/// host, host:port, [v6] or [v6]:port; the host a DNS name or a literal, nothing else.
fn host_port(text: &str) -> bool {
    let allowed = |c: u8| c.is_ascii_alphanumeric() || b".-:[]".contains(&c);
    if text.is_empty() || text.len() > URI_FIELD_MAX || !text.bytes().all(allowed) {
        return false;
    }
    let port = if let Some(rest) = text.strip_prefix('[') {
        let Some(close) = rest.find(']').filter(|c| *c >= 1) else { return false };
        let tail = &rest[close + 1..];
        if tail.is_empty() {
            None
        } else if let Some(port) = tail.strip_prefix(':') {
            Some(port)
        } else {
            return false;
        }
    } else {
        let parts: Vec<&str> = text.split(':').collect();
        if parts.len() > 2 || parts[0].is_empty() || parts[0].contains('[') {
            return false;
        }
        parts.get(1).copied()
    };
    port.is_none_or(|p| {
        !p.is_empty() && p.len() <= 5 && p.parse::<u32>().is_ok_and(|v| (1..=65535).contains(&v) && v.to_string() == p)
    })
}

/// "stun:host[:port]" with nothing else.
pub fn stun_uri_valid(uri: &str) -> bool {
    uri.strip_prefix("stun:").is_some_and(host_port)
}

fn percent_encoded(text: &str) -> String {
    text.bytes()
        .map(|c| {
            if c.is_ascii_alphanumeric() || b"-._~".contains(&c) {
                (c as char).to_string()
            } else {
                format!("%{c:02X}")
            }
        })
        .collect()
}

/// libdatachannel's ICE server URL for TURN over UDP, credentials percent-encoded (usernames hold a colon).
pub fn turn_server_url(relay: &RelayCredentials, now: f64) -> Result<String, OnlineError> {
    let host = relay.turn_uri.strip_prefix("turn:").map(|h| h.strip_suffix("?transport=udp").unwrap_or(h));
    let Some(host) = host.filter(|h| host_port(h)) else { return Err(OnlineError::NotAuthorized) };
    let short = |s: &str| !s.is_empty() && s.len() <= URI_FIELD_MAX;
    if !short(&relay.username) || !short(&relay.credential) || relay.expires <= now {
        return Err(OnlineError::NotAuthorized);
    }
    Ok(format!("turn:{}:{}@{host}?transport=udp", percent_encoded(&relay.username), percent_encoded(&relay.credential)))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SDP: &str = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\nm=application 9 UDP/DTLS/SCTP \
webrtc-datachannel\r\nc=IN IP4 0.0.0.0\r\na=mid:0\r\na=ice-ufrag:abcd\r\na=ice-pwd:0123456789012345678901\r\n\
a=fingerprint:sha-256 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:\
CC:DD:EE:FF\r\na=candidate:1 1 UDP 1 127.0.0.1 5000 typ host\r\na=end-of-candidates\r\n";

    const FINGERPRINT: &str = "00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:\
CC:DD:EE:FF";

    #[test]
    fn descriptions_are_checked_and_lose_their_candidates() {
        let description = Description::parse(SDP).unwrap();
        assert_eq!(description.mid, "0");
        assert_eq!(description.candidates, vec!["candidate:1 1 UDP 1 127.0.0.1 5000 typ host"]);
        assert!(!description.sdp.contains("candidate"));
        assert_eq!(description.fingerprint[10], 0xaa);
        let other = format!("a=mid:0\r\na=fingerprint:sha-256 01{}", &FINGERPRINT[2..]);
        let second = SDP.replace("a=mid:0", &other);
        assert_eq!(Description::parse(&second), Err(OnlineError::FingerprintMismatch));
        let audio = SDP.replace("m=application 9 UDP/DTLS/SCTP webrtc-datachannel", "m=audio 9 RTP/AVP 0");
        assert_eq!(Description::parse(&audio), Err(OnlineError::DescriptionInvalid));
    }

    #[test]
    fn turn_urls_encode_their_credentials() {
        let relay = RelayCredentials {
            turn_uri: "turn:127.0.0.1:3478?transport=udp".into(),
            username: "1700000000:abc".into(),
            credential: "x+y/z=".into(),
            expires: 2e9,
        };
        assert_eq!(
            turn_server_url(&relay, 1e9).unwrap(),
            "turn:1700000000%3Aabc:x%2By%2Fz%3D@127.0.0.1:3478?transport=udp"
        );
        assert!(turn_server_url(&relay, 3e9).is_err());
        assert!(stun_uri_valid("stun:[::1]:3478") && !stun_uri_valid("stun:a:b:c") && !stun_uri_valid("turn:x"));
    }
}

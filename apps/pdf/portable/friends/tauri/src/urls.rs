//! Values the bridge acts on itself: the web and mail links a friend's message may open, the system settings a
//! Nearby notice may open, and the app's Friends link URLs (PROTOCOL.md § Links), checked as the Electron bridge
//! checks them (`electron/friends/validate.cjs`).

use tauri::Url;

/// Links in a friend's message open only through the panel's link menu, and only these kinds.
pub fn external_url(value: &str) -> Option<String> {
    if value.len() > 4096 {
        return None;
    }
    let url = Url::parse(value).ok()?;
    match url.scheme() {
        "mailto" => Some(url.to_string()),
        "http" | "https" if url.host_str().is_some_and(|h| !h.is_empty()) && url.username().is_empty() => {
            url.password().is_none().then(|| url.to_string())
        }
        _ => None,
    }
}

/// The system settings a Nearby notice can open, per system. None where the system has no such page.
pub fn settings_url(target: &str) -> Option<&'static str> {
    if cfg!(target_os = "macos") {
        return match target {
            "local_network_privacy" => {
                Some("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
            }
            "bluetooth_privacy" => Some("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"),
            "bluetooth" => Some("x-apple.systempreferences:com.apple.BluetoothSettings"),
            "wifi" => Some("x-apple.systempreferences:com.apple.wifi-settings-extension"),
            _ => None,
        };
    }
    if cfg!(windows) {
        return match target {
            "bluetooth" => Some("ms-settings:bluetooth"),
            "wifi" => Some("ms-settings:network-wifi"),
            _ => None,
        };
    }
    // iOS opens the app's own page in Settings, where its Local Network and Bluetooth switches are; it links to no
    // other page of Settings.
    if cfg!(target_os = "ios") {
        return matches!(target, "local_network_privacy" | "bluetooth_privacy").then_some("app-settings:");
    }
    // Android: the plugin's Kotlin half turns these into the system's settings screens.
    if cfg!(target_os = "android") {
        return match target {
            "bluetooth_privacy" => Some("szfriends-settings:app"),
            "bluetooth" => Some("szfriends-settings:bluetooth"),
            "wifi" => Some("szfriends-settings:wifi"),
            _ => None,
        };
    }
    None
}

fn base64url_decode(text: &str) -> Option<Vec<u8>> {
    let value = |c: u8| match c {
        b'A'..=b'Z' => Some(c - b'A'),
        b'a'..=b'z' => Some(c - b'a' + 26),
        b'0'..=b'9' => Some(c - b'0' + 52),
        b'-' => Some(62),
        b'_' => Some(63),
        _ => None,
    };
    if text.len() % 4 == 1 {
        return None;
    }
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0u32);
    for &c in text.as_bytes() {
        acc = (acc << 6) | value(c)? as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    // Canonical: no unused trailing bit is set, so re-encoding gives the same text.
    (acc == 0).then_some(out)
}

/// `<scheme>://friends/link#<payload>` → the payload, when it is a well-formed friend or download link.
pub fn link_payload(url_text: &str, scheme: &str) -> Option<String> {
    if url_text.len() > 512 {
        return None;
    }
    let url = Url::parse(url_text).ok()?;
    let plain = url.scheme() == scheme
        && url.host_str() == Some("friends")
        && url.path() == "/link"
        && url.username().is_empty()
        && url.password().is_none()
        && url.port().is_none()
        && url.query().is_none();
    let payload = url.fragment().filter(|f| plain && !f.is_empty())?;
    let (kind, encoded) = (payload.get(..2)?, payload.get(2..)?);
    let bytes = base64url_decode(encoded)?;
    if bytes.first() != Some(&1) {
        return None;
    }
    match kind {
        "d." => (bytes.len() == 49).then(|| payload.to_owned()),
        "f." => friend_link_is_plain(&bytes).then(|| payload.to_owned()),
        _ => None,
    }
}

/// Version, key (32), invite (16), ID length and ID (3 to 64 of lowercase words), name length and name (0 to 160
/// bytes of UTF-8 without control characters).
fn friend_link_is_plain(bytes: &[u8]) -> bool {
    let mut offset = 49;
    let Some(&id_length) = bytes.get(offset) else { return false };
    offset += 1;
    let id_length = id_length as usize;
    if !(3..=64).contains(&id_length) || offset + id_length > bytes.len() {
        return false;
    }
    let id = &bytes[offset..offset + id_length];
    let words: Vec<&[u8]> = id.split(|&b| b == b'-').collect();
    if words.len() < 2 || words.iter().any(|w| w.is_empty() || !w.iter().all(u8::is_ascii_lowercase)) {
        return false;
    }
    offset += id_length;
    let Some(&name_length) = bytes.get(offset) else { return false };
    offset += 1;
    if name_length > 160 || offset + name_length as usize != bytes.len() {
        return false;
    }
    std::str::from_utf8(&bytes[offset..]).is_ok_and(|name| !name.chars().any(|c| c.is_control()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encode(bytes: &[u8]) -> String {
        const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let mut out = String::new();
        for chunk in bytes.chunks(3) {
            let n = chunk.iter().enumerate().fold(0u32, |acc, (i, &b)| acc | (b as u32) << (16 - 8 * i));
            for i in 0..=chunk.len() {
                out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char);
            }
        }
        out
    }

    #[test]
    fn links_open_only_for_the_web_and_email() {
        assert_eq!(external_url("https://example.com/a?b=1").as_deref(), Some("https://example.com/a?b=1"));
        assert_eq!(external_url("mailto:mei@example.com").as_deref(), Some("mailto:mei@example.com"));
        for url in
            ["file:///etc/passwd", "javascript:alert(1)", "szfriends:mention?ref=0", "https://user:pw@example.com/"]
        {
            assert_eq!(external_url(url), None, "{url}");
        }
        assert_eq!(settings_url("../../evil"), None);
    }

    #[test]
    fn friends_link_urls_are_checked_as_protocol_md_says() {
        let download = encode(&[[1u8].as_slice(), &[7u8; 48]].concat());
        assert_eq!(
            link_payload(&format!("shenzhen3d://friends/link#d.{download}"), "shenzhen3d"),
            Some(format!("d.{download}"))
        );
        let (id, name) = (b"amber-falcon".as_slice(), "Mei Lin".as_bytes());
        let friend = encode(&[&[1u8][..], &[3u8; 48], &[id.len() as u8], id, &[name.len() as u8], name].concat());
        assert_eq!(
            link_payload(&format!("shenzhen3d://friends/link#f.{friend}"), "shenzhen3d"),
            Some(format!("f.{friend}"))
        );
        let wrong_version = encode(&[[2u8].as_slice(), &[0u8; 48]].concat());
        for url in [
            format!("shenzhenpdf://friends/link#d.{download}"),
            format!("shenzhen3d://friends/other#d.{download}"),
            format!("shenzhen3d://friends/link?x=1#d.{download}"),
            format!("shenzhen3d://friends/link#d.{download}A"),
            format!("shenzhen3d://friends/link#d.{download}="),
            format!("shenzhen3d://friends/link#x.{download}"),
            format!("shenzhen3d://friends/link#d.{wrong_version}"),
            format!("shenzhen3d://friends/link#f.{}", &friend[..friend.len() - 2]),
            format!("shenzhen3d://friends/link#d.{}", "A".repeat(600)),
        ] {
            assert_eq!(link_payload(&url, "shenzhen3d"), None, "{url}");
        }
    }
}

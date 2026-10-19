//! The form a mention takes inside a message's text, read and written in one place (`SZFriendsMentions.{h,m}`,
//! PROTOCOL.md § Mentions, ADR 0007). A mention travels as a Markdown link with Friends' own scheme:
//!
//! ```text
//! [@Mei Lin](szfriends:mention?id=jasmine-street&key=C7p4jaaHK1zWWJGVH-YasjrlEk8qfJvd3KLmn0IFY3E)
//! ```
//!
//! The link text is "@" and the name the sender sees, Markdown-escaped; the destination carries the Friends ID and the
//! identity key (base64url, no padding). Only a sending helper writes this form; every reader resolves it against its
//! own Friends list, and a receiving helper turns every Friends link that is not a well-formed mention into plain
//! text before storing it. Positions are UTF-16 offsets, as the helper's are.

mod checks;
mod html;
mod scan;

pub use checks::{mentions_checked, mentions_neutralized};
pub use scan::text_links;

use super::text::{clusters, is_control_or_format, is_space_or_newline, trim};

/// At most this many mentions in one message; the receiving helper shows any beyond them as plain text.
pub const MENTIONS_MAX: usize = 20;
/// A mention's name is at most this many Unicode scalar values.
pub const MENTION_NAME_MAX: usize = 64;
/// Where send_message's text puts each mention, in the order of its `mentions` array.
pub const MENTION_PLACEHOLDER: char = '\u{FFFC}';

pub(crate) const MENTION_DESTINATION: &str = "szfriends:mention?id=";
pub(crate) const MENTION_KEY_FIELD: &str = "&key=";
pub(crate) const KEY_CHARACTERS: usize = 43;

/// One link to Friends' own scheme found in a text: a mention, or anything else that points at szfriends:.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TextLink {
    /// The whole link, as UTF-16 (start, length) in the text it was found in.
    pub range: (usize, usize),
    /// The words a renderer would show for it, unescaped: an inline link's text ("@Mei Lin"), an autolink's address,
    /// or a reference definition's whole line.
    pub shown_text: String,
    /// Set only for a well-formed mention: the name without its "@", the Friends ID as written, the key.
    pub name: Option<String>,
    pub friends_id: Option<String>,
    pub identity_key: Option<[u8; 32]>,
    pub is_mention: bool,
}

impl TextLink {
    pub(crate) fn end(&self) -> usize {
        self.range.0 + self.range.1
    }

    pub(crate) fn plain(range: (usize, usize), shown_text: String) -> Self {
        Self { range, shown_text, name: None, friends_id: None, identity_key: None, is_mention: false }
    }
}

pub(crate) fn is_ascii_punctuation(c: u16) -> bool {
    (u16::from(b'!')..=u16::from(b'/')).contains(&c)
        || (u16::from(b':')..=u16::from(b'@')).contains(&c)
        || (u16::from(b'[')..=u16::from(b'`')).contains(&c)
        || (u16::from(b'{')..=u16::from(b'~')).contains(&c)
}

/// What could start Markdown structure inside a line in the engines hosts use.
fn needs_escape(c: char) -> bool {
    matches!(c, '\\' | '`' | '*' | '_' | '[' | ']' | '<' | '>' | '!' | '&' | '~' | '|' | '$' | '^' | '=')
}

/// Markdown that shows `plain` exactly: the punctuation that could start emphasis, a link, code, math or HTML is
/// backslash-escaped.
pub fn markdown_literal(plain: &str) -> String {
    let mut escaped = String::with_capacity(plain.len() + 8);
    for c in plain.chars() {
        if needs_escape(c) {
            escaped.push('\\');
        }
        escaped.push(c);
    }
    escaped
}

/// CommonMark's backslash escapes: before ASCII punctuation the backslash goes; before anything else it stays.
pub(crate) fn unescaped(markdown: &str) -> String {
    let mut plain = String::with_capacity(markdown.len());
    let mut chars = markdown.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' {
            if let Some(&next) = chars.peek() {
                if next.is_ascii_punctuation() {
                    plain.push(next);
                    chars.next();
                    continue;
                }
            }
        }
        plain.push(c);
    }
    plain
}

pub(crate) fn name_is_valid(name: &str) -> bool {
    if name.is_empty() || name.chars().count() > MENTION_NAME_MAX {
        return false;
    }
    let (Some(first), Some(last)) = (name.chars().next(), name.chars().last()) else { return false };
    if is_space_or_newline(first) || is_space_or_newline(last) {
        return false;
    }
    // One line of text: no control characters and no line or paragraph separators.
    !name.chars().any(|c| is_control_or_format(c) || c == '\u{2028}' || c == '\u{2029}')
}

/// Two or three words of 3 to 8 lowercase letters (ADR 0006 rule 1); the word list is the helper's to check.
pub(crate) fn id_is_well_formed(friends_id: &str) -> bool {
    let words: Vec<&str> = friends_id.split('-').collect();
    (2..=3).contains(&words.len())
        && words.iter().all(|w| (3..=8).contains(&w.len()) && w.bytes().all(|b| b.is_ascii_lowercase()))
}

const BASE64URL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// A key as mentions and add_from_mention carry it: base64url, no padding.
pub fn key_string(key: &[u8]) -> String {
    let mut out = String::with_capacity(key.len().div_ceil(3) * 4);
    for chunk in key.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for i in 0..=chunk.len() {
            out.push(BASE64URL[(n >> (18 - 6 * i) & 63) as usize] as char);
        }
    }
    out
}

/// The key a mention carries, or None unless exactly 32 bytes in the canonical 43-character form.
pub fn key_from_string(text: &str) -> Option<[u8; 32]> {
    if text.len() != KEY_CHARACTERS {
        return None;
    }
    let mut bits: u32 = 0;
    let mut count = 0;
    let mut bytes = Vec::with_capacity(33);
    for c in text.bytes() {
        let value = BASE64URL.iter().position(|b| *b == c)? as u32;
        bits = (bits << 6) | value;
        count += 6;
        if count >= 8 {
            count -= 8;
            bytes.push((bits >> count) as u8);
            bits &= (1 << count) - 1;
        }
    }
    // Canonical only: the spare bits are zero, so one key has exactly one spelling.
    if bits != 0 {
        return None;
    }
    bytes.try_into().ok()
}

/// What a mention calls someone the sender sees as `name` and `friends_id`: the name, trimmed, or else the Friends ID
/// with U+2011 between its words; cut to [`MENTION_NAME_MAX`] scalar values on a composed character.
pub fn mention_name(name: Option<&str>, friends_id: Option<&str>) -> String {
    let trimmed = trim(name.unwrap_or(""));
    let chosen = if trimmed.is_empty() { friends_id.unwrap_or("").replace('-', "\u{2011}") } else { trimmed.into() };
    if chosen.chars().count() <= MENTION_NAME_MAX {
        return chosen;
    }
    let mut cut = String::new();
    let mut scalars = 0;
    for piece in clusters(&chosen) {
        let count = piece.chars().count();
        if scalars + count > MENTION_NAME_MAX {
            break;
        }
        scalars += count;
        cut.push_str(&piece);
    }
    trim(&cut).to_owned()
}

/// The well-formed mention link for one person, or None when the name is empty or too long, the ID is not two or
/// three words, or the key is not 32 bytes.
pub fn mention_link(name: &str, friends_id: &str, identity_key: &[u8]) -> Option<String> {
    if !name_is_valid(name) || !id_is_well_formed(friends_id) || identity_key.len() != 32 {
        return None;
    }
    Some(format!(
        "[{}]({MENTION_DESTINATION}{friends_id}{MENTION_KEY_FIELD}{})",
        markdown_literal(&format!("@{name}")),
        key_string(identity_key)
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_and_links() {
        let key = key_from_string("C7p4jaaHK1zWWJGVH-YasjrlEk8qfJvd3KLmn0IFY3E").unwrap();
        assert_eq!(key_string(&key), "C7p4jaaHK1zWWJGVH-YasjrlEk8qfJvd3KLmn0IFY3E");
        assert!(key_from_string("C7p4jaaHK1zWWJGVH-YasjrlEk8qfJvd3KLmn0IFY3F").is_none());
        assert_eq!(
            mention_link("Mei_Lin", "jasmine-street", &key).unwrap(),
            "[@Mei\\_Lin](szfriends:mention?id=jasmine-street&key=C7p4jaaHK1zWWJGVH-YasjrlEk8qfJvd3KLmn0IFY3E)"
        );
        assert_eq!(mention_name(Some("  "), Some("tulip-canyon")), "tulip\u{2011}canyon");
        assert_eq!(unescaped("\\_a\\b"), "_a\\b");
    }
}

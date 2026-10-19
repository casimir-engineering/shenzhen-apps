//! Finding links to Friends' own scheme (`SZFriendsTextLinks`). The search starts from each place a renderer reads as
//! "szfriends:" (escaped, spelled with character references, or broken by tabs and line breaks) and looks around it
//! for the link structure, so a message without one costs a substring search or two, and a hostile 32 KB message a
//! bounded amount of work per occurrence.

use super::html::{html_tag, TagScan, TAG_STATES};
use super::{
    id_is_well_formed, is_ascii_punctuation, key_from_string, markdown_literal, name_is_valid, unescaped, TextLink,
    KEY_CHARACTERS, MENTION_DESTINATION, MENTION_KEY_FIELD,
};
use crate::presentation::text::{from_utf16, utf16};

/// How far around an occurrence a link's text and destination are looked for.
pub(super) const LINK_TEXT_MAX: usize = 1024;
pub(super) const LINK_DESTINATION_MAX: usize = 2048;

/// The text as UTF-16 units with, for each, whether a backslash escapes it, and the HTML tag readings carried forward.
pub(super) struct Scan {
    pub chars: Vec<u16>,
    pub escaped: Vec<bool>,
    pub tags: TagScan,
}

impl Scan {
    pub fn len(&self) -> usize {
        self.chars.len()
    }

    pub fn is_unescaped(&self, index: usize, c: u8) -> bool {
        index < self.len() && self.chars[index] == u16::from(c) && !self.escaped[index]
    }

    pub fn substring(&self, from: usize, to: usize) -> String {
        from_utf16(&self.chars[from..to])
    }

    fn is(&self, index: usize, c: u8) -> bool {
        self.chars[index] == u16::from(c)
    }
}

/// The unescaped "[" matching the unescaped "]" at `close`, within LINK_TEXT_MAX.
fn opening_bracket(scan: &Scan, close: usize) -> Option<usize> {
    let mut depth = 0i64;
    let floor = close.saturating_sub(LINK_TEXT_MAX);
    let mut i = close;
    while i > floor {
        let j = i - 1;
        i -= 1;
        if scan.escaped[j] {
            continue;
        }
        if scan.is(j, b']') {
            depth += 1;
        } else if scan.is(j, b'[') {
            if depth == 0 {
                return Some(j);
            }
            depth -= 1;
        }
    }
    None
}

/// The well-formed mention whose destination starts at `start`, preceded by "](" and the link text at `open`; None
/// when anything differs from what [`super::mention_link`] writes.
fn strict_mention(scan: &Scan, open: usize, close: usize, start: usize) -> Option<TextLink> {
    let prefix = MENTION_DESTINATION.len();
    if start + prefix > scan.len() || scan.substring(start, start + prefix) != MENTION_DESTINATION {
        return None;
    }
    let mut id_end = start + prefix;
    while id_end < scan.len() && id_end - start < 64 {
        let c = scan.chars[id_end];
        if !((u16::from(b'a')..=u16::from(b'z')).contains(&c) || c == u16::from(b'-')) {
            break;
        }
        id_end += 1;
    }
    let key_start = id_end + MENTION_KEY_FIELD.len();
    let key_end = key_start + KEY_CHARACTERS;
    if key_end >= scan.len() || scan.substring(id_end, key_start) != MENTION_KEY_FIELD || !scan.is(key_end, b')') {
        return None;
    }
    let friends_id = scan.substring(start + prefix, id_end);
    let key = key_from_string(&scan.substring(key_start, key_end));
    let label = scan.substring(open + 1, close);
    let written = label.strip_prefix('@')?;
    if !id_is_well_formed(&friends_id) {
        return None;
    }
    let key = key?;
    let name = unescaped(written);
    // Exactly the writer's escaping, so one name has one spelling and nothing hides in an unusual escape.
    if !name_is_valid(&name) || markdown_literal(&name) != written {
        return None;
    }
    Some(TextLink {
        range: (open, key_end + 1 - open),
        shown_text: format!("@{name}"),
        name: Some(name),
        friends_id: Some(friends_id),
        identity_key: Some(key),
        is_mention: true,
    })
}

/// Where an inline link whose destination starts at `start` ends (just past its ")"). Angle-bracketed destinations
/// end at ">", bare ones at the first unescaped ")" outside parentheses; never past a blank line.
fn inline_link_end(scan: &Scan, start: usize, angled: bool) -> Option<usize> {
    let mut depth = 0i64;
    let limit = scan.len().min(start + LINK_DESTINATION_MAX);
    let mut in_destination = true;
    for i in start..limit {
        if scan.is(i, b'\n') && i + 1 < limit && scan.is(i + 1, b'\n') {
            return None;
        }
        if scan.escaped[i] {
            continue;
        }
        if angled && in_destination {
            if scan.is(i, b'>') {
                in_destination = false;
            }
            continue;
        }
        if scan.is(i, b'(') {
            depth += 1;
        } else if scan.is(i, b')') {
            if depth == 0 {
                return Some(i + 1);
            }
            depth -= 1;
        }
    }
    None
}

/// An autolink, <szfriends:...>, whose address starts at `at`; None when no ">" closes it on the same line.
fn autolink(scan: &Scan, at: usize) -> Option<TextLink> {
    if at == 0 || !scan.is_unescaped(at - 1, b'<') {
        return None;
    }
    let mut i = at;
    while i < scan.len() && i < at + LINK_DESTINATION_MAX {
        let c = scan.chars[i];
        if [b' ', b'\n', b'\t', b'<'].iter().any(|b| c == u16::from(*b)) {
            return None;
        }
        if c == u16::from(b'>') {
            return Some(TextLink::plain((at - 1, i + 2 - at), scan.substring(at, i)));
        }
        i += 1;
    }
    None
}

/// An inline link or a reference definition whose destination starts at `at`.
fn destination_link(scan: &Scan, at: usize) -> Option<TextLink> {
    // Back over an optional "<" and spaces (one line break at most) to "(" or, for a reference definition, ":".
    let mut i = at;
    let mut angled = false;
    if i > 0 && scan.is_unescaped(i - 1, b'<') {
        angled = true;
        i -= 1;
    }
    let mut breaks = 0;
    while i > 0 && (scan.is(i - 1, b' ') || scan.is(i - 1, b'\t') || scan.is(i - 1, b'\n')) {
        if scan.is(i - 1, b'\n') {
            breaks += 1;
            if breaks > 1 {
                return None;
            }
        }
        i -= 1;
    }
    if i < 2 {
        return None;
    }
    let marker = scan.chars[i - 1];
    let close = i - 2;
    let is_marker = marker == u16::from(b'(') || marker == u16::from(b':');
    if scan.escaped[i - 1] || !is_marker || !scan.is_unescaped(close, b']') {
        return None;
    }
    let open = opening_bracket(scan, close)?;
    if marker == u16::from(b':') {
        // A reference definition: "[label]: szfriends:..." opening its line after at most three spaces.
        let mut line_start = open;
        while line_start > 0 && scan.is(line_start - 1, b' ') && open - line_start < 3 {
            line_start -= 1;
        }
        if line_start > 0 && !scan.is(line_start - 1, b'\n') {
            return None;
        }
        let mut line_end = at;
        while line_end < scan.len() && !scan.is(line_end, b'\n') {
            line_end += 1;
        }
        return Some(TextLink::plain((line_start, line_end - line_start), scan.substring(line_start, line_end)));
    }
    if !angled && breaks == 0 && i == at {
        if let Some(mention) = strict_mention(scan, open, close, at) {
            return Some(mention);
        }
    }
    let end = inline_link_end(scan, at, angled)?;
    Some(TextLink::plain((open, end - open), unescaped(&scan.substring(open + 1, close))))
}

/// A wikilink, [[szfriends:...]] or [[szfriends:...|words]], whose target starts at `at` after spaces.
fn wikilink(scan: &Scan, at: usize) -> Option<TextLink> {
    let mut start = at;
    while start > 0 && (scan.is(start - 1, b' ') || scan.is(start - 1, b'\t')) {
        start -= 1;
    }
    if start < 2 || !scan.is_unescaped(start - 1, b'[') || !scan.is_unescaped(start - 2, b'[') {
        return None;
    }
    let mut pipe: Option<usize> = None;
    let mut i = at;
    while i + 1 < scan.len() && i < at + LINK_DESTINATION_MAX {
        if scan.is(i, b'\n') && (pipe.is_none() || scan.is(i + 1, b'\n')) {
            return None;
        }
        if !scan.escaped[i] {
            if scan.is(i, b'|') && pipe.is_none() {
                pipe = Some(i);
            }
            if scan.is(i, b']') && scan.is_unescaped(i + 1, b']') {
                let shown = match pipe {
                    None => scan.substring(start, i),
                    Some(p) => scan.substring(p + 1, i),
                };
                return Some(TextLink::plain((start - 2, i + 2 - (start - 2)), unescaped(&shown)));
            }
        }
        i += 1;
    }
    None
}

/// The Friends link around the "szfriends:" at `at`, or None when that text is not part of a link.
fn link_around(scan: &mut Scan, at: usize) -> Option<TextLink> {
    destination_link(scan, at)
        .or_else(|| autolink(scan, at))
        .or_else(|| wikilink(scan, at))
        .or_else(|| html_tag(scan, at))
}

/// The character a reference at `at` stands for, and its length (0: none there). Only ASCII can spell
/// "szfriends:", so anything else is U+FFFD. Named: "&colon;", "&Tab;" and "&NewLine;" with the semicolon; numeric
/// ones any number of digits, ending at the semicolon or the first non-digit.
fn entity_at(chars: &[u16], at: usize) -> (u16, usize) {
    const NAMES: [(&str, u8); 3] = [("&colon;", b':'), ("&Tab;", b'\t'), ("&NewLine;", b'\n')];
    for (name, c) in NAMES {
        let matches = name.bytes().enumerate().all(|(i, b)| chars.get(at + i) == Some(&u16::from(b)));
        if matches {
            return (u16::from(c), name.len());
        }
    }
    if at + 2 >= chars.len() || chars[at + 1] != u16::from(b'#') {
        return (0, 0);
    }
    let hex = (chars[at + 2] | 0x20) == u16::from(b'x');
    let first = at + if hex { 3 } else { 2 };
    let mut value: u32 = 0;
    let mut i = first;
    while i < chars.len() {
        let c = chars[i];
        let lower = c | 0x20;
        let digit = if (u16::from(b'0')..=u16::from(b'9')).contains(&c) {
            u32::from(c - u16::from(b'0'))
        } else if hex && (u16::from(b'a')..=u16::from(b'f')).contains(&lower) {
            u32::from(lower - u16::from(b'a')) + 10
        } else {
            break;
        };
        value = (value * if hex { 16 } else { 10 } + digit).min(0x11_0000);
        i += 1;
    }
    if i == first {
        return (0, 0);
    }
    let used = i + usize::from(i < chars.len() && chars[i] == u16::from(b';')) - at;
    (if value > 0 && value < 0x80 { value as u16 } else { 0xFFFD }, used)
}

/// Every link to szfriends: in `text`, in order: inline links, autolinks, link reference definitions, wikilinks and
/// HTML tags, with the scheme as a renderer reads it.
pub fn text_links(text: &str) -> Vec<TextLink> {
    // Every spelling holds "szfriends", a reference, or a tab or line break: without any, one search or two.
    if !text.to_ascii_lowercase().contains("szfriends") && !text.contains(['&', '\t', '\n', '\r']) {
        return Vec::new();
    }
    let chars = utf16(text);
    let length = chars.len();
    let mut escaped = vec![false; length];
    for i in 1..length {
        escaped[i] = chars[i - 1] == u16::from(b'\\') && !escaped[i - 1];
    }
    // The text as a renderer reads the scheme in it; `source` holds where each character read starts.
    let mut decoded: Vec<u16> = Vec::with_capacity(length);
    let mut source: Vec<usize> = Vec::with_capacity(length);
    let mut i = 0;
    while i < length {
        let mut used =
            if chars[i] == u16::from(b'\\') && i + 1 < length && is_ascii_punctuation(chars[i + 1]) { 2 } else { 0 };
        let mut c = if used > 0 { chars[i + 1] } else { chars[i] };
        if used == 0 && c == u16::from(b'&') {
            let (entity, length_used) = entity_at(&chars, i);
            used = length_used;
            if entity != 0 {
                c = entity;
            }
        }
        if ![b'\t', b'\n', b'\r'].iter().any(|b| c == u16::from(*b)) {
            source.push(i);
            decoded.push(c);
        }
        i += used.max(1);
    }
    let scheme = b"szfriends:";
    let mut starts = Vec::new();
    for i in 0..decoded.len().saturating_sub(9) {
        let matched = scheme.iter().enumerate().all(|(m, b)| {
            let c = decoded[i + m] | if m < 9 { 0x20 } else { 0 };
            c == u16::from(*b)
        });
        if matched {
            starts.push(source[i]);
        }
    }
    let mut scan = Scan { chars, escaped, tags: TagScan { position: 0, open: [usize::MAX; TAG_STATES] } };
    let mut links: Vec<TextLink> = Vec::new();
    let mut after = 0;
    for start in starts {
        let link = if start >= after { link_around(&mut scan, start) } else { None };
        let Some(link) = link else { continue };
        // A link whose text holds links found before it replaces them: it is one link, refused whole.
        while links.last().is_some_and(|last| last.range.0 >= link.range.0 && last.end() <= link.end()) {
            links.pop();
        }
        // Otherwise links never overlap: one that starts inside the previous one is part of it.
        let floor = links.last().map_or(0, TextLink::end);
        if link.range.0 >= floor {
            after = link.end();
            links.push(link);
        }
    }
    links
}

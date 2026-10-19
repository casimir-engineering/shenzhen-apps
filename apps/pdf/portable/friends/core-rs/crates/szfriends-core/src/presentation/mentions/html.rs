//! HTML tags holding a Friends destination (`<a href="szfriends:...">`), which inline HTML and HTML blocks make a link
//! (`HTMLTag` and `ReadTag` in `SZFriendsMentions.m`). Read as loosely as any reader reads a tag: a tag opens at any
//! "<" before a letter; a quote opens a value, or is part of a name as HTML5 reads `<a x" href=...>`; only an unquoted
//! ">" closes it. A reading counts only once an "=" with no backslash before it has come before the destination, since
//! only that gives an attribute a value. Readings in the same state read the rest alike, so the one opened farthest
//! back stands for them all and the work stays linear.

use super::scan::{Scan, LINK_DESTINATION_MAX};
use super::TextLink;

const OUTSIDE: usize = 0;
const IN_DOUBLE: usize = 1;
const IN_SINGLE: usize = 2;
const QUOTES: usize = 3;
pub(super) const TAG_STATES: usize = 2 * QUOTES;
const NONE: usize = usize::MAX;

/// The tag readings open at `position` (the earliest start in each state), carried forward as occurrences come.
pub(super) struct TagScan {
    pub position: usize,
    pub open: [usize; TAG_STATES],
}

/// One character, at `i`, of every reading in `open`, for a destination at `at` (NONE: none yet). A valued reading
/// closed after the destination sets `found` and `end`.
fn read_tag(scan: &Scan, i: usize, at: usize, open: &mut [usize; TAG_STATES], found: &mut usize, end: &mut usize) {
    let mut next = [NONE; TAG_STATES];
    let c = scan.chars[i];
    let before = at == NONE || i < at;
    let equals = c == u16::from(b'=') && before && (i == 0 || scan.chars[i - 1] != u16::from(b'\\'));
    for (state, start) in open.iter().copied().enumerate() {
        if start >= *found {
            continue; // nothing to follow, or no better than the tag already found
        }
        let quote = state % QUOTES;
        let valued = state - quote;
        if quote != OUTSIDE {
            let closing = if quote == IN_DOUBLE { b'"' } else { b'\'' };
            let to = valued + if c == u16::from(closing) { OUTSIDE } else { quote };
            next[to] = next[to].min(start);
            continue;
        }
        if c == u16::from(b'>') {
            if !before && i > at && valued != 0 {
                // Closed after the destination, it is the tag holding it.
                *found = start;
                *end = i + 1;
            }
            continue;
        }
        if c == u16::from(b'"') || c == u16::from(b'\'') {
            // A value opens, or the quote is part of a name and the reading stays outside.
            let to = valued + if c == u16::from(b'"') { IN_DOUBLE } else { IN_SINGLE };
            next[to] = next[to].min(start);
        }
        let stay = if equals { QUOTES } else { valued };
        next[stay] = next[stay].min(start);
    }
    let name = if i + 1 < scan.len() { scan.chars[i + 1] | 0x20 } else { 0 };
    if before && c == u16::from(b'<') && (u16::from(b'a')..=u16::from(b'z')).contains(&name) {
        next[OUTSIDE] = next[OUTSIDE].min(i);
    }
    *open = next;
}

/// An HTML tag holding the destination at `at`; it shows as the text it is. A reading with a value still open a reach
/// after `at` counts as the tag up to there. The tag found starts at or before the renderer's: showing a little more as
/// text is harmless, where showing less would leave a link.
pub(super) fn html_tag(scan: &mut Scan, at: usize) -> Option<TextLink> {
    let mut found = NONE;
    let mut end = 0;
    let from = at.saturating_sub(LINK_DESTINATION_MAX);
    let limit = scan.len().min(at + LINK_DESTINATION_MAX);
    while scan.tags.position < from {
        let mut none = NONE;
        let mut ignored = 0;
        let mut open = scan.tags.open;
        read_tag(scan, scan.tags.position, NONE, &mut open, &mut none, &mut ignored);
        scan.tags.open = open;
        scan.tags.position += 1;
    }
    let mut open = scan.tags.open;
    let mut i = from;
    while i < limit {
        read_tag(scan, i, at, &mut open, &mut found, &mut end);
        let earliest = open.iter().copied().min().unwrap_or(NONE);
        if i >= at && earliest >= found {
            break;
        }
        i += 1;
    }
    if found == NONE && i == limit && limit < scan.len() {
        found = open[QUOTES..].iter().copied().min().unwrap_or(NONE);
        end = limit;
    }
    if found == NONE {
        return None;
    }
    Some(TextLink::plain((found, end - found), scan.substring(found, end)))
}

//! Text as Foundation counts and classifies it, for the rules the helper's presentation states in its terms: lengths
//! and ranges in UTF-16 units (`NSString.length`, `NSRange`), its whitespace and control character sets, composed
//! character sequences, and the case, diacritic and width insensitive comparison of `rangeOfString:options:`.

use unicode_normalization::char::is_combining_mark;

/// The UTF-16 units of `text`.
pub fn utf16(text: &str) -> Vec<u16> {
    text.encode_utf16().collect()
}

/// A string from UTF-16 units; a lone surrogate (a range that split a pair) becomes U+FFFD.
pub fn from_utf16(units: &[u16]) -> String {
    String::from_utf16_lossy(units)
}

/// `NSString.length`.
pub fn length16(text: &str) -> usize {
    text.encode_utf16().count()
}

/// `whitespaceAndNewlineCharacterSet`: Unicode's White_Space, the same characters (Z*, tab to carriage return, U+0085).
pub fn is_space_or_newline(c: char) -> bool {
    c.is_whitespace()
}

/// `whitespaceCharacterSet`: the space separators and the tab, no line breaks.
pub fn is_space(c: char) -> bool {
    c == '\t' || (c.is_whitespace() && !is_newline(c) && !matches!(c, '\u{b}' | '\u{c}'))
}

/// `newlineCharacterSet`.
pub fn is_newline(c: char) -> bool {
    matches!(c, '\n'..='\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// `stringByTrimmingCharactersInSet:whitespaceAndNewlineCharacterSet`.
pub fn trim(text: &str) -> &str {
    text.trim_matches(is_space_or_newline)
}

/// The trimmed text when anything is left, as the builder treats a name.
pub fn non_empty_trimmed(text: Option<&str>) -> Option<&str> {
    text.map(trim).filter(|t| !t.is_empty())
}

/// `controlCharacterSet`: general categories Cc and Cf.
pub fn is_control_or_format(c: char) -> bool {
    if c.is_control() {
        return true;
    }
    matches!(u32::from(c),
        0xAD | 0x600..=0x605 | 0x61C | 0x6DD | 0x70F | 0x890..=0x891 | 0x8E2 | 0x180E | 0x200B..=0x200F
        | 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x206F | 0xFEFF | 0xFFF9..=0xFFFB | 0x110BD | 0x110CD
        | 0x13430..=0x1343F | 0x1BCA0..=0x1BCA3 | 0x1D173..=0x1D17A | 0xE0001 | 0xE0020..=0xE007F)
}

fn is_regional_indicator(c: char) -> bool {
    matches!(u32::from(c), 0x1F1E6..=0x1F1FF)
}

/// Whether `c` continues the composed character sequence `previous` belongs to: combining marks, variation selectors,
/// emoji modifiers and tags, either side of a zero-width joiner, a flag's second regional indicator, CR LF.
fn continues(previous: char, c: char, regional_run: usize) -> bool {
    if previous == '\r' && c == '\n' {
        return true;
    }
    if c == '\u{200D}' || previous == '\u{200D}' {
        return true;
    }
    if is_regional_indicator(previous) && is_regional_indicator(c) {
        return regional_run % 2 == 1;
    }
    matches!(u32::from(c), 0xFE00..=0xFE0F | 0xE0100..=0xE01EF | 0x1F3FB..=0x1F3FF | 0xE0020..=0xE007F)
        || (is_combining_mark(c) && previous != '\n')
}

/// The composed character sequences of `text` as (start, end) UTF-16 offsets, in order.
pub fn clusters16(text: &str) -> Vec<(usize, usize)> {
    let mut clusters: Vec<(usize, usize)> = Vec::new();
    let mut offset = 0;
    let mut previous: Option<char> = None;
    let mut regional_run = 0;
    for c in text.chars() {
        let width = c.len_utf16();
        let joined = previous.is_some_and(|p| continues(p, c, regional_run));
        regional_run = if is_regional_indicator(c) { regional_run + 1 } else { 0 };
        match clusters.last_mut() {
            Some(last) if joined => last.1 = offset + width,
            _ => clusters.push((offset, offset + width)),
        }
        offset += width;
        previous = Some(c);
    }
    clusters
}

/// The composed character sequences of `text` as strings.
pub fn clusters(text: &str) -> Vec<String> {
    let units = utf16(text);
    clusters16(text).into_iter().map(|(start, end)| from_utf16(&units[start..end])).collect()
}

/// `rangeOfComposedCharacterSequencesForRange:`: `start..end` (UTF-16) widened to whole sequences.
pub fn composed_range16(text: &str, start: usize, end: usize) -> (usize, usize) {
    let mut from = start;
    let mut to = end;
    for (a, b) in clusters16(text) {
        if a < start && start < b {
            from = a;
        }
        if a < end && end < b {
            to = b;
        }
    }
    (from, to)
}

/// Containment as `rangeOfString:options:` finds it with case, diacritic and width insensitive search.
pub fn contains_folded(haystack: &str, needle: &str) -> bool {
    crate::store::fold(haystack).contains(&crate::store::fold(needle))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn composed_sequences() {
        assert_eq!(clusters("e\u{301}a"), ["e\u{301}", "a"]);
        assert_eq!(clusters("👍🏽!"), ["👍🏽", "!"]);
        assert_eq!(clusters("🇭🇰🇨🇳"), ["🇭🇰", "🇨🇳"]);
        assert_eq!(clusters("👩\u{200D}💻x"), ["👩\u{200D}💻", "x"]);
        assert_eq!(composed_range16("ae\u{301}", 0, 2), (0, 3));
        assert!(contains_folded("Tomás Rivera", "tomas"));
        assert!(is_space('\u{a0}') && !is_space('\n') && is_space_or_newline('\n'));
    }
}

//! Plain text split at the links a person can open (`segmentsForText:` in `SZFriendsSnapshotBuilder+Items.m`): http,
//! https and mailto, as Foundation's link detector finds them in running text. Friends never fetches a preview of them.
//!
//! The helper uses `NSDataDetector`; this is the same idea written out: an explicit `http://`, `https://` or `mailto:`
//! address, a `www.` host, or an email address, ending at white space or a character no address contains, without the
//! sentence punctuation that follows it. A bare host without `www.` ("example.com") stays text here.

use serde_json::{json, Value};

use super::SnapshotBuilder;

fn ends_address(c: char) -> bool {
    c.is_whitespace() || matches!(c, '<' | '>' | '"' | '`' | '{' | '}' | '|' | '\\' | '^') || c.is_control()
}

/// The address starting at byte `start` of `text`, without trailing sentence punctuation; its byte end.
fn address_end(text: &str, start: usize) -> usize {
    let mut end = start;
    for (offset, c) in text[start..].char_indices() {
        if ends_address(c) {
            break;
        }
        end = start + offset + c.len_utf8();
    }
    // Sentence punctuation after an address is not part of it; a closing bracket is, when the address opened one.
    loop {
        let candidate = &text[start..end];
        let Some(last) = candidate.chars().last() else { break };
        let unbalanced = |open: char, close: char| {
            last == close && candidate.matches(close).count() > candidate.matches(open).count()
        };
        if matches!(last, '.' | ',' | ':' | ';' | '!' | '?' | '\'' | '’' | '”' | '*' | '_')
            || unbalanced('(', ')')
            || unbalanced('[', ']')
        {
            end -= last.len_utf8();
        } else {
            break;
        }
    }
    end
}

fn is_host(host: &str) -> bool {
    let labels: Vec<&str> = host.split('.').collect();
    labels.len() >= 2
        && labels.iter().all(|l| !l.is_empty() && l.chars().all(|c| c.is_alphanumeric() || c == '-'))
        && labels.last().is_some_and(|tld| tld.len() >= 2 && tld.chars().all(char::is_alphabetic))
}

fn starts_word(text: &str, at: usize) -> bool {
    text[..at].chars().last().is_none_or(|c| !(c.is_alphanumeric() || matches!(c, '.' | '@' | '/' | '-' | '_' | '+')))
}

/// The next link at or after byte `from`: (start, end, url).
fn next_link(text: &str, from: usize) -> Option<(usize, usize, String)> {
    let lower = text.to_ascii_lowercase();
    let mut at = from;
    while at < text.len() {
        if !text.is_char_boundary(at) {
            at += 1;
            continue;
        }
        let rest = &lower[at..];
        if starts_word(text, at) {
            for scheme in ["https://", "http://", "mailto:"] {
                if rest.starts_with(scheme) {
                    let end = address_end(text, at);
                    if end > at + scheme.len() {
                        let url = format!("{scheme}{}", &text[at + scheme.len()..end]);
                        return Some((at, end, url));
                    }
                }
            }
            if rest.starts_with("www.") {
                let end = address_end(text, at);
                let host = text[at..end].split(['/', '?', '#', ':']).next().unwrap_or("");
                if is_host(host) {
                    return Some((at, end, format!("http://{}", &text[at..end])));
                }
            }
        }
        if text[at..].starts_with('@') {
            if let Some(found) = email_around(text, at, from) {
                return Some(found);
            }
        }
        at += 1;
    }
    None
}

/// An email address whose "@" is at byte `at`, starting no earlier than `from`.
fn email_around(text: &str, at: usize, from: usize) -> Option<(usize, usize, String)> {
    let local_ok = |c: char| c.is_alphanumeric() || matches!(c, '.' | '_' | '%' | '+' | '-');
    let mut start = at;
    for (index, c) in text[from..at].char_indices().rev() {
        if !local_ok(c) {
            break;
        }
        start = from + index;
    }
    let local = text[start..at].trim_start_matches('.');
    let start = at - local.len();
    let mut end = at + 1;
    for (offset, c) in text[at + 1..].char_indices() {
        if !(c.is_alphanumeric() || matches!(c, '.' | '-')) {
            break;
        }
        end = at + 1 + offset + c.len_utf8();
    }
    let domain = text[at + 1..end].trim_end_matches(['.', '-']);
    let end = at + 1 + domain.len();
    if local.is_empty() || !is_host(domain) || !starts_word(text, start) {
        return None;
    }
    Some((start, end, format!("mailto:{}", &text[start..end])))
}

impl SnapshotBuilder {
    /// `text` as segments, each link one with its `url`.
    pub(crate) fn segments_for_text(&self, text: &str) -> Vec<Value> {
        let mut segments = Vec::new();
        let mut cursor = 0;
        while let Some((start, end, url)) = next_link(text, cursor) {
            if start > cursor {
                segments.push(json!({"text": &text[cursor..start]}));
            }
            segments.push(json!({"text": &text[start..end], "url": url}));
            cursor = end;
        }
        if cursor < text.len() || segments.is_empty() {
            segments.push(json!({"text": &text[cursor..]}));
        }
        segments
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn links_in_running_text() {
        let links = |text: &str| {
            let mut found = Vec::new();
            let mut from = 0;
            while let Some((start, end, url)) = next_link(text, from) {
                found.push((text[start..end].to_owned(), url));
                from = end;
            }
            found
        };
        assert_eq!(
            links("see https://example.com/plan please"),
            [("https://example.com/plan".into(), "https://example.com/plan".into())]
        );
        assert_eq!(
            links("(at www.example.com/a_(b).)"),
            [("www.example.com/a_(b)".into(), "http://www.example.com/a_(b)".into())]
        );
        assert_eq!(links("mail mei@example.com."), [("mei@example.com".into(), "mailto:mei@example.com".into())]);
        assert!(links("Supplier contract v3.pdf, pages 3–5").is_empty());
    }
}

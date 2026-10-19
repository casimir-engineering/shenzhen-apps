//! Arriving and typed messages (`SZFriendsMentionChecks.m`): every Friends link that is not a mention to keep becomes
//! plain text.

use super::{markdown_literal, text_links, TextLink, MENTIONS_MAX};
use crate::presentation::text::{from_utf16, utf16};

/// `text` with each link `keep` refuses replaced by its words as plain text. Replacing can bring a new link together
/// from the text around it, so the pass repeats until nothing refused is left; after a few passes a text still forming
/// links loses every bracket's power instead.
fn replaced(text: &str, keep: impl Fn(&TextLink, usize) -> bool) -> String {
    let mut text = text.to_owned();
    for _ in 0..4 {
        let links = text_links(&text);
        let units = utf16(&text);
        let mut result = String::with_capacity(text.len());
        let mut cursor = 0;
        let mut kept = 0;
        let mut changed = false;
        for link in &links {
            result.push_str(&from_utf16(&units[cursor..link.range.0]));
            if keep(link, kept) {
                kept += 1;
                result.push_str(&from_utf16(&units[link.range.0..link.end()]));
            } else {
                changed = true;
                result.push_str(&markdown_literal(&link.shown_text));
            }
            cursor = link.end();
        }
        if !changed {
            return text;
        }
        result.push_str(&from_utf16(&units[cursor..]));
        text = result;
    }
    // Shown exactly as written, Markdown and all: nothing in it can be a link any more.
    markdown_literal(&text)
}

/// An arriving message: every Friends link kept only if it is a well-formed mention whose ID `valid_id` accepts (the
/// helper passes its word list) and among the first [`MENTIONS_MAX`]; everything else becomes plain text.
pub fn mentions_checked(text: &str, valid_id: impl Fn(&str) -> bool) -> String {
    replaced(text, |link, kept| {
        link.is_mention && kept < MENTIONS_MAX && link.friends_id.as_deref().is_some_and(&valid_id)
    })
}

/// What a person typed into the composer: every Friends link becomes plain text, so the only mentions a message
/// carries are the ones its helper writes from send_message's `mentions`.
pub fn mentions_neutralized(text: &str) -> String {
    replaced(text, |_, _| false)
}

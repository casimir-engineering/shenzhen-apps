//! Search as a reader sees it (ADR 0007; ADR 0003, Corrections; `SZFriendsStoreSearch.m`, `displayedHit:` in
//! `SZFriendsSnapshotBuilder+Mentions.m`). A message is searched as a reader sees it: each mention as its "@Name"
//! label, never the Friends ID and key its link carries. Search then never finds a message by an ID or key nobody
//! sees, and every hit has a match a view can show.
//!
//! [`fold_item`] is what the store indexes for a body; [`refold`] brings rows folded before mentions were labels up to
//! date once per store; [`hit_ranges`] gives a hit's matches as ranges of the stored text; [`search_messages`] runs
//! search_messages' search on a store. Ranges are UTF-16 (start, length), as the helper's are.

use rusqlite::OptionalExtension;
use serde_json::Value;

use super::facts::SearchHitFacts;
use super::mentions::{markdown_literal, text_links};
use super::text::{from_utf16, trim, utf16};
use super::SnapshotBuilder;
use crate::store::{fold, Direction, ItemKind, Store, StoreError};

/// `meta.search_fold` once every row is folded with mentions as labels.
pub const SEARCH_FOLD_VERSION: &str = "labels";

/// One stretch of a text as a reader sees it, and where its characters are in the stored text. A link's stored stretch
/// is the part a view lights up for it: a mention's label inside its brackets, or a whole other link.
struct Piece {
    shown: (usize, usize),
    stored: (usize, usize),
    link: bool,
}

/// The text a reader sees, every Friends link replaced by its words (unescaped, so "Mei_Lin" is found as shown).
fn visible(text: &str) -> (String, Vec<Piece>) {
    let links = text_links(text);
    let units = utf16(text);
    if links.is_empty() {
        return (text.to_owned(), vec![Piece { shown: (0, units.len()), stored: (0, units.len()), link: false }]);
    }
    let mut shown = String::new();
    let mut shown_length = 0;
    let mut pieces = Vec::new();
    let mut cursor = 0;
    for link in &links {
        let gap = link.range.0 - cursor;
        pieces.push(Piece { shown: (shown_length, gap), stored: (cursor, gap), link: false });
        shown.push_str(&from_utf16(&units[cursor..link.range.0]));
        shown_length += gap;
        let mut stored = link.range;
        if link.is_mention && link.range.1 > 1 {
            let label = markdown_literal(&link.shown_text).encode_utf16().count();
            stored = (link.range.0 + 1, label.min(link.range.1 - 1));
        }
        let words = link.shown_text.encode_utf16().count();
        pieces.push(Piece { shown: (shown_length, words), stored, link: true });
        shown.push_str(&link.shown_text);
        shown_length += words;
        cursor = link.end();
    }
    let tail = units.len() - cursor;
    pieces.push(Piece { shown: (shown_length, tail), stored: (cursor, tail), link: false });
    shown.push_str(&from_utf16(&units[cursor..]));
    (shown, pieces)
}

/// What the store indexes for a body: a message as a reader sees it, a file's name as it is.
pub fn fold_item(body: &str, is_message: bool) -> String {
    if is_message {
        fold(&visible(body).0)
    } else {
        fold(body)
    }
}

/// Sorted, with overlapping ranges joined.
fn merged(mut found: Vec<(usize, usize)>) -> Vec<(usize, usize)> {
    found.sort_by_key(|(start, _)| *start);
    let mut merged: Vec<(usize, usize)> = Vec::new();
    for (start, length) in found {
        match merged.last_mut() {
            Some(last) if start <= last.0 + last.1 => {
                let end = (last.0 + last.1).max(start + length);
                last.1 = end - last.0;
            }
            _ => merged.push((start, length)),
        }
    }
    merged
}

/// Every occurrence of each folded term in `text`, case, diacritic and width insensitive, as ranges of `text`.
fn match_ranges(text: &str, terms: &[String]) -> Vec<(usize, usize)> {
    // The text folded character by character, each folded byte knowing the UTF-16 range it came from.
    let mut folded = String::new();
    let mut owner: Vec<(usize, usize)> = Vec::new();
    let mut offset = 0;
    for c in text.chars() {
        let width = c.len_utf16();
        let piece = fold(c.encode_utf8(&mut [0; 4]));
        owner.extend(std::iter::repeat_n((offset, offset + width), piece.len()));
        folded.push_str(&piece);
        offset += width;
    }
    let mut found = Vec::new();
    for term in terms.iter().filter(|t| !t.is_empty()) {
        for (start, matched) in folded.match_indices(term.as_str()) {
            let (from, _) = owner[start];
            let (_, to) = owner[start + matched.len() - 1];
            found.push((from, to - from));
        }
    }
    merged(found)
}

/// A hit's matches as ranges of the stored text: in a message, found in what the reader sees; a match touching a
/// mention's label covers the label, never its destination.
pub fn hit_ranges(text: &str, is_message: bool, terms: &[String]) -> Vec<(usize, usize)> {
    if !is_message {
        return match_ranges(text, terms);
    }
    let (shown, pieces) = visible(text);
    let mut found = Vec::new();
    for (start, length) in match_ranges(&shown, terms) {
        for piece in &pieces {
            let from = start.max(piece.shown.0);
            let to = (start + length).min(piece.shown.0 + piece.shown.1);
            if to <= from {
                continue;
            }
            let stored = if piece.link { piece.stored } else { (piece.stored.0 + from - piece.shown.0, to - from) };
            if stored.1 > 0 {
                found.push(stored);
            }
        }
    }
    merged(found)
}

/// The search terms of a query as the store splits them: folded, whitespace-separated, each once.
pub fn search_terms(query: &str) -> Vec<String> {
    let mut terms: Vec<String> = Vec::new();
    for term in fold(query).split_whitespace() {
        if !terms.iter().any(|t| t == term) {
            terms.push(term.to_owned());
        }
    }
    terms
}

/// search_messages' search (`intent_search_messages:`): up to `limit` hits newest first, whole-query hits first, with
/// their match ranges, and whether there are more. No network.
pub fn search_messages(
    store: &Store,
    query: &str,
    conversation_id: Option<&str>,
    limit: usize,
) -> Result<(Vec<SearchHitFacts>, bool), StoreError> {
    let trimmed = trim(query);
    if trimmed.is_empty() {
        return Ok((Vec::new(), false));
    }
    let scope = conversation_id.map(|id| vec![id.to_owned()]);
    let hits = store.search(trimmed, scope.as_deref(), limit + 1)?;
    let terms = search_terms(trimmed);
    let more = hits.len() > limit;
    let facts = hits
        .into_iter()
        .take(limit)
        .map(|hit| {
            let message = hit.kind == ItemKind::Message;
            (hit_ranges(&hit.text, message, &terms), message, hit)
        })
        // A row folded before mentions were labels can match only inside a link's ID or key, which nobody sees: no hit.
        .filter(|(ranges, message, hit)| !ranges.is_empty() || !*message || text_links(&hit.text).is_empty())
        .map(|(match_ranges, _, hit)| SearchHitFacts {
            match_ranges,
            conversation_id: hit.conversation_id,
            item_id: hit.item_id,
            sent_at: hit.sent_at,
            outgoing: hit.direction == Direction::Outgoing,
            text: hit.text,
        })
        .collect();
    Ok((facts, more))
}

/// Refolds, once per store, the messages folded before mentions were labels (`SZFriendsRefoldSearch`): their
/// `folded` copy still holds each mention's ID and key. Returns how many rows changed.
pub fn refold(store: &Store) -> Result<usize, StoreError> {
    let conn = store.connection();
    let done: Option<String> =
        conn.query_row("SELECT value FROM meta WHERE key = 'search_fold'", [], |r| r.get(0)).optional()?;
    if done.as_deref() == Some(SEARCH_FOLD_VERSION) {
        return Ok(0);
    }
    let transaction = rusqlite::Transaction::new_unchecked(conn, rusqlite::TransactionBehavior::Immediate)?;
    let rows: Vec<(i64, String)> = {
        // LIKE ignores ASCII case, as the search for links does.
        let mut statement =
            transaction.prepare("SELECT seq, body FROM messages WHERE kind = 0 AND body LIKE '%szfriends:%'")?;
        let rows = statement.query_map([], |r| Ok((r.get(0)?, r.get::<_, Option<String>>(1)?.unwrap_or_default())))?;
        rows.collect::<Result<_, _>>()?
    };
    for (seq, body) in &rows {
        transaction
            .execute("UPDATE messages SET folded = ?1 WHERE seq = ?2", rusqlite::params![fold_item(body, true), seq])?;
    }
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES ('search_fold', ?1) ON CONFLICT(key) DO UPDATE SET value = ?1",
        [SEARCH_FOLD_VERSION],
    )?;
    transaction.commit()?;
    Ok(rows.len())
}

impl SnapshotBuilder {
    /// A search hit as its excerpt shows it: the plain text, its matches moved there. None when every match was in
    /// what nobody sees (a mention's ID or key), so a search for "szfriends" or a key fragment finds nothing.
    pub fn displayed_hit(&self, hit: &SearchHitFacts) -> Option<SearchHitFacts> {
        let links = text_links(&hit.text);
        if links.is_empty() {
            return Some(hit.clone());
        }
        let resolved = self.mentions_for_links(&links, self.mention_directory.as_ref());
        let units = utf16(&hit.text);
        let mut plain = String::new();
        let mut plain_length = 0;
        // (from, length, to, shown, link): a stretch of the stored text and where it lands in the plain text.
        let mut pieces: Vec<(usize, usize, usize, usize, bool)> = Vec::new();
        let mut cursor = 0;
        for (link, mention) in links.iter().zip(&resolved) {
            let gap = link.range.0 - cursor;
            pieces.push((cursor, gap, plain_length, gap, false));
            plain.push_str(&from_utf16(&units[cursor..link.range.0]));
            plain_length += gap;
            let label = match mention {
                Some(m) => m["label"].as_str().map(str::to_owned).unwrap_or_default(),
                None => link.shown_text.clone(),
            };
            let label_length = label.encode_utf16().count();
            // A link's visible part is its link text ("[@Mei Lin]"): a match there lights up the whole name shown.
            let visible = if link.is_mention {
                markdown_literal(&link.shown_text).encode_utf16().count() + 2
            } else {
                link.range.1
            };
            pieces.push((link.range.0, visible.min(link.range.1), plain_length, label_length, true));
            plain.push_str(&label);
            plain_length += label_length;
            cursor = link.end();
        }
        pieces.push((cursor, units.len() - cursor, plain_length, units.len() - cursor, false));
        plain.push_str(&from_utf16(&units[cursor..]));
        let mut ranges = Vec::new();
        for (start, length) in &hit.match_ranges {
            for (from, stretch, to, shown, link) in &pieces {
                let a = (*start).max(*from);
                let b = (start + length).min(from + stretch);
                if b <= a {
                    continue;
                }
                let range = if *link { (*to, *shown) } else { (to + a - from, b - a) };
                if range.1 > 0 {
                    ranges.push(range);
                }
            }
        }
        if !hit.match_ranges.is_empty() && ranges.is_empty() {
            return None;
        }
        Some(SearchHitFacts { text: plain, match_ranges: ranges, ..hit.clone() })
    }
}

/// The search result for a `search_messages` reply from a store search (the reply's `result` object).
pub fn search_result_from_store(
    builder: &SnapshotBuilder,
    store: &Store,
    query: &str,
    conversation_id: Option<&str>,
    limit: usize,
    people: &std::collections::HashMap<String, super::facts::PersonFacts>,
    now: f64,
) -> Result<Value, StoreError> {
    let (hits, more) = search_messages(store, query, conversation_id, limit)?;
    Ok(builder.search_result(&hits, people, more, now))
}

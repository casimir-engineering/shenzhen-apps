//! Local search (ADR 0003 § Search; `SZFriendsStoreSearch.m`): an FTS5 trigram index over a folded copy of each body,
//! a substring filter for one- and two-character terms, newest first with whole-query hits ranked first.
//!
//! The index is not a versioned migration: it is created at open where the tokenizer exists and kept in step by
//! temporary triggers on this connection, exactly as the helper does (ADR 0003, Corrections), so the schema a Rust
//! store holds is the helper's. Writes made without the index mark it stale and the next open rebuilds it.
//!
//! Mentions are folded as raw text for now: the label form (ADR 0007) arrives with the presentation area in wave 3, and
//! until then this store never writes `meta.search_fold`.

use rusqlite::{Connection, OptionalExtension};
use unicode_normalization::char::is_combining_mark;
use unicode_normalization::UnicodeNormalization;

use super::people::{Direction, ItemKind};
use super::{Result, StoreError};

/// The diacritics Foundation's diacritic-insensitive folding removes: the combining blocks for Latin, Greek and
/// Cyrillic letters and for symbols. Marks that belong to a script's spelling (Devanagari vowel signs, Arabic harakat,
/// kana sound marks) stay.
fn is_folded_diacritic(c: char) -> bool {
    matches!(u32::from(c), 0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF | 0xFE20..=0xFE2F)
        && is_combining_mark(c)
}

/// Case, diacritic and width folding with no locale (`SZFriendsSearchFold`): fullwidth ASCII and halfwidth katakana
/// to their usual forms, then lower case (with the full folds of ß, ŉ and the Latin ligatures), then the diacritics
/// removed. Halfwidth sound marks are kept as they are. Stored and query text fold identically everywhere.
pub fn fold(text: &str) -> String {
    let mut wide = String::with_capacity(text.len());
    for c in text.nfc() {
        match u32::from(c) {
            0xFF01..=0xFF5E => wide.push(char::from_u32(u32::from(c) - 0xFEE0).unwrap_or(c)),
            0xFF65..=0xFF9D => wide.extend(std::iter::once(c).nfkc()),
            _ => wide.push(c),
        }
    }
    let mut lower = String::with_capacity(wide.len());
    for c in wide.chars() {
        match c {
            'ß' | 'ẞ' => lower.push_str("ss"),
            'ŉ' => lower.push_str("ʼn"),
            '\u{FB00}'..='\u{FB06}' => lower.extend(std::iter::once(c).nfkc()),
            _ => lower.extend(c.to_lowercase()),
        }
    }
    lower.nfd().filter(|c| !is_folded_diacritic(*c)).nfc().collect()
}

/// Creates the FTS table and its temporary triggers when the trigram tokenizer exists (`true`); without it, marks the
/// index stale on every change (`false`). A store opened without `allow_trigram` behaves as on such a SQLite.
pub(super) fn prepare(conn: &Connection, allow_trigram: bool) -> Result<bool> {
    let trigram = allow_trigram
        && conn
            .execute_batch(
                "CREATE VIRTUAL TABLE temp.szf_probe USING fts5(x, tokenize='trigram'); DROP TABLE temp.szf_probe",
            )
            .is_ok();
    if !trigram {
        if allow_trigram {
            return Err(StoreError::NoTrigram);
        }
        let stale =
            "INSERT INTO meta(key, value) VALUES ('search_stale', '1') ON CONFLICT(key) DO UPDATE SET value = '1'";
        conn.execute_batch(&format!(
            "CREATE TEMP TRIGGER IF NOT EXISTS szf_stale_ai AFTER INSERT ON main.messages BEGIN {stale}; END;\
             CREATE TEMP TRIGGER IF NOT EXISTS szf_stale_ad AFTER DELETE ON main.messages BEGIN {stale}; END;\
             CREATE TEMP TRIGGER IF NOT EXISTS szf_stale_au AFTER UPDATE OF folded ON main.messages BEGIN {stale}; END;"
        ))?;
        return Ok(false);
    }
    let exists: i64 =
        conn.query_row("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'search'", [], |r| {
            r.get(0)
        })?;
    let stale: Option<String> =
        conn.query_row("SELECT value FROM meta WHERE key = 'search_stale'", [], |r| r.get(0)).optional()?;
    let fresh = exists > 0 && stale.as_deref() != Some("1");
    let setup = "CREATE VIRTUAL TABLE IF NOT EXISTS main.search USING fts5(folded, content='messages', \
                 content_rowid='seq', tokenize='trigram');\
                 CREATE TEMP TRIGGER IF NOT EXISTS szf_search_ai AFTER INSERT ON main.messages BEGIN \
                 INSERT INTO search(rowid, folded) VALUES (new.seq, new.folded); END;\
                 CREATE TEMP TRIGGER IF NOT EXISTS szf_search_ad AFTER DELETE ON main.messages BEGIN \
                 INSERT INTO search(search, rowid, folded) VALUES ('delete', old.seq, old.folded); END;\
                 CREATE TEMP TRIGGER IF NOT EXISTS szf_search_au AFTER UPDATE OF folded ON main.messages BEGIN \
                 INSERT INTO search(search, rowid, folded) VALUES ('delete', old.seq, old.folded); \
                 INSERT INTO search(rowid, folded) VALUES (new.seq, new.folded); END;";
    let transaction = rusqlite::Transaction::new_unchecked(conn, rusqlite::TransactionBehavior::Immediate)?;
    transaction.execute_batch(setup)?;
    if !fresh {
        rebuild(&transaction)?;
    }
    transaction.commit()?;
    Ok(true)
}

/// Rebuilds the index from the messages table and clears the stale mark.
pub(super) fn rebuild(conn: &Connection) -> Result<()> {
    let exists: i64 =
        conn.query_row("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'search'", [], |r| {
            r.get(0)
        })?;
    if exists > 0 {
        conn.execute_batch("INSERT INTO search(search) VALUES ('rebuild')")?;
    }
    conn.execute_batch("DELETE FROM meta WHERE key = 'search_stale'")?;
    Ok(())
}

/// One history row that matches.
#[derive(Clone, Debug, PartialEq)]
pub struct SearchHit {
    pub conversation_id: String,
    pub item_id: String,
    pub kind: ItemKind,
    pub sent_at: f64,
    pub direction: Direction,
    pub text: String,
}

/// FTS5 string syntax: a term in double quotes, inner quotes doubled, is matched literally.
fn phrase(term: &str) -> String {
    format!("\"{}\"", term.replace('"', "\"\""))
}

/// Every whitespace-separated term must occur, in any order; hits holding the whole query rank first, then newest.
pub(super) fn search(
    conn: &Connection,
    query: &str,
    conversation_ids: Option<&[String]>,
    limit: usize,
    use_index: bool,
) -> Result<Vec<SearchHit>> {
    if limit == 0 || conversation_ids.is_some_and(<[String]>::is_empty) {
        return Ok(Vec::new());
    }
    let folded = fold(query);
    let mut terms: Vec<&str> = Vec::new();
    for term in folded.split_whitespace() {
        if !terms.contains(&term) {
            terms.push(term);
        }
    }
    if terms.is_empty() {
        return Ok(Vec::new());
    }
    let mut binds: Vec<rusqlite::types::Value> = vec![terms.join(" ").into()];
    let mut clause = String::from("m.folded IS NOT NULL");
    let mut indexed = Vec::new();
    for term in &terms {
        // Trigrams need three characters, so 合同 and 合 are a substring test on the folded copy instead.
        if use_index && term.chars().count() >= 3 {
            indexed.push(phrase(term));
        } else {
            clause.push_str(" AND instr(m.folded, ?) > 0");
            binds.push(term.to_string().into());
        }
    }
    if let Some(ids) = conversation_ids {
        clause.push_str(&format!(" AND m.conversation_id IN ({})", vec!["?"; ids.len()].join(",")));
        binds.extend(ids.iter().map(|id| id.clone().into()));
    }
    let mut from = "messages m";
    if !indexed.is_empty() {
        from = "search JOIN messages m ON m.seq = search.rowid";
        clause.push_str(" AND search MATCH ?");
        binds.push(indexed.join(" AND ").into());
    }
    binds.push((limit as i64).into());
    let sql = format!(
        "SELECT m.conversation_id, m.item_id, m.kind, m.sent_at, m.direction, m.body, instr(m.folded, ?1) > 0 \
         AS exact FROM {from} WHERE {clause} ORDER BY exact DESC, m.sent_at DESC, m.item_id DESC LIMIT ?"
    );
    let mut statement = conn.prepare(&sql)?;
    let rows = statement.query_map(rusqlite::params_from_iter(binds), |row| {
        Ok(SearchHit {
            conversation_id: row.get(0)?,
            item_id: row.get(1)?,
            kind: ItemKind::from_i64(row.get(2)?),
            sent_at: row.get(3)?,
            direction: Direction::from_i64(row.get(4)?),
            text: row.get::<_, Option<String>>(5)?.unwrap_or_default(),
        })
    })?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

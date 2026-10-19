//! One place for every user-facing string Friends shows (`SZFriendsCatalog*.m`). The tables are the helper's own,
//! entry for entry; the suite compares them with the Objective-C sources, so the two catalogs cannot drift apart. M1
//! ships English (en-GB conventions, as in the mockups); a translation is a second table with the same keys, and a
//! language without plural forms supplies `.other` only.

mod chrome;
mod devices;
mod extra;
mod people;
mod views;

use std::collections::{BTreeSet, HashMap};
use std::sync::{Mutex, OnceLock};

/// Every table in the order the helper merges them; a later entry would replace an earlier one with the same key.
const TABLES: &[&[(&str, &str)]] = &[
    chrome::CORE,
    views::TRANSFERS_AND_CONVERSATIONS,
    views::NEARBY,
    people::PEOPLE_AND_SETTINGS,
    people::ERRORS,
    extra::MENTIONS,
    extra::LINKS,
    extra::JOIN,
    devices::DEVICES,
];

/// The English catalog: key to template.
pub fn english() -> &'static HashMap<&'static str, &'static str> {
    static CATALOG: OnceLock<HashMap<&'static str, &'static str>> = OnceLock::new();
    CATALOG.get_or_init(|| TABLES.iter().flat_map(|table| table.iter().copied()).collect())
}

/// One part of the catalog by the helper's file: "chrome", "views", "people", "mentions", "links", "join" or
/// "devices" (the views part is two tables, and so is the people part, merged here).
pub fn part(name: &str) -> Vec<(&'static str, &'static str)> {
    let tables: &[&[(&str, &str)]] = match name {
        "chrome" => &[chrome::CORE],
        "views" => &[views::TRANSFERS_AND_CONVERSATIONS, views::NEARBY],
        "people" => &[people::PEOPLE_AND_SETTINGS, people::ERRORS],
        "mentions" => &[extra::MENTIONS],
        "links" => &[extra::LINKS],
        "join" => &[extra::JOIN],
        "devices" => &[devices::DEVICES],
        _ => &[],
    };
    tables.iter().flat_map(|table| table.iter().copied()).collect()
}

/// Every entry of every table, in table order, duplicates included (for the parity check with the helper).
pub fn entries() -> impl Iterator<Item = (&'static str, &'static str)> {
    TABLES.iter().flat_map(|table| table.iter().copied())
}

fn missing() -> &'static Mutex<BTreeSet<String>> {
    static MISSING: OnceLock<Mutex<BTreeSet<String>>> = OnceLock::new();
    MISSING.get_or_init(Default::default)
}

/// Keys a lookup asked for and did not find, and placeholders left unfilled (`key{name}`). Tests build every
/// snapshot and then require this to be empty, so a typo in a key fails a test instead of showing the key to someone.
pub fn missing_keys() -> BTreeSet<String> {
    missing().lock().map(|set| set.clone()).unwrap_or_default()
}

pub(crate) fn record_missing(key: String) {
    if let Ok(mut set) = missing().lock() {
        set.insert(key);
    }
}

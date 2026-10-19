//! Friends IDs (ADR 0006): two words (three once the host says so) from a versioned list of 2,048, as people type
//! them and as the helper draws them (`SZFriendsIDCodec`, `SZFriendsWordList`).

use std::collections::HashMap;
use std::sync::OnceLock;

use sha2::{Digest, Sha256};
use unicode_normalization::UnicodeNormalization;

/// The v1 list, compiled in from the helper's own file so both implementations read the same bytes.
const V1_FILE: &str = include_str!("../../../../service/identity/wordlist/friends-id-words-v1.txt");
/// The pinned SHA-256 of every v1 word followed by "\n" (`SZFriendsWordListV1Digest`).
pub const V1_DIGEST: &str = "feb7e254b1a9668501e52a3277de505c9982d69af54fe0f2ac55c2a7f5de857e";
const V1_COUNT: usize = 2048;
const MAX_WORDS: usize = 65_536;
/// Longer input is not normalised at all (UTF-16 code units, as the helper counts).
const INPUT_MAX: usize = 256;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WordListError {
    Count,
    Word(usize),
    Duplicate(String),
    Format(&'static str),
}

#[derive(Debug)]
pub struct WordList {
    version: u32,
    words: Vec<String>,
    indexes: HashMap<String, usize>,
}

fn word_is_valid(word: &str) -> bool {
    (3..=8).contains(&word.len()) && word.bytes().all(|b| b.is_ascii_lowercase())
}

impl WordList {
    /// Any count from 1 to 65,536 of unique words of 3 to 8 letters a-z, in the given order.
    pub fn with_words(words: Vec<String>, version: u32) -> Result<Self, WordListError> {
        if words.is_empty() || words.len() > MAX_WORDS {
            return Err(WordListError::Count);
        }
        let mut indexes = HashMap::with_capacity(words.len());
        for (i, word) in words.iter().enumerate() {
            if !word_is_valid(word) {
                return Err(WordListError::Word(i + 1));
            }
            if indexes.insert(word.clone(), i).is_some() {
                return Err(WordListError::Duplicate(word.clone()));
            }
        }
        Ok(Self { version, words, indexes })
    }

    /// The file format: '#' header lines first, one of them "# version: <n>", then one word per line, each ending in
    /// "\n"; no blank lines, no header lines after the first word, ASCII only. Does not check the pin.
    pub fn from_file(text: &str) -> Result<Self, WordListError> {
        if !text.is_ascii() || !text.ends_with('\n') {
            return Err(WordListError::Format("ASCII text ending in a newline"));
        }
        let mut words = Vec::new();
        let mut version = None;
        for line in text[..text.len() - 1].split('\n') {
            if let Some(header) = line.strip_prefix('#') {
                if !words.is_empty() {
                    return Err(WordListError::Format("header lines come before the words"));
                }
                if let Some(value) = header.strip_prefix(" version: ") {
                    match (version, value.parse::<u32>()) {
                        (None, Ok(v)) if v >= 1 => version = Some(v),
                        _ => return Err(WordListError::Format("one positive version header")),
                    }
                }
                continue;
            }
            words.push(line.to_owned());
        }
        Self::with_words(words, version.ok_or(WordListError::Format("no version header"))?)
    }

    /// The compiled-in v1 list, validated once: version 1, 2,048 words, the pinned digest. `None` when it fails, so
    /// a build that embedded the wrong file draws no ID rather than IDs other installs cannot parse.
    pub fn bundled() -> Option<&'static WordList> {
        static LIST: OnceLock<Option<WordList>> = OnceLock::new();
        LIST.get_or_init(|| {
            WordList::from_file(V1_FILE)
                .ok()
                .filter(|l| l.version == 1 && l.words.len() == V1_COUNT && l.word_lines_digest() == V1_DIGEST)
        })
        .as_ref()
    }

    pub fn version(&self) -> u32 {
        self.version
    }

    pub fn len(&self) -> usize {
        self.words.len()
    }

    pub fn is_empty(&self) -> bool {
        self.words.is_empty()
    }

    pub fn word(&self, index: usize) -> &str {
        &self.words[index]
    }

    pub fn index_of(&self, word: &str) -> Option<usize> {
        self.indexes.get(word).copied()
    }

    /// Lowercase hex SHA-256 of every word followed by "\n": what a version's pin covers.
    pub fn word_lines_digest(&self) -> String {
        let mut hasher = Sha256::new();
        for word in &self.words {
            hasher.update(word.as_bytes());
            hasher.update(b"\n");
        }
        hasher.finalize().iter().map(|b| format!("{b:02x}")).collect()
    }

    /// The canonical form, `word-word` or `word-word-word`. Accepts what people type: surrounding whitespace, any
    /// case, and spaces, hyphens, dots or underscores between words, runs of them too, and the full-width and dash
    /// forms Chinese and macOS input methods produce. `None` for a word not in the list, or for one word or four.
    pub fn normalized_id(&self, input: &str) -> Option<String> {
        let units = input.encode_utf16().count();
        if units == 0 || units > INPUT_MAX {
            return None;
        }
        let folded: String = input.nfkc().collect::<String>().to_lowercase();
        let mut words: Vec<&str> = Vec::with_capacity(3);
        for part in folded.split(is_separator).filter(|part| !part.is_empty()) {
            if words.len() == 3 || self.index_of(part).is_none() {
                return None;
            }
            words.push(part);
        }
        (words.len() >= 2).then(|| words.join("-"))
    }

    /// A uniformly random ID of `word_count` (2 or 3) words; `draw(bound)` returns a uniform value below `bound`
    /// (the system random source in production, scripted in tests). Panics on another count or a draw at or above
    /// the bound, as the helper raises: a generator that ignores its bound would pick words unevenly.
    pub fn random_id(&self, word_count: usize, mut draw: impl FnMut(u32) -> u32) -> String {
        assert!(word_count == 2 || word_count == 3, "Friends IDs have 2 or 3 words");
        let bound = self.words.len() as u32;
        let words: Vec<&str> = (0..word_count)
            .map(|_| {
                let index = draw(bound);
                assert!(index < bound, "random draw out of range");
                self.word(index as usize)
            })
            .collect();
        words.join("-")
    }
}

/// Whitespace and newlines (Unicode White_Space, as Foundation's set), and `- . _` with the forms input methods
/// substitute for them: hyphen and dash variants, the minus sign, and the ideographic and katakana full stops.
fn is_separator(c: char) -> bool {
    c.is_whitespace()
        || matches!(c, '-' | '.' | '_' | '\u{2010}'..='\u{2015}' | '\u{2212}' | '\u{3002}' | '\u{ff61}' | '\u{30fb}')
}

/// A uniform value below `bound` from the system's secure random source (rejection sampling, like libsodium's
/// `randombytes_uniform`).
pub fn system_uniform(bound: u32) -> u32 {
    assert!(bound >= 1, "bound must be at least 1");
    let limit = u32::MAX - (u32::MAX % bound);
    loop {
        let mut bytes = [0u8; 4];
        szfriends_crypto::random_bytes(&mut bytes);
        let value = u32::from_le_bytes(bytes);
        if value < limit {
            return value % bound;
        }
    }
}

/// How many words the next drawn ID has (ADR 0006 § Three-word threshold): three when the signed host list says so,
/// or after three collisions in a row, which covers a stale list.
pub fn word_count_for_new_id(list_new_id_words: i64, collisions_in_a_row: u64) -> usize {
    if list_new_id_words >= 3 || collisions_in_a_row >= 3 {
        3
    } else {
        2
    }
}

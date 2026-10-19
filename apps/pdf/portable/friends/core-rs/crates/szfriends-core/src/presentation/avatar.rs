//! Pictures as the views draw them (`avatars/SZFriendsPicture.m`, `SZFriendsAnimalSet.m`): the bundled animal set,
//! initials, and the stable placeholder colors. An animal travels as (set, index); an index this copy of the set does
//! not know is drawn as a placeholder (initials on a colored circle) rather than failing.

use serde_json::{json, Map, Value};

use super::text::{clusters, is_space_or_newline, trim};

/// A person's picture as stored and exchanged.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum Picture {
    #[default]
    Placeholder,
    Animal {
        set: i64,
        index: i64,
    },
    /// The helper's re-encoded copy of a photo.
    Image {
        path: String,
    },
}

impl Picture {
    /// An animal; values no set can hold (set below 1, index below 0) are the placeholder from the start.
    pub fn animal(set: i64, index: i64) -> Self {
        if set < 1 || index < 0 {
            Self::Placeholder
        } else {
            Self::Animal { set, index }
        }
    }
}

/// One version of the bundled animal set: what `avatars/animals/manifest.json` says about each animal that the
/// snapshots need (its circle color).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AnimalSet {
    pub version: i64,
    pub colors: Vec<String>,
}

impl AnimalSet {
    /// Reads a manifest (`{"set": 1, "count": N, "animals": [{"index": 0, "color": "#5a4a7a", ...}, ...]}`), with the
    /// helper's checks: a set of at least 1, a count that matches, indexes that are positions, and #rrggbb colors.
    pub fn from_manifest(json: &str) -> Result<Self, String> {
        let manifest: Value = serde_json::from_str(json).map_err(|e| e.to_string())?;
        let version = manifest["set"].as_i64().filter(|v| *v >= 1).ok_or("\"set\" must be an integer of at least 1")?;
        let animals = manifest["animals"].as_array().filter(|a| !a.is_empty() && a.len() <= 65_536);
        let animals = animals.ok_or("\"animals\" must be a non-empty array of at most 65536 entries")?;
        if manifest["count"].as_u64() != Some(animals.len() as u64) {
            return Err("\"count\" must equal the number of animals".into());
        }
        let mut colors = Vec::with_capacity(animals.len());
        for (expected, animal) in animals.iter().enumerate() {
            if animal["index"].as_u64() != Some(expected as u64) {
                return Err(format!("animal {expected} has the wrong \"index\""));
            }
            if animal["name"].as_str().is_none_or(|n| n.is_empty()) {
                return Err(format!("animal {expected} needs a \"name\""));
            }
            let color = animal["color"].as_str().filter(|c| is_color(c));
            colors.push(color.ok_or(format!("animal {expected} needs a \"color\" like #5a4a7a"))?.to_owned());
        }
        Ok(Self { version, colors })
    }

    pub fn color_at(&self, index: i64) -> Option<&str> {
        usize::try_from(index).ok().and_then(|i| self.colors.get(i)).map(String::as_str)
    }
}

fn is_color(text: &str) -> bool {
    text.len() == 7 && text.starts_with('#') && text[1..].bytes().all(|b| b.is_ascii_hexdigit())
}

/// The avatar fields a picture gives (`protocolFieldsValidatedAgainst:`): kind, set and index or path, and a known
/// animal's color. Unknown animals, and every animal without a set, come out as the placeholder.
pub(crate) fn protocol_fields(picture: &Picture, set: Option<&AnimalSet>) -> Map<String, Value> {
    let mut fields = Map::new();
    match picture {
        Picture::Animal { set: version, index } => {
            if let Some(color) = set.and_then(|s| s.color_at(*index)) {
                fields.insert("kind".into(), json!("animal"));
                fields.insert("set".into(), json!(version));
                fields.insert("index".into(), json!(index));
                fields.insert("color".into(), json!(color));
                return fields;
            }
        }
        Picture::Image { path } if !path.is_empty() => {
            fields.insert("kind".into(), json!("image"));
            fields.insert("path".into(), json!(path));
            return fields;
        }
        _ => {}
    }
    fields.insert("kind".into(), json!("placeholder"));
    fields
}

/// Muted mid-dark colors from the animal set's family; each keeps white initials at 4.5:1 or more. The order is part
/// of the contract: a person's color never changes between releases.
const PLACEHOLDER_PALETTE: [&str; 12] = [
    "#5a4a7a", "#2f6474", "#7a3f4f", "#4a6a2f", "#7a5a34", "#3f6b4f", "#4f4f86", "#5a5a66", "#6a4a6a", "#355f80",
    "#80463a", "#3d6a6a",
];

/// A stable color for a person without an animal: FNV-1a 32 over the seed's UTF-8 (`SZFriendsPlaceholderColor`).
pub fn placeholder_color(seed: &str) -> &'static str {
    let mut hash: u32 = 0x811c_9dc5;
    for byte in seed.bytes() {
        hash ^= u32::from(byte);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    PLACEHOLDER_PALETTE[hash as usize % PLACEHOLDER_PALETTE.len()]
}

fn looks_like_friends_id(text: &str) -> bool {
    let words: Vec<&str> = text.split('-').collect();
    words.len() >= 2 && words.iter().all(|w| !w.is_empty() && w.bytes().all(|b| b.is_ascii_lowercase()))
}

/// The first character people would see as a letter: leading punctuation and symbols skipped ("(Mei)" gives "M"),
/// whole composed characters kept; a word of only symbols gives its first character.
fn first_character(word: &str) -> String {
    let pieces = clusters(word);
    for piece in &pieces {
        if piece.chars().next().is_some_and(char::is_alphanumeric) {
            return piece.clone();
        }
    }
    pieces.into_iter().next().unwrap_or_default()
}

/// Up to two initials from a name, or from a Friends ID's words (`SZFriendsInitials`).
pub fn initials(name_or_friends_id: &str) -> String {
    let trimmed = trim(name_or_friends_id);
    let words: Vec<&str> = if looks_like_friends_id(trimmed) {
        trimmed.split('-').collect()
    } else {
        trimmed.split(is_space_or_newline).filter(|w| !w.is_empty()).collect()
    };
    words.iter().take(2).map(|w| first_character(w)).collect::<String>().to_uppercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initials_and_colors() {
        assert_eq!(initials("Mei Lin"), "ML");
        assert_eq!(initials("tulip-canyon"), "TC");
        assert_eq!(initials("(Mei) lin wong"), "ML");
        assert_eq!(initials("  "), "");
        assert_eq!(placeholder_color(""), PLACEHOLDER_PALETTE[0x811c_9dc5_u32 as usize % 12]);
    }
}

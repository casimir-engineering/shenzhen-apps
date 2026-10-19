//! The discovery merger (`SZFriendsDiscoveryMerger.m`, ADR 0004 § The merger): sightings from every adapter in, one
//! candidate per person out. Pure: every date arrives as an argument.
//!
//! An endpoint is grouped by who it is: a conversation (a tag matched, or a handshake named someone in the list), an
//! identity key not in the list, an unidentified public entry (each its own: entry names are never identity), or a
//! hidden device nobody matches (one per tag). Each method keeps its own expiry, and a candidate goes only when every
//! one of its sightings has expired, so a brief loss on one method does not flip the route icon.

use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap, HashSet};

use super::callbacks::TagMatcher;
use super::{rank, Method, Sighting, Tag};

/// A Bonjour endpoint lingers this long after its removal.
pub const BONJOUR_REMOVAL_GRACE_SECONDS: f64 = 30.0;
/// A Bluetooth sighting lives this long after it was last seen.
pub const BLUETOOTH_SIGHTING_LIFE_SECONDS: f64 = 90.0;

/// One person nearby, identified or not (`SZFriendsCandidate`).
#[derive(Clone, Debug, PartialEq)]
pub struct Candidate {
    /// Stable while any of its sightings lives; `[A-Za-z0-9_-]`, as nearby ids must be.
    pub id: String,
    pub conversation_id: Option<String>,
    /// Public entries of someone not in the list: dialed with XX.
    pub public: bool,
    /// Live sightings, best route first.
    pub sightings: Vec<Sighting>,
    /// The identity key a handshake over one of its public endpoints returned.
    pub identity_key: Option<[u8; 32]>,
}

impl Candidate {
    /// Whether Nearby may show it: a tag matched, or a handshake returned key and profile.
    pub fn identified(&self) -> bool {
        self.conversation_id.is_some() || self.identity_key.is_some()
    }
}

#[derive(Clone, Debug)]
struct Entry {
    sighting: Sighting,
    removed_at: Option<f64>,
    matched: Option<String>,
    identity_key: Option<[u8; 32]>,
    identified_conversation: Option<String>,
    candidate_id: Option<String>,
}

impl Entry {
    fn expires_at(&self) -> Option<f64> {
        match self.sighting.method {
            Method::Bluetooth => Some(self.sighting.seen_at + BLUETOOTH_SIGHTING_LIFE_SECONDS),
            Method::Network => self.removed_at.map(|at| at + BONJOUR_REMOVAL_GRACE_SECONDS),
        }
    }
}

/// See the module documentation.
#[derive(Debug, Default)]
pub struct Merger {
    matcher: TagMatcher,
    entries: BTreeMap<(Method, String), Entry>,
    sequence: HashMap<String, u64>,
    next_sequence: u64,
    candidates: Vec<Candidate>,
    unmatched: Vec<Candidate>,
    signature: String,
    generation: u64,
}

fn match_entry(matcher: &TagMatcher, entry: &mut Entry) {
    let sighting = &entry.sighting;
    // The presence tag says who the device is; a callback tag only that someone who asked for us by ID is there, so
    // it counts only when the presence tag is nobody we know.
    let mut found = sighting.presence_tag.as_ref().and_then(|tag| matcher.conversation(tag));
    for tag in &sighting.callback_tags {
        if found.is_some() {
            break;
        }
        found = matcher.conversation(tag);
    }
    entry.matched = found.map(str::to_owned);
}

fn group_key(key: &(Method, String), entry: &Entry) -> String {
    if let Some(conversation) = entry.matched.as_ref().or(entry.identified_conversation.as_ref()) {
        return format!("c:{conversation}");
    }
    if let Some(identity) = entry.identity_key {
        return format!("k:{}", hex::encode(identity));
    }
    let entry_key = format!("{}|{}", key.0 as u8, key.1);
    if entry.sighting.public {
        return format!("e:{entry_key}");
    }
    match entry.sighting.presence_tag {
        Some(tag) => format!("t:{}", hex::encode(tag)),
        None => format!("u:{entry_key}"),
    }
}

/// Best route first; a lingering endpoint after a live one; then the newest; then by id.
fn compare(a: &Entry, b: &Entry) -> Ordering {
    rank(a.sighting.route)
        .cmp(&rank(b.sighting.route))
        .then_with(|| a.removed_at.is_some().cmp(&b.removed_at.is_some()))
        .then_with(|| b.sighting.seen_at.total_cmp(&a.sighting.seen_at))
        .then_with(|| a.sighting.endpoint.cmp(&b.sighting.endpoint))
}

impl Merger {
    pub fn new(matcher: TagMatcher) -> Self {
        Self { matcher, ..Self::default() }
    }

    /// A new window or a changed secret: every live sighting is matched again.
    pub fn set_matcher(&mut self, matcher: TagMatcher) {
        self.matcher = matcher;
        for entry in self.entries.values_mut() {
            match_entry(&self.matcher, entry);
        }
        self.rebuild();
    }

    pub fn matcher(&self) -> &TagMatcher {
        &self.matcher
    }

    pub fn add_sighting(&mut self, sighting: Sighting) {
        let key = (sighting.method, sighting.endpoint.clone());
        if let Some(entry) = self.entries.get(&key) {
            // Out of order: an older observation never overwrites a newer one or revives a later removal.
            if sighting.seen_at < entry.sighting.seen_at || entry.removed_at.is_some_and(|r| sighting.seen_at < r) {
                return;
            }
        }
        let entry = self.entries.entry(key).or_insert_with(|| Entry {
            sighting: sighting.clone(),
            removed_at: None,
            matched: None,
            identity_key: None,
            identified_conversation: None,
            candidate_id: None,
        });
        entry.sighting = sighting;
        entry.removed_at = None; // seen again within the grace: the loss was a flap
        match_entry(&self.matcher, entry);
        self.rebuild();
    }

    /// Starts the method's grace for this endpoint rather than dropping it at once.
    pub fn remove_endpoint(&mut self, endpoint: &str, method: Method, at: f64) {
        let Some(entry) = self.entries.get_mut(&(method, endpoint.to_owned())) else { return };
        if at < entry.sighting.seen_at || entry.removed_at.is_some() {
            return; // older than the newest sighting, or a repeat that must not extend the grace
        }
        entry.removed_at = Some(at);
        self.rebuild();
    }

    /// Drops sightings past their expiry; `true` when candidates changed.
    pub fn expire(&mut self, now: f64) -> bool {
        let before = self.generation;
        self.entries.retain(|_, entry| entry.expires_at().is_none_or(|at| now < at));
        self.rebuild();
        self.generation != before
    }

    /// Forgets everything at once (Nearby stopped).
    pub fn clear(&mut self) {
        self.entries.clear();
        self.rebuild();
    }

    /// A handshake over a public endpoint returned this key; `conversation_id` names someone in the list.
    pub fn identify(&mut self, endpoint: &str, method: Method, identity_key: [u8; 32], conversation: Option<String>) {
        let Some(entry) = self.entries.get_mut(&(method, endpoint.to_owned())) else { return };
        entry.identity_key = Some(identity_key);
        entry.identified_conversation = conversation;
        self.rebuild();
    }

    /// Friends matched by tag and public endpoints, oldest first.
    pub fn candidates(&self) -> &[Candidate] {
        &self.candidates
    }

    /// What Nearby shows, one per person.
    pub fn identified(&self) -> impl Iterator<Item = &Candidate> {
        self.candidates.iter().filter(|c| c.identified())
    }

    /// Hidden devices whose tag nobody matches, one per tag: never shown; Add by ID and probes go to them.
    pub fn unmatched(&self) -> &[Candidate] {
        &self.unmatched
    }

    pub fn candidate(&self, id: &str) -> Option<&Candidate> {
        self.candidates.iter().chain(&self.unmatched).find(|c| c.id == id)
    }

    /// When the next sighting expires.
    pub fn next_expiry(&self) -> Option<f64> {
        self.entries.values().filter_map(Entry::expires_at).min_by(f64::total_cmp)
    }

    /// Moves whenever candidates or unmatched devices change, and only then.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    fn new_candidate_id(&mut self) -> String {
        // Random rather than a counter: an id a client still holds from before a restart cannot name someone else.
        let mut bytes = [0u8; 12];
        szfriends_crypto::random_bytes(&mut bytes);
        let id = format!("n{}", hex::encode(bytes));
        self.sequence.insert(id.clone(), self.next_sequence);
        self.next_sequence += 1;
        id
    }

    fn oldest_prior(&self, members: &[(Method, String)], claimed: &HashSet<String>) -> Option<String> {
        let mut best: Option<&String> = None;
        for key in members {
            let Some(prior) = self.entries[key].candidate_id.as_ref() else { continue };
            if claimed.contains(prior) || !self.sequence.contains_key(prior) {
                continue;
            }
            if best.is_none_or(|b| self.sequence[prior] < self.sequence[b]) {
                best = Some(prior);
            }
        }
        best.cloned()
    }

    fn rebuild(&mut self) {
        let mut groups: BTreeMap<String, Vec<(Method, String)>> = BTreeMap::new();
        for (key, entry) in &self.entries {
            groups.entry(group_key(key, entry)).or_default().push(key.clone());
        }
        // Older groups claim their ids first: when two candidates merge the older id survives.
        let none = HashSet::new();
        let mut order: Vec<(String, Option<u64>)> = groups
            .iter()
            .map(|(group, members)| (group.clone(), self.oldest_prior(members, &none).map(|id| self.sequence[&id])))
            .collect();
        order.sort_by(|a, b| match (a.1, b.1) {
            (Some(x), Some(y)) if x != y => x.cmp(&y),
            (Some(_), None) => Ordering::Less,
            (None, Some(_)) => Ordering::Greater,
            _ => a.0.cmp(&b.0),
        });
        let mut claimed = HashSet::new();
        let (mut candidates, mut unmatched) = (Vec::new(), Vec::new());
        let mut signature = String::new();
        for (group, _) in order {
            let mut members = groups.remove(&group).unwrap_or_default();
            members.sort_by(|a, b| compare(&self.entries[a], &self.entries[b]));
            let id = match self.oldest_prior(&members, &claimed) {
                Some(id) => id,
                None => self.new_candidate_id(),
            };
            claimed.insert(id.clone());
            let mut sightings = Vec::new();
            let mut identity_key = None;
            let mut all_public = true;
            for key in &members {
                let entry = self.entries.get_mut(key).expect("grouped from the entries");
                entry.candidate_id = Some(id.clone());
                sightings.push(entry.sighting.clone());
                identity_key = identity_key.or(entry.identity_key);
                all_public &= entry.sighting.public;
            }
            let conversation_id = group.strip_prefix("c:").map(str::to_owned);
            let candidate = Candidate {
                id: id.clone(),
                public: conversation_id.is_none() && all_public,
                conversation_id,
                identity_key,
                sightings,
            };
            signature.push_str(&format!("{group}={id}{}[", identity_key.map(hex::encode).unwrap_or_default()));
            for s in &candidate.sightings {
                let tag = s.presence_tag.map(hex::encode).unwrap_or_default();
                signature.push_str(&format!("{}/{}/{}/{tag}/{}/", s.method as u8, s.endpoint, s.route as u8, s.public));
                for callback in &s.callback_tags {
                    signature.push_str(&hex::encode(callback));
                }
            }
            signature.push_str("];");
            let hidden = group.starts_with("t:") || group.starts_with("u:");
            if hidden { &mut unmatched } else { &mut candidates }.push(candidate);
        }
        self.sequence.retain(|id, _| claimed.contains(id));
        let by_sequence = |c: &Candidate| self.sequence.get(&c.id).copied().unwrap_or(u64::MAX);
        candidates.sort_by_key(by_sequence);
        unmatched.sort_by_key(by_sequence);
        self.candidates = candidates;
        self.unmatched = unmatched;
        if signature != self.signature {
            self.signature = signature;
            self.generation += 1;
        }
    }
}

/// The tag a sighting showed for `conversation`: the one a relayer had to copy to be dialed at all.
pub fn matched_tag(sighting: &Sighting, matcher: &TagMatcher, conversation: &str) -> Option<Tag> {
    let tags = sighting.presence_tag.iter().chain(&sighting.callback_tags);
    tags.clone().find(|tag| matcher.conversation(tag) == Some(conversation)).or(sighting.presence_tag.as_ref()).copied()
}

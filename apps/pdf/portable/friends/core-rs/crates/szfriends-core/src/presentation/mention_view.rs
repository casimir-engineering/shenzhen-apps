//! Mentions as the reader sees them (`SZFriendsSnapshotBuilder+Mentions.m`, PROTOCOL.md § Mentions, ADR 0007). Whoever
//! reads a mention sees it resolved against their own Friends list: a friend (matched by key) under the reader's own
//! name for them, which opens their chat; the reader themselves; anyone else under the sender's name with a card to add
//! them; and a forged mention (a friend's or the reader's own ID under another key) as plain text. The ID and key never
//! reach a view except on that card, which needs them to send add_from_mention.

use std::collections::HashMap;

use serde_json::{json, Value};

use super::facts::{PersonFacts, ProfileFacts, Relation};
use super::mentions::{key_string, markdown_literal, text_links, TextLink, MENTIONS_MAX};
use super::text::{from_utf16, non_empty_trimmed, utf16};
use super::SnapshotBuilder;

/// Who the mentions in a snapshot resolve against: this person's own identity and Friends list. A friend is matched
/// by identity key only, so a sender cannot make a stranger look like a friend by borrowing a friend's name or ID.
#[derive(Clone, Debug)]
pub struct MentionDirectory {
    profile: ProfileFacts,
    people: Vec<PersonFacts>,
    by_key: HashMap<[u8; 32], usize>,
    by_id: HashMap<String, Vec<usize>>,
}

impl MentionDirectory {
    pub fn new(people: &[PersonFacts], profile: &ProfileFacts) -> Self {
        let mut by_key = HashMap::new();
        let mut by_id: HashMap<String, Vec<usize>> = HashMap::new();
        for (index, person) in people.iter().enumerate() {
            if let Some(key) = person.identity_key {
                by_key.insert(key, index);
            }
            if let Some(id) = person.friends_id.as_deref().filter(|id| !id.is_empty()) {
                by_id.entry(id.to_owned()).or_default().push(index);
            }
        }
        Self { profile: profile.clone(), people: people.to_vec(), by_key, by_id }
    }

    pub fn profile(&self) -> &ProfileFacts {
        &self.profile
    }

    pub fn person_with_identity_key(&self, key: &[u8; 32]) -> Option<&PersonFacts> {
        self.by_key.get(key).map(|i| &self.people[*i])
    }

    pub fn people_with_friends_id(&self, friends_id: &str) -> impl Iterator<Item = &PersonFacts> {
        self.by_id.get(friends_id).into_iter().flatten().map(|i| &self.people[*i])
    }
}

/// A message's text as one person sees it, its mentions resolved.
pub(crate) struct ResolvedText {
    /// `text`: mentions as links to `mentions`, or literal.
    pub markdown: String,
    /// What a person reads, each mention as "@Name".
    pub plain: String,
    /// The plain-text form, a mention segment per link.
    pub segments: Vec<Value>,
    /// None when no mention shows as a link.
    pub mentions: Option<Vec<Value>>,
}

impl SnapshotBuilder {
    fn mention_object(
        &self,
        url: &str,
        kind: &str,
        label: &str,
        tooltip: Option<String>,
        conversation: Option<&str>,
        card: Value,
    ) -> Value {
        json!({
            "url": url,
            "kind": kind,
            "label": format!("@{label}"),
            "tooltip": tooltip,
            "conversation_id": conversation,
            "card": card,
        })
    }

    /// Someone the reader is not friends with: the sender's name, a card with the ID, and what the reader can do.
    fn stranger_mention(
        &self,
        link: &TextLink,
        person: Option<&PersonFacts>,
        directory: &MentionDirectory,
        url: &str,
    ) -> Value {
        let s = &self.strings;
        let name = link.name.clone().unwrap_or_default();
        let friends_id = link.friends_id.clone().unwrap_or_default();
        let key = link.identity_key.unwrap_or([0; 32]);
        let id = s.display_id(Some(&friends_id));
        let first = s.first_name(Some(&name), None);
        let values = [("name", name.as_str()), ("id", id.as_str()), ("first", first.as_str())];
        // The host vouched that this ID now belongs to another key: Add would reach someone else.
        let moved = directory
            .people_with_friends_id(&friends_id)
            .any(|holder| holder.friends_id_confirmed && holder.identity_key != Some(key));
        // Nobody known by this key reads as removed: nothing between them, so Add.
        let relation = person.map_or(Relation::Removed, |p| p.relation);
        let mut actions = Vec::new();
        let state = if relation == Relation::Blocked {
            "blocked"
        } else if moved {
            "moved"
        } else if relation == Relation::OutgoingRequest {
            "requested"
        } else if relation == Relation::IncomingRequest {
            actions.push(Value::Object(self.action("accept_request", s.text("action.accept"), "primary")));
            actions.push(Value::Object(self.action("decline_request", s.text("action.decline"), "secondary")));
            actions.push(Value::Object(self.block_action(&name, s.text_with("action.block", &values))));
            "asked"
        } else {
            let mut add = self.action("add_from_mention", s.text("mention.action.add"), "primary");
            add.insert("friends_id".into(), json!(friends_id));
            add.insert("identity_key".into(), json!(key_string(&key)));
            add.insert("name".into(), json!(name));
            actions.push(Value::Object(add));
            "stranger"
        };
        let status = (state != "stranger").then(|| s.text_with(&format!("mention.card.{state}"), &values));
        let card = json!({
            "title": name,
            "id_label": s.text_with("mention.card.id", &values),
            "status_label": status,
            "conversation_id": person.map(|p| p.conversation_id.clone()),
            "actions": actions,
        });
        let tooltip = s.text_with(&format!("mention.tooltip.{state}"), &values);
        self.mention_object(url, "stranger", &name, Some(tooltip), None, card)
    }

    /// The protocol's mention object for a well-formed link, or None when it shows as plain text: no directory, or a
    /// forged mention.
    fn mention_for_link(&self, link: &TextLink, url: &str, directory: Option<&MentionDirectory>) -> Option<Value> {
        let directory = directory?;
        if !link.is_mention {
            return None;
        }
        let key = link.identity_key?;
        let profile = directory.profile();
        if profile.identity_public_key == Some(key) {
            let own = non_empty_trimmed(profile.name.as_deref())
                .map(str::to_owned)
                .unwrap_or_else(|| self.strings.display_id(Some(&profile.friends_id)));
            return Some(self.mention_object(url, "you", &own, None, None, Value::Null));
        }
        let person = directory.person_with_identity_key(&key);
        if let Some(friend) = person.filter(|p| p.relation == Relation::Friend) {
            let first = self.first_name_for_person(friend);
            let tooltip = self.strings.text_with("mention.tooltip.friend", &[("first", &first)]);
            let title = self.title_for_person(friend);
            return Some(self.mention_object(
                url,
                "friend",
                &title,
                Some(tooltip),
                Some(&friend.conversation_id),
                Value::Null,
            ));
        }
        // Forged: the reader's own ID, or a friend's, under a key that is not theirs.
        let friends_id = link.friends_id.as_deref().unwrap_or("");
        if profile.friends_id == friends_id {
            return None;
        }
        if directory.people_with_friends_id(friends_id).any(|p| p.relation == Relation::Friend) {
            return None;
        }
        Some(self.stranger_mention(link, person, directory, url))
    }

    /// Each link's mention object, or None where it shows as plain text. Links count toward `url`s only once
    /// resolved, so the n-th link a view can click is always "szfriends:mention?ref=n".
    pub(crate) fn mentions_for_links(
        &self,
        links: &[TextLink],
        directory: Option<&MentionDirectory>,
    ) -> Vec<Option<Value>> {
        let mut seen = 0;
        let mut linked = 0;
        let mut mentions = Vec::with_capacity(links.len());
        for link in links {
            let url = format!("szfriends:mention?ref={linked}");
            // Beyond the twentieth a mention is plain text, as the receiving helper already made it.
            let mention = if link.is_mention && {
                seen += 1;
                seen <= MENTIONS_MAX
            } {
                self.mention_for_link(link, &url, directory)
            } else {
                None
            };
            if mention.is_some() {
                linked += 1;
            }
            mentions.push(mention);
        }
        mentions
    }

    /// `wants_segments` false: only the plain words, for previews, without finding web links in them.
    pub(crate) fn resolved_text(
        &self,
        text: &str,
        directory: Option<&MentionDirectory>,
        wants_segments: bool,
    ) -> ResolvedText {
        let links = text_links(text);
        let segments_of = |run: &str| if wants_segments { self.segments_for_text(run) } else { Vec::new() };
        if links.is_empty() {
            return ResolvedText {
                markdown: text.into(),
                plain: text.into(),
                segments: segments_of(text),
                mentions: None,
            };
        }
        // Clients that cannot show a mention as a link get its words as plain text.
        let linked = self.audience().has("mentions");
        let resolved = self.mentions_for_links(&links, directory);
        let units = utf16(text);
        let (mut markdown, mut plain, mut run) = (String::new(), String::new(), String::new());
        let mut segments: Vec<Value> = Vec::new();
        let mut mentions: Vec<Value> = Vec::new();
        let mut cursor = 0;
        for (link, mention) in links.iter().zip(resolved) {
            let between = from_utf16(&units[cursor..link.range.0]);
            let label = match &mention {
                Some(m) => m["label"].as_str().unwrap_or_default().to_owned(),
                None => link.shown_text.clone(),
            };
            cursor = link.end();
            markdown.push_str(&between);
            plain.push_str(&between);
            plain.push_str(&label);
            run.push_str(&between);
            let Some(mention) = mention.filter(|_| linked) else {
                markdown.push_str(&markdown_literal(&label));
                run.push_str(&label);
                continue;
            };
            markdown.push_str(&format!(
                "[{}]({})",
                markdown_literal(&label),
                mention["url"].as_str().unwrap_or_default()
            ));
            if wants_segments && !run.is_empty() {
                segments.extend(self.segments_for_text(&run));
            }
            run.clear();
            segments.push(json!({"text": label, "mention": mentions.len()}));
            mentions.push(mention);
        }
        let tail = from_utf16(&units[cursor..]);
        markdown.push_str(&tail);
        plain.push_str(&tail);
        run.push_str(&tail);
        if wants_segments && (!run.is_empty() || segments.is_empty()) {
            segments.extend(self.segments_for_text(&run));
        }
        ResolvedText {
            markdown,
            plain,
            segments: if wants_segments { segments } else { Vec::new() },
            mentions: (!mentions.is_empty()).then_some(mentions),
        }
    }

    /// Only the words, for list previews.
    pub(crate) fn plain_text_of(&self, text: &str, directory: Option<&MentionDirectory>) -> String {
        self.resolved_text(text, directory, false).plain
    }

    /// The composer's `mention_note`: None when the client shows no mentions, null when the composer is off.
    pub(crate) fn mention_note(&self, person: &PersonFacts, enabled: bool) -> Option<Value> {
        if !self.audience().has("mentions") {
            return None;
        }
        if !enabled {
            return Some(Value::Null);
        }
        Some(json!(self.strings.text_with("mention.note", &[("first", &self.first_name_for_person(person))])))
    }

    /// Whether a list row can be named in a mention (it carries the person's ID and key), or None when the client
    /// shows no mentions.
    pub(crate) fn mentionable(&self, person: &PersonFacts) -> Option<bool> {
        if !self.audience().has("mentions") {
            return None;
        }
        let has_id = person.friends_id.as_deref().is_some_and(|id| !id.is_empty());
        Some(person.relation == Relation::Friend && has_id && person.identity_key.is_some())
    }
}

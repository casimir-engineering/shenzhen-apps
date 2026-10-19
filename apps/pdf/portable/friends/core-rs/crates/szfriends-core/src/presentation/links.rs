//! Links (`SZFriendsSnapshotBuilder+Links.m`, PROTOCOL.md § Links): the profile's "Your links", the cards open_link
//! answers with, and the messages after Add, Download and Copy Download Link.

use serde_json::{json, Value};

use super::avatar::Picture;
use super::facts::{DownloadLinkFacts, LinksFacts};
use super::text::non_empty_trimmed;
use super::SnapshotBuilder;

impl SnapshotBuilder {
    fn expiry_label(&self, expires_at: f64, now: f64) -> String {
        let s = &self.strings;
        match self.audience().time_zone.days_between(now, expires_at).max(0) {
            0 => s.text("links.expires.today"),
            1 => s.text("links.expires.tomorrow"),
            days => s.text_count("links.expires.days", days, &[]),
        }
    }

    fn download_row(&self, link: &DownloadLinkFacts, now: f64) -> Value {
        let s = &self.strings;
        let mut revoke = self.action("revoke_link", s.text("links.revoke"), "link");
        revoke.insert("link_id".into(), json!(link.link_id));
        let downloads = if link.downloads == 0 {
            s.text("links.downloads.none")
        } else {
            s.text_count("links.downloads.count", link.downloads as i64, &[])
        };
        json!({
            "link_id": link.link_id,
            "file_name": link.file_name,
            "downloads_label": downloads,
            "expires_label": self.expiry_label(link.expires_at, now),
            "revoke": revoke,
        })
    }

    /// The profile's "links": None unless the audience's helper announces "links" and a friend link can be made.
    pub(crate) fn links_section(&self, links: Option<&LinksFacts>) -> Option<Value> {
        let links = links?;
        let url = links.friend_url.as_deref().filter(|u| !u.is_empty())?;
        if !self.audience().helper_has("links") {
            return None;
        }
        let s = &self.strings;
        let mut reset = self.action("reset_friend_link", s.text("links.friend.reset"), "secondary");
        let confirm = self.confirm(
            "links.friend.reset.confirm.title",
            "links.friend.reset.confirm.body",
            "links.friend.reset.confirm.button",
            &[],
            true,
        );
        reset.insert("confirm".into(), confirm);
        let downloads: Vec<Value> = links.downloads.iter().map(|link| self.download_row(link, links.now)).collect();
        let empty = downloads.is_empty().then(|| s.text("links.downloads.empty"));
        Some(json!({
            "title": s.text("links.title"),
            "friend": {
                "label": s.text("links.friend.label"),
                "url": url,
                "note": s.text("links.friend.note"),
                "copy_label": s.text("static.copy"),
                "reset": reset,
            },
            "downloads_label": s.text("links.downloads.label"),
            "downloads_empty": empty,
            "downloads": downloads,
        }))
    }

    /// A friend link's card: "Add Mei?", the Friends ID, why the request is accepted at once, Add (add_from_link with
    /// the payload); or, when this person is already a friend, saying so with nothing to press.
    pub fn friend_link_card(&self, name: Option<&str>, friends_id: &str, payload: &str, already_friend: bool) -> Value {
        let s = &self.strings;
        let trimmed = non_empty_trimmed(name);
        let id = s.display_id(Some(friends_id));
        let who = trimmed.map(str::to_owned).unwrap_or_else(|| id.clone());
        let values = [("name", who.as_str()), ("id", id.as_str())];
        let mut add = self.action("add_from_link", s.text("link.friend.add"), "primary");
        add.insert("payload".into(), json!(payload));
        json!({
            "kind": "friend",
            "title": s.text_with(if already_friend { "link.friend.already" } else { "link.friend.title" }, &values),
            "subtitle": s.text_with("link.friend.subtitle", &values),
            "note": if already_friend { Value::Null } else { json!(s.text_with("link.friend.note", &values)) },
            "avatar": self.avatar_for_picture(&Picture::Placeholder, friends_id, trimmed.unwrap_or(friends_id)),
            "actions": if already_friend { json!([]) } else { json!([add]) },
        })
    }

    /// A download link's card: what pressing Download does (receive_link with the payload).
    pub fn download_link_card(&self, payload: &str) -> Value {
        let s = &self.strings;
        let mut download = self.action("receive_link", s.text("link.download.action"), "primary");
        download.insert("payload".into(), json!(payload));
        json!({
            "kind": "download",
            "title": s.text("link.download.title"),
            "subtitle": null,
            "note": s.text("link.download.note"),
            "avatar": null,
            "actions": [download],
        })
    }

    /// add_from_link's result.message.
    pub fn link_request_sent_message(&self, name: &str, online: bool) -> String {
        self.strings.text_with(if online { "link.request_sent.online" } else { "link.request_sent" }, &[("name", name)])
    }

    /// receive_link's result.message: where the file will be.
    pub fn link_receiving_message(&self, file_name: &str, sender: Option<&str>) -> String {
        let s = &self.strings;
        match non_empty_trimmed(sender) {
            None => s.text_with("link.receiving.anonymous", &[("file", file_name)]),
            Some(name) => {
                let first = s.first_name(Some(name), None);
                s.text_with("link.receiving", &[("file", file_name), ("name", name), ("first", &first)])
            }
        }
    }

    /// make_download_link's result.message, with the day the link stops working ("19 October").
    pub fn download_link_made_message(&self, expires_at: f64) -> String {
        let civil = self.audience().time_zone.civil(expires_at);
        let month = self.strings.text(&format!("month.long.{}", civil.month));
        let date = format!("{} {month}", civil.day);
        self.strings.text_with("link.made", &[("date", &date)])
    }
}

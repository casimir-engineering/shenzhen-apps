//! System notifications' words (ADR 0017, PROTOCOL.md § Notifications; `SZFriendsCatalogNotifications.m`): what a
//! banner or a lock screen says about a friend's message, file, request or acceptance, or a computer asking to join,
//! and this device's Notifications block in Settings and the list's ask card. The helper decides what notifies; this
//! only words it, from the catalog, so both helpers say the same.

use serde_json::{json, Value};

use super::facts::{PersonFacts, ProfileFacts};
use super::text::{composed_range16, from_utf16, utf16};
use super::SnapshotBuilder;

/// Longer message text is cut: a banner shows a few lines, and a lock screen fewer.
const BODY_LENGTH: usize = 400;

/// What the system allows on this device (the notifier's word).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum NotifyPermission {
    /// Windows and Linux: nothing to ask.
    #[default]
    NotNeeded,
    Granted,
    Denied,
    NotAsked,
    /// Linux with no notification service on the session bus.
    Unavailable,
}

/// This device's notification switches and permission: never synced, a person may want text on a computer but not on
/// a phone's lock screen.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NotificationFacts {
    /// "Show notifications".
    pub enabled: bool,
    /// "Show message text": off, notifications say who sent something, not what it says.
    pub preview: bool,
    /// Android: "Stay reachable in the background".
    pub background: bool,
    pub permission: NotifyPermission,
    /// An iPhone or iPad, which gets messages only while the app is open: Settings says so.
    pub ios: bool,
    /// Windows, whose own Settings app turns an app's notifications off.
    pub windows: bool,
    /// The person chose Not Now on the ask card.
    pub ask_dismissed: bool,
    /// The person has used Friends here (an `activate`): only then may the ask card show.
    pub activated: bool,
}

impl Default for NotificationFacts {
    fn default() -> Self {
        Self {
            enabled: true,
            preview: true,
            background: false,
            permission: NotifyPermission::NotNeeded,
            ios: false,
            windows: false,
            ask_dismissed: false,
            activated: false,
        }
    }
}

/// The people notices: a request, an acceptance, a friend link used either way.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PeopleNotice {
    /// A friend request arrived.
    Request,
    /// They accepted this person's request.
    Accepted,
    /// Someone added this person through this person's friend link.
    LinkUsed,
    /// This person added someone through that person's friend link, and it went through.
    LinkAdded,
}

/// A notification's title and body.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NotificationWords {
    pub title: String,
    pub body: String,
}

/// The inline reply's words (messages only).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReplyWords {
    pub label: String,
    pub placeholder: String,
    pub send: String,
}

impl SnapshotBuilder {
    /// The friend as the list names them.
    pub fn notification_title(&self, person: &PersonFacts) -> String {
        self.title_for_person(person)
    }

    /// Messages in one conversation, oldest first, that land in one burst: one notification for the newest. Without
    /// previews it says how many, never what.
    pub fn notify_messages(&self, person: &PersonFacts, texts: &[&str], preview: bool) -> NotificationWords {
        let s = &self.strings;
        let body = match texts.last() {
            Some(text) if preview => self.notification_text(text),
            _ => s.text_count("notify.message.hidden", texts.len().max(1) as i64, &[]),
        };
        NotificationWords { title: self.title_for_person(person), body }
    }

    /// Files a friend offered together (`received` false) or that arrived together, accepted automatically (`received`
    /// true). Without previews no file name shows.
    pub fn notify_files(
        &self,
        person: &PersonFacts,
        names: &[&str],
        received: bool,
        preview: bool,
    ) -> NotificationWords {
        let s = &self.strings;
        let name = self.title_for_person(person);
        let base = if received { "notify.file.received" } else { "notify.file.offer" };
        let count = names.len().max(1) as i64;
        let body = match names.first() {
            Some(file) if preview && count == 1 => s.text_with(base, &[("name", &name), ("file", file)]),
            Some(file) if preview => {
                s.text_count(&format!("{base}.more"), count - 1, &[("name", &name), ("file", file)])
            }
            _ => s.text_count(&format!("{base}.hidden"), count, &[("name", &name)]),
        };
        NotificationWords { title: name, body }
    }

    pub fn notify_people(&self, person: &PersonFacts, notice: PeopleNotice) -> NotificationWords {
        let key = match notice {
            PeopleNotice::Request => "notify.request",
            PeopleNotice::Accepted => "notify.accepted",
            PeopleNotice::LinkUsed => "notify.link.used",
            PeopleNotice::LinkAdded => "notify.link.added",
        };
        NotificationWords { title: self.title_for_person(person), body: self.strings.text(key) }
    }

    /// A computer or phone asking to join this person's profile, by the name it gave.
    pub fn notify_join(&self, device: &str) -> NotificationWords {
        let s = &self.strings;
        NotificationWords {
            title: s.text_with("notify.join.title", &[("device", device)]),
            body: s.text("notify.join.body"),
        }
    }

    pub fn notify_reply(&self, person: &PersonFacts) -> ReplyWords {
        let s = &self.strings;
        ReplyWords {
            label: s.text("notify.reply"),
            placeholder: s.text_with("notify.reply.placeholder", &[("name", &self.title_for_person(person))]),
            send: s.text("notify.reply.send"),
        }
    }

    /// A message's words as a banner shows them: mentions as the names they show under, cut when long.
    fn notification_text(&self, text: &str) -> String {
        let plain = self.plain_text_of(text, self.mention_directory.as_ref());
        let trimmed = plain.trim();
        let units = utf16(trimmed);
        if units.len() <= BODY_LENGTH {
            return trimmed.to_owned();
        }
        let (start, end) = composed_range16(trimmed, 0, BODY_LENGTH);
        format!("{}…", from_utf16(&units[start..end]))
    }

    /// Settings' Notifications block (helper capability `notifications`): the two switches, the permission's line
    /// with its one action, and on an Android host that can stay running (`background.reachable`) the background
    /// switch with what it costs.
    pub(crate) fn notifications_settings(&self, facts: &NotificationFacts) -> Value {
        let s = &self.strings;
        let app = self.audience().app_name.clone();
        let (note, action) = match facts.permission {
            NotifyPermission::NotAsked => {
                let allow = self.action("allow_notifications", s.text("settings.notifications.allow"), "secondary");
                (s.text("settings.notifications.note.not_asked"), Value::Object(allow))
            }
            NotifyPermission::Denied => {
                let (note, label) = if facts.windows {
                    (
                        s.text("settings.notifications.note.denied.windows"),
                        s.text("settings.notifications.open_settings.windows"),
                    )
                } else if self.on_phone() {
                    (
                        s.text_with("settings.notifications.note.denied.phone", &[("app", &app)]),
                        s.text("settings.notifications.open_settings.phone"),
                    )
                } else {
                    (
                        s.text("settings.notifications.note.denied.mac"),
                        s.text("settings.notifications.open_settings.mac"),
                    )
                };
                let mut open = self.action("open_settings", label, "secondary");
                open.insert("settings_target".into(), json!("notifications"));
                (note, Value::Object(open))
            }
            NotifyPermission::Unavailable => (s.text("settings.notifications.note.unavailable"), Value::Null),
            NotifyPermission::Granted | NotifyPermission::NotNeeded if facts.ios => {
                (s.text_with("settings.notifications.note.ios", &[("app", &app)]), Value::Null)
            }
            NotifyPermission::Granted | NotifyPermission::NotNeeded => (String::new(), Value::Null),
        };
        let mut block = json!({
            "label": s.text("settings.notifications.label"),
            "enabled": {"label": s.text("settings.notifications.enabled"), "value": facts.enabled},
            "preview": {
                "label": s.text("settings.notifications.preview"),
                "note": s.text("settings.notifications.preview.note"),
                "value": facts.preview,
            },
            "note": note,
            "action": action,
        });
        if self.audience().has("background.reachable") {
            block["background"] = json!({
                "label": s.text("settings.notifications.background.label"),
                "note": s.text_with("settings.notifications.background.note", &[("app", &app)]),
                "value": facts.background,
            });
        }
        block
    }

    /// The list's ask card (clients that declare `notifications.ask`): once the person has used Friends, while the
    /// system has not been asked, Notifications is on and they have not chosen Not Now.
    pub(crate) fn notifications_banner(&self, profile: &ProfileFacts) -> Option<Value> {
        let facts = profile.notifications.as_ref()?;
        let shows = self.audience().has("notifications.ask")
            && self.audience().helper_has("notifications")
            && facts.permission == NotifyPermission::NotAsked
            && facts.enabled
            && facts.activated
            && !facts.ask_dismissed;
        if !shows {
            return None;
        }
        let s = &self.strings;
        let allow = self.action("allow_notifications", s.text("banner.notifications.allow"), "primary");
        let mut dismiss = self.action("dismiss_banner", s.text("banner.notifications.dismiss"), "link");
        dismiss.insert("kind".into(), json!("notifications"));
        Some(json!({
            "kind": "notifications",
            "text": s.text("banner.notifications.text"),
            "action": allow,
            "dismiss": dismiss,
        }))
    }
}

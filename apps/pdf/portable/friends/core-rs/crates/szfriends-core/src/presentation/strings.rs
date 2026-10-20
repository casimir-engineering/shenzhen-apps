//! Catalog lookup and the formatting every view needs: times, sizes, durations, routes (`SZFriendsStrings.m`). All
//! wording comes from the catalog; this file only decides which entry applies and fills it. Dates are computed in the
//! audience's time zone and spelled from the catalog's month and weekday names.

use std::collections::BTreeMap;

use super::catalog;
use super::facts::{Audience, RouteKind, RouteMethod};
use super::text::{is_space, trim};

/// Placeholder values for a catalog template.
pub type Values<'a> = &'a [(&'a str, &'a str)];

/// The catalog for one audience, and the words built from it.
#[derive(Clone, Debug)]
pub struct Strings {
    audience: Audience,
}

impl Strings {
    pub fn new(audience: Audience) -> Self {
        Self { audience }
    }

    pub fn audience(&self) -> &Audience {
        &self.audience
    }

    /// The helper announces "online" to this audience: waiting words say "online or nearby", never "nearby" alone.
    pub fn reaches_online(&self) -> bool {
        self.audience.helper_has("online")
    }

    // Catalog lookup

    pub fn has(&self, key: &str) -> bool {
        catalog::english().contains_key(key)
    }

    pub fn text(&self, key: &str) -> String {
        self.text_with(key, &[])
    }

    /// The template for `key` with its `{name}` placeholders filled from `values`. A missing key shows as itself and a
    /// missing value as its placeholder; both are recorded ([`catalog::missing_keys`]).
    pub fn text_with(&self, key: &str, values: Values) -> String {
        let Some(template) = catalog::english().get(key) else {
            catalog::record_missing(key.to_owned());
            return key.to_owned();
        };
        if !template.contains('{') {
            return (*template).to_owned();
        }
        // {apps} is the catalog's own (apps.with_friends), so no caller has to pass it and no string names the apps.
        let apps;
        let mut with_apps: Vec<(&str, &str)>;
        let values = if template.contains("{apps}") && !values.iter().any(|(name, _)| *name == "apps") {
            apps = catalog::english().get("apps.with_friends").copied().unwrap_or_default();
            with_apps = values.to_vec();
            with_apps.push(("apps", apps));
            &with_apps[..]
        } else {
            values
        };
        if values.is_empty() {
            return (*template).to_owned();
        }
        let mut result = String::with_capacity(template.len() + 32);
        let mut rest = *template;
        while let Some(open) = rest.find('{') {
            result.push_str(&rest[..open]);
            let after = &rest[open + 1..];
            let Some(close) = after.find('}') else {
                // An unclosed brace is literal text.
                result.push('{');
                result.push_str(after);
                return result;
            };
            let name = &after[..close];
            match values.iter().find(|(n, _)| *n == name) {
                Some((_, value)) => result.push_str(value),
                None => {
                    catalog::record_missing(format!("{key}{{{name}}}"));
                    result.push('{');
                    result.push_str(name);
                    result.push('}');
                }
            }
            rest = &after[close + 1..];
        }
        result.push_str(rest);
        result
    }

    /// `<key>.one` or `<key>.other` for `count`, with `{count}` filled along with `values`.
    pub fn text_count(&self, key: &str, count: i64, values: Values) -> String {
        let number = count.to_string();
        let mut filled: Vec<(&str, &str)> = values.to_vec();
        filled.push(("count", &number));
        let one = format!("{key}.one");
        if count == 1 && self.has(&one) {
            return self.text_with(&one, &filled);
        }
        self.text_with(&format!("{key}.other"), &filled)
    }

    /// welcome.strings: the static chrome labels PROTOCOL.md § Static strings lists. Only `{apps}` is filled here; the
    /// placeholders views and hosts fill stay as they are.
    pub fn static_strings(&self) -> BTreeMap<String, String> {
        const KEYS: [&str; 33] = [
            "button_label",
            "tab_friends",
            "tab_nearby",
            "search_placeholder",
            "people_nearby",
            "back",
            "copy",
            "copied",
            "copy_your_id",
            "edit_name",
            "conversation_search_placeholder",
            "attach_keys",
            "attach_note",
            "drop_hint",
            "drop_folders_refused",
            "drop_not_a_file",
            "drop_send_one",
            "drop_send_many",
            "drop_send_file",
            "drop_send_file_and_more",
            "animals_title",
            "crop_title",
            "crop_use",
            "cancel",
            "loading",
            "load_earlier",
            "link_open",
            "link_open_email",
            "link_elsewhere",
            "queued_note",
            "show_all",
            "save",
            "name_empty",
        ];
        let apps = self.text("apps.with_friends");
        let values: Values = &[
            ("apps", &apps),
            ("count", "{count}"),
            ("name", "{name}"),
            ("host", "{host}"),
            ("shown", "{shown}"),
            ("first", "{first}"),
        ];
        let mut strings: BTreeMap<String, String> =
            KEYS.iter().map(|k| ((*k).to_owned(), self.text_with(&format!("static.{k}"), values))).collect();
        if self.reaches_online() {
            strings.insert("queued_note".into(), self.text_with("static.queued_note.online", values));
        }
        strings
    }

    // Dates

    fn days_from(&self, date: f64, now: f64) -> i64 {
        self.audience.time_zone.days_between(date, now)
    }

    pub fn is_same_day(&self, date: f64, other: f64) -> bool {
        self.days_from(date, other) == 0
    }

    /// "14:32".
    pub fn clock_label(&self, date: f64) -> String {
        let c = self.audience.time_zone.civil(date);
        format!("{:02}:{:02}", c.hour, c.minute)
    }

    fn weekday(&self, date: f64) -> String {
        self.text(&format!("weekday.{}", self.audience.time_zone.civil(date).weekday))
    }

    /// "3 Oct", or "3 Oct 2025" outside the current year; `long_month` spells "October" for speech.
    fn calendar_date(&self, date: f64, now: f64, long_month: bool) -> String {
        let zone = &self.audience.time_zone;
        let c = zone.civil(date);
        let month = self.text(&format!("month.{}.{}", if long_month { "long" } else { "short" }, c.month));
        let key = if c.year == zone.civil(now).year { "date.day_month" } else { "date.day_month_year" };
        self.text_with(key, &[("day", &c.day.to_string()), ("month", &month), ("year", &c.year.to_string())])
    }

    fn relative_day(&self, date: f64, now: f64, capitalized: bool) -> Option<String> {
        match self.days_from(date, now) {
            0 => Some(self.text(if capitalized { "time.today" } else { "time.today_lower" })),
            1 => Some(self.text(if capitalized { "time.yesterday" } else { "time.yesterday_lower" })),
            2..=6 => Some(self.weekday(date)),
            _ => None,
        }
    }

    /// "14:32" today, "Yesterday", a weekday within six days, "3 Oct" this year, "3 Oct 2025" otherwise.
    pub fn time_label(&self, date: f64, now: f64) -> String {
        if self.days_from(date, now) == 0 {
            return self.clock_label(date);
        }
        self.relative_day(date, now, true).unwrap_or_else(|| self.calendar_date(date, now, false))
    }

    /// "14:40", "yesterday", "3 October".
    pub fn time_accessibility_label(&self, date: f64, now: f64) -> String {
        if self.days_from(date, now) == 0 {
            return self.clock_label(date);
        }
        self.relative_day(date, now, false).unwrap_or_else(|| self.calendar_date(date, now, true))
    }

    /// "Today", "Thursday", "2 Oct".
    pub fn day_label(&self, date: f64, now: f64) -> String {
        self.relative_day(date, now, true).unwrap_or_else(|| self.calendar_date(date, now, false))
    }

    /// "Today", "2 October".
    pub fn day_accessibility_label(&self, date: f64, now: f64) -> String {
        self.relative_day(date, now, true).unwrap_or_else(|| self.calendar_date(date, now, true))
    }

    /// "today at 14:40", "3 Oct at 09:10".
    pub fn moment_phrase(&self, date: f64, now: f64) -> String {
        let day = self.relative_day(date, now, false).unwrap_or_else(|| self.calendar_date(date, now, false));
        self.text_with("time.moment", &[("day", &day), ("time", &self.clock_label(date))])
    }

    /// "2 October at 16:20".
    pub fn moment_accessibility_phrase(&self, date: f64, now: f64) -> String {
        let day = self.relative_day(date, now, false).unwrap_or_else(|| self.calendar_date(date, now, true));
        self.text_with("time.moment", &[("day", &day), ("time", &self.clock_label(date))])
    }

    /// "today", "on 3 Oct".
    pub fn day_phrase(&self, date: f64, now: f64) -> String {
        let days = self.days_from(date, now);
        let day = self.relative_day(date, now, false).unwrap_or_else(|| self.calendar_date(date, now, false));
        if days == 0 || days == 1 {
            return day;
        }
        self.text_with("time.on_day", &[("day", &day)])
    }

    /// "d_20261012".
    pub fn day_item_id(&self, date: f64) -> String {
        let c = self.audience.time_zone.civil(date);
        format!("d_{:04}{:02}{:02}", c.year, c.month, c.day)
    }

    // Small wording helpers

    /// A catalog phrase inside a longer spoken sentence: its first letter lowered ("Nearby, ..." to "nearby, ..."),
    /// unless the first word is all capitals ("ID", "PDF"). Never applied to what people wrote.
    pub fn spoken_fragment(&self, phrase: &str) -> String {
        let mut chars = phrase.chars();
        let (Some(first), Some(second)) = (chars.next(), chars.next()) else { return phrase.to_owned() };
        if !self.audience.locale.to_lowercase().starts_with("en") || !first.is_uppercase() || second.is_uppercase() {
            return phrase.to_owned();
        }
        first.to_lowercase().chain(phrase[first.len_utf8()..].chars()).collect()
    }

    /// What a sentence calls someone: the first word of their name, or the whole Friends ID in its display form.
    pub fn first_name(&self, name: Option<&str>, friends_id: Option<&str>) -> String {
        let trimmed = trim(name.unwrap_or(""));
        if !trimmed.is_empty() {
            return trimmed.split(is_space).next().unwrap_or(trimmed).to_owned();
        }
        match friends_id.filter(|id| !id.is_empty()) {
            Some(id) => self.display_id(Some(id)),
            None => self.text("person.unnamed"),
        }
    }

    /// A Friends ID as text shows it: its words joined by U+2011, a hyphen that never breaks a line.
    pub fn display_id(&self, friends_id: Option<&str>) -> String {
        friends_id.unwrap_or("").replace('-', "\u{2011}")
    }

    /// "A", "A and B", "A, B and C".
    pub fn joined_list(&self, items: &[String]) -> String {
        match items {
            [] => String::new(),
            [one] => one.clone(),
            [head @ .., last] => {
                let head = head.join(&self.text("list.separator"));
                self.text_with("list.join", &[("head", &head), ("last", last)])
            }
        }
    }

    /// "PDF", "Markdown"; an unknown extension in capitals; "File" without one.
    pub fn kind_label(&self, file_name: &str, extension: Option<&str>) -> String {
        let extension =
            extension.filter(|e| !e.is_empty()).map(str::to_owned).unwrap_or_else(|| path_extension(file_name));
        let extension = extension.to_lowercase();
        if extension.is_empty() {
            return self.text("kind.file");
        }
        let key = format!("kind.{extension}");
        if self.has(&key) {
            return self.text(&key);
        }
        extension.to_uppercase()
    }

    /// "418 270".
    pub fn grouped_comparison_code(&self, digits: &str) -> String {
        let chars: Vec<char> = digits.chars().collect();
        if chars.len() != 6 {
            return digits.to_owned();
        }
        format!("{} {}", chars[..3].iter().collect::<String>(), chars[3..].iter().collect::<String>())
    }

    /// "Comparison code 4 1 8, 2 7 0".
    pub fn spoken_comparison_code(&self, digits: &str) -> String {
        let chars: Vec<String> = digits.chars().map(String::from).collect();
        let groups: Vec<String> = chars.chunks(3).map(|g| g.join(" ")).collect();
        self.text_with("code.spoken", &[("code", &groups.join(", "))])
    }

    /// "", "2", "99+".
    pub fn badge_label(&self, count: i64) -> String {
        if count <= 0 {
            return String::new();
        }
        if count > 99 {
            return self.text("badge.many");
        }
        count.to_string()
    }

    /// "Nearby, on your network", "Online, direct", "Not nearby right now"...
    pub fn route_label(&self, kind: RouteKind, method: RouteMethod) -> String {
        match kind {
            RouteKind::Local => self.text(match method {
                RouteMethod::Lan => "route.lan",
                RouteMethod::PeerToPeerWifi => "route.p2p_wifi",
                RouteMethod::Bluetooth => "route.bluetooth",
                _ => "route.local",
            }),
            RouteKind::Online => self.text(match method {
                RouteMethod::Relay => "route.relay",
                RouteMethod::Internet => "route.internet",
                _ => "route.online",
            }),
            RouteKind::Offline => self.text("route.offline"),
            RouteKind::None => String::new(),
        }
    }
}

/// `pathExtension`: what follows the last "." of the last path component, unless that dot starts it.
pub fn path_extension(path: &str) -> String {
    let name = path.rsplit('/').next().unwrap_or(path);
    match name.rfind('.') {
        Some(dot) if dot > 0 && dot + 1 < name.len() => name[dot + 1..].to_owned(),
        _ => String::new(),
    }
}

/// `lastPathComponent`.
pub fn last_path_component(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        return if path.is_empty() { String::new() } else { "/".into() };
    }
    trimmed.rsplit('/').next().unwrap_or(trimmed).to_owned()
}

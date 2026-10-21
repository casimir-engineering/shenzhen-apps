//! Joining a profile from a new computer (`SZFriendsSnapshotBuilder+Join.m`, PROTOCOL.md § Joining): the rows a request
//! makes at the top of the list on the person's other computers, and the `join` view on the new computer. Two readers,
//! two sets of words: on a computer that has the profile, whether this is them and what Approve does; on the new one,
//! what to type and what happens next.

use serde_json::{json, Map, Value};

use super::SnapshotBuilder;

/// One request as a computer of the person holds it.
#[derive(Clone, Debug, Default)]
pub struct JoinRequestFacts {
    /// Opaque, sent back in approve_join and deny_join.
    pub join_id: String,
    /// "Mei's MacBook Air", as the new computer calls itself.
    pub device_name: String,
    /// "macOS 26.1".
    pub system: String,
    pub received_at: f64,
    pub approved: bool,
    /// 8 digits, while approved.
    pub code: Option<String>,
    pub code_expires_at: Option<f64>,
}

/// Where joining stands on the new computer.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum JoiningState {
    /// Not joining; offered only while this computer has no friends yet.
    #[default]
    Idle,
    /// The request went out: approve on another computer, then type its code.
    Waiting,
    Checking,
    WrongCode,
    NotReached,
    Denied,
    Expired,
    TooManyAttempts,
    Joined,
    /// This computer already has friends or a profile shared with others.
    Unavailable,
}

impl JoiningState {
    pub const ALL: [Self; 10] = [
        Self::Idle,
        Self::Waiting,
        Self::Checking,
        Self::WrongCode,
        Self::NotReached,
        Self::Denied,
        Self::Expired,
        Self::TooManyAttempts,
        Self::Joined,
        Self::Unavailable,
    ];

    fn name(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Waiting => "waiting",
            Self::Checking => "checking",
            Self::WrongCode => "wrong_code",
            Self::NotReached => "not_reached",
            Self::Denied => "denied",
            Self::Expired => "expired",
            Self::TooManyAttempts => "too_many_attempts",
            Self::Joined => "joined",
            Self::Unavailable => "unavailable",
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct JoiningFacts {
    pub state: JoiningState,
    /// The ID typed, from Waiting on.
    pub friends_id: Option<String>,
}

/// "4831 2207": two groups of four, as people read a code aloud.
fn grouped_join_code(code: &str) -> String {
    let chars: Vec<char> = code.chars().collect();
    if chars.len() != 8 {
        return code.to_owned();
    }
    format!("{} {}", chars[..4].iter().collect::<String>(), chars[4..].iter().collect::<String>())
}

/// "4 8 3 1, 2 2 0 7": digit by digit, so a screen reader never says "forty-eight million".
fn spoken_join_code(code: &str) -> String {
    let digits: Vec<String> = code.chars().map(String::from).collect();
    digits.chunks(4).map(|group| group.join(" ")).collect::<Vec<_>>().join(", ")
}

impl SnapshotBuilder {
    fn join_row(&self, facts: &JoinRequestFacts, now: f64) -> Value {
        let s = &self.strings;
        let names = [("device", facts.device_name.as_str()), ("system", facts.system.as_str())];
        let mut row = Map::new();
        row.insert("join_id".into(), json!(facts.join_id));
        row.insert("code".into(), Value::Null);
        row.insert("code_accessibility_label".into(), Value::Null);
        row.insert("code_note".into(), Value::Null);
        let live_code = facts.code.as_deref().filter(|c| !c.is_empty());
        let expires = facts.code_expires_at.filter(|at| *at > now);
        let (Some(code), Some(expires), true) = (live_code, expires, facts.approved) else {
            let mut approve = self.action("approve_join", s.text("join.row.approve"), "primary");
            approve.insert("join_id".into(), json!(facts.join_id));
            let mut deny = self.action("deny_join", s.text("join.row.deny"), "secondary");
            deny.insert("join_id".into(), json!(facts.join_id));
            // A stray click would turn the person's own new computer away, so Deny asks for a second one.
            deny.insert(
                "arm".into(),
                json!({
                    "label": s.text("join.row.deny.arm"),
                    "accessibility_label": s.text_with("join.row.deny.arm.accessibility", &names),
                    "seconds": 4,
                }),
            );
            row.insert("state".into(), json!("waiting"));
            row.insert("title".into(), json!(s.text_with("join.row.title", &names)));
            row.insert("subtitle".into(), json!(s.text_with("join.row.subtitle", &names)));
            row.insert("actions".into(), json!([approve, deny]));
            row.insert("accessibility_label".into(), json!(s.text_with("join.row.accessibility", &names)));
            return Value::Object(row);
        };
        let time = s.clock_label(expires);
        let spoken = spoken_join_code(code);
        let values = [names[0], names[1], ("time", time.as_str()), ("code", spoken.as_str())];
        let mut cancel = self.action("deny_join", s.text("join.row.approved.cancel"), "secondary");
        cancel.insert("join_id".into(), json!(facts.join_id));
        row.insert("state".into(), json!("approved"));
        row.insert("title".into(), json!(s.text_with("join.row.approved.title", &values)));
        row.insert("subtitle".into(), json!(s.text_with("join.row.approved.subtitle", &values)));
        row.insert("code".into(), json!(grouped_join_code(code)));
        row.insert("code_accessibility_label".into(), json!(spoken));
        row.insert("code_note".into(), json!(s.text_with("join.row.approved.note", &values)));
        row.insert("actions".into(), json!([cancel]));
        row.insert("accessibility_label".into(), json!(s.text_with("join.row.approved.accessibility", &values)));
        Value::Object(row)
    }

    /// list.join_requests: oldest first, as given.
    pub fn join_request_rows(&self, requests: &[JoinRequestFacts], now: f64) -> Value {
        Value::Array(requests.iter().map(|request| self.join_row(request, now)).collect())
    }

    /// The `join` view on the new computer.
    pub fn join(&self, facts: &JoiningFacts) -> Value {
        let s = &self.strings;
        let state = facts.state;
        let id = s.display_id(facts.friends_id.as_deref());
        let mut data = Map::new();
        data.insert("state".into(), json!(state.name()));
        data.insert("title".into(), json!(s.text("join.title")));
        data.insert("message".into(), Value::Null);
        data.insert("friends_id".into(), json!(facts.friends_id));
        data.insert("id_field".into(), Value::Null);
        data.insert("code_field".into(), Value::Null);
        data.insert("error".into(), Value::Null);
        data.insert("actions".into(), json!([]));
        let cancel = self.action("cancel_join", s.text("join.cancel"), "secondary");
        let mut again = self.action("join_profile", s.text("join.start_again"), "primary");
        again.insert("friends_id".into(), json!(facts.friends_id.as_deref().unwrap_or("")));
        let code_field = json!({
            "length": 8,
            "placeholder": s.text("join.code.placeholder"),
            "button": s.text("join.code.button"),
            "enabled": state != JoiningState::Checking,
        });
        match state {
            JoiningState::Idle => {
                data.insert("message".into(), json!(s.text(&self.device_key("join.idle.message"))));
                let field =
                    json!({"placeholder": s.text("join.idle.placeholder"), "button": s.text("join.idle.button")});
                data.insert("id_field".into(), field);
            }
            JoiningState::Waiting | JoiningState::Checking | JoiningState::WrongCode | JoiningState::NotReached => {
                data.insert("title".into(), json!(s.text(&self.device_key("join.waiting.title"))));
                let message = if state == JoiningState::Checking {
                    s.text("join.checking.message")
                } else {
                    s.text_with("join.waiting.message", &[("id", &id)])
                };
                data.insert("message".into(), json!(message));
                data.insert("code_field".into(), code_field);
                if state == JoiningState::WrongCode {
                    data.insert("error".into(), json!(s.text("join.wrong_code")));
                }
                if state == JoiningState::NotReached {
                    data.insert("error".into(), json!(s.text("join.not_reached")));
                }
                data.insert("actions".into(), json!([cancel]));
            }
            JoiningState::Denied | JoiningState::Expired | JoiningState::TooManyAttempts => {
                let key = match state {
                    JoiningState::Denied => "join.denied",
                    JoiningState::Expired => "join.expired",
                    _ => "join.too_many",
                };
                data.insert("title".into(), json!(s.text(&self.device_key(&format!("{key}.title")))));
                data.insert("message".into(), json!(s.text(&format!("{key}.message"))));
                let has_id = facts.friends_id.as_deref().is_some_and(|id| !id.is_empty());
                data.insert("actions".into(), if has_id { json!([again, cancel]) } else { json!([cancel]) });
            }
            JoiningState::Joined => {
                data.insert("title".into(), json!(s.text(&self.device_key("join.joined.title"))));
                data.insert("message".into(), json!(s.text("join.joined.message")));
            }
            JoiningState::Unavailable => {
                data.insert("message".into(), json!(s.text("join.unavailable.message")));
            }
        }
        Value::Object(data)
    }
}

//! What this device keeps about notifications, outside the store so it never syncs (ADR 0017 § Settings, per
//! device): the switches and Not Now in `<state dir>/notify-settings.json`, and the app a click opens in
//! `<state dir>/notify-target`, so clicks after a restart still go there.

use std::path::{Path, PathBuf};

use serde_json::{json, Value};

pub const SETTINGS_FILE: &str = "notify-settings.json";
pub const TARGET_FILE: &str = "notify-target";

/// The URL scheme, app and name a click opens when no app was used yet: Shenzhen 3D, the app on Windows, Linux and
/// phones.
pub const DEFAULT_SCHEME: &str = "shenzhen3d";
pub const DEFAULT_APP_ID: &str = "com.shenzhen3d.viewer";
pub const DEFAULT_APP_NAME: &str = "Shenzhen 3D";

/// This device's switches.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Prefs {
    pub enabled: bool,
    pub preview: bool,
    pub background: bool,
    /// Not Now on the ask card: it never shows again (Settings keeps Allow).
    pub ask_dismissed: bool,
}

impl Default for Prefs {
    fn default() -> Self {
        Self { enabled: true, preview: true, background: false, ask_dismissed: false }
    }
}

impl Prefs {
    pub fn load(state_dir: &Path) -> Self {
        let Some(value) = read_json(&state_dir.join(SETTINGS_FILE)) else { return Self::default() };
        let flag = |key: &str, default: bool| value.get(key).and_then(Value::as_bool).unwrap_or(default);
        let defaults = Self::default();
        Self {
            enabled: flag("enabled", defaults.enabled),
            preview: flag("preview", defaults.preview),
            background: flag("background", defaults.background),
            ask_dismissed: flag("ask_dismissed", defaults.ask_dismissed),
        }
    }

    pub fn save(&self, state_dir: &Path) {
        let value = json!({"enabled": self.enabled, "preview": self.preview, "background": self.background,
                           "ask_dismissed": self.ask_dismissed});
        write_json(&state_dir.join(SETTINGS_FILE), &value);
    }
}

/// The app the person last used Friends from: where a click goes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    pub url_scheme: String,
    pub app_id: String,
    pub app_name: String,
    /// The app's executable (Linux, Windows) when the helper could read it from the connection.
    pub app_path: Option<String>,
}

impl Default for Target {
    fn default() -> Self {
        Self {
            url_scheme: DEFAULT_SCHEME.to_owned(),
            app_id: DEFAULT_APP_ID.to_owned(),
            app_name: DEFAULT_APP_NAME.to_owned(),
            app_path: None,
        }
    }
}

impl Target {
    pub fn load(state_dir: &Path) -> Self {
        let Some(value) = read_json(&state_dir.join(TARGET_FILE)) else { return Self::default() };
        let text = |key: &str| value.get(key).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_owned);
        match (text("url_scheme"), text("app_id")) {
            (Some(url_scheme), Some(app_id)) => Self {
                url_scheme,
                app_id,
                app_name: text("app_name").unwrap_or_else(|| DEFAULT_APP_NAME.to_owned()),
                app_path: text("app_path"),
            },
            _ => Self::default(),
        }
    }

    pub fn save(&self, state_dir: &Path) {
        let value = json!({"url_scheme": self.url_scheme, "app_id": self.app_id, "app_name": self.app_name,
                           "app_path": self.app_path});
        write_json(&state_dir.join(TARGET_FILE), &value);
    }

    /// `<scheme>://friends/conversation/<id>`, or `<scheme>://friends` without a conversation (a join request).
    pub fn url(&self, conversation_id: Option<&str>) -> String {
        match conversation_id {
            Some(id) => format!("{}://friends/conversation/{id}", self.url_scheme),
            None => format!("{}://friends", self.url_scheme),
        }
    }
}

fn read_json(path: &Path) -> Option<Value> {
    let text = std::fs::read_to_string(path).ok()?;
    serde_json::from_str::<Value>(&text).ok().filter(Value::is_object)
}

/// Written beside and renamed over, so a crash never leaves half a file.
fn write_json(path: &Path, value: &Value) {
    let partial: PathBuf = path.with_extension("partial");
    if std::fs::write(&partial, value.to_string()).is_ok() && std::fs::rename(&partial, path).is_err() {
        let _ = std::fs::remove_file(&partial);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn home(label: &str) -> PathBuf {
        let mut random = [0u8; 8];
        szfriends_crypto::random_bytes(&mut random);
        let name: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let path = std::env::temp_dir().join(format!("szf-notify-prefs-{label}-{name}"));
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn switches_and_the_target_survive_a_restart() {
        let dir = home("restart");
        assert_eq!(Prefs::load(&dir), Prefs::default());
        assert_eq!(Target::load(&dir).url(Some("c_mei")), "shenzhen3d://friends/conversation/c_mei");
        let prefs = Prefs { preview: false, ask_dismissed: true, ..Prefs::default() };
        prefs.save(&dir);
        assert_eq!(Prefs::load(&dir), prefs);
        let target = Target {
            url_scheme: "shenzhenpdf".into(),
            app_id: "com.intuition.shenzhenpdf".into(),
            app_name: "ShenzhenPDF".into(),
            app_path: Some("/opt/pdf/shenzhenpdf".into()),
        };
        target.save(&dir);
        assert_eq!(Target::load(&dir), target);
        assert_eq!(Target::load(&dir).url(None), "shenzhenpdf://friends");
        std::fs::write(dir.join(TARGET_FILE), "not json").unwrap();
        assert_eq!(Target::load(&dir), Target::default(), "a damaged file falls back to Shenzhen 3D");
        let _ = std::fs::remove_dir_all(&dir);
    }
}

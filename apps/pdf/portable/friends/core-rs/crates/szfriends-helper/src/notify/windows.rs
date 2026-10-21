//! Windows toasts under the helper's own AppUserModelID ([`APP_USER_MODEL_ID`]), registered under
//! `HKCU\Software\Classes\AppUserModelId` with the display name "Shenzhen Friends" and its icon, so an unpackaged
//! helper may post and the Action Center names it. Each toast's XML (`toast.rs`) carries `activationType="protocol"`
//! with the conversation's URL, so a click opens the app with it without the helper; a conversation's toasts share a
//! group, removed together when it is read.

use std::path::Path;

use windows::core::HSTRING;
use windows::Data::Xml::Dom::XmlDocument;
use windows::UI::Notifications::{NotificationSetting, ToastNotification, ToastNotificationManager};

use super::toast::{group, tag, toast_xml};
use super::{icon_file, Notifier, Open, Permission, Request, APP_NAME, APP_USER_MODEL_ID};

/// The registry key Windows reads an unpackaged app's toast identity from.
pub fn registration_key() -> String {
    format!("Software\\Classes\\AppUserModelId\\{APP_USER_MODEL_ID}")
}

/// Registers the AppUserModelID for this user: its display name and icon (written into the state directory).
pub fn register(state_dir: &Path) -> windows::core::Result<()> {
    let key = windows_registry::CURRENT_USER.create(registration_key())?;
    key.set_string("DisplayName", APP_NAME)?;
    if let Some(icon) = icon_file(state_dir) {
        key.set_string("IconUri", icon.to_string_lossy().as_ref())?;
    }
    Ok(())
}

#[derive(Debug)]
pub struct ToastNotifier {
    registered: bool,
}

impl ToastNotifier {
    pub fn new(state_dir: &Path) -> Self {
        let registered = match register(state_dir) {
            Ok(()) => true,
            Err(error) => {
                crate::log!("could not register for notifications: {error}");
                false
            }
        };
        Self { registered }
    }

    fn show(request: &Request) -> windows::core::Result<()> {
        let document = XmlDocument::new()?;
        document.LoadXml(&HSTRING::from(toast_xml(request)))?;
        let toast = ToastNotification::CreateToastNotification(&document)?;
        toast.SetTag(&HSTRING::from(tag(&request.key)))?;
        toast.SetGroup(&HSTRING::from(group(&request.thread)))?;
        ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(APP_USER_MODEL_ID))?.Show(&toast)
    }

    fn remove(thread: &str) -> windows::core::Result<()> {
        ToastNotificationManager::History()?
            .RemoveGroupWithId(&HSTRING::from(group(thread)), &HSTRING::from(APP_USER_MODEL_ID))
    }

    fn setting() -> windows::core::Result<NotificationSetting> {
        ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(APP_USER_MODEL_ID))?.Setting()
    }
}

impl Notifier for ToastNotifier {
    fn post(&self, request: &Request) {
        if let Err(error) = Self::show(request) {
            crate::log!("a notification was not shown: {error}");
        }
    }

    fn withdraw(&self, thread: &str) {
        let _ = Self::remove(thread);
    }

    /// Windows asks nothing; the person may still have turned Friends' notifications off in Settings.
    fn permission(&self) -> Permission {
        match Self::setting() {
            Ok(NotificationSetting::Enabled) => Permission::NotNeeded,
            Ok(_) => Permission::Denied,
            Err(_) if self.registered => Permission::NotNeeded,
            Err(_) => Permission::Unavailable,
        }
    }

    fn ask(&self) {}

    /// Windows opens the toast's URL itself (`activationType="protocol"`).
    fn open(&self, _open: &Open) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notify::{Open, Request};

    fn shown() -> u32 {
        ToastNotificationManager::History()
            .and_then(|h| h.GetHistoryWithId(&HSTRING::from(APP_USER_MODEL_ID)))
            .and_then(|list| list.Size())
            .unwrap_or(0)
    }

    /// A real toast in the signed-in user's Action Center: only where SZFRIENDS_TEST_TOASTS=1 (a test VM).
    #[test]
    fn a_toast_is_shown_under_the_helpers_identity_and_withdrawn_with_its_conversation() {
        if std::env::var_os("SZFRIENDS_TEST_TOASTS").is_none() {
            return;
        }
        let home = std::env::temp_dir().join(format!("szf-toast-{}", std::process::id()));
        std::fs::create_dir_all(&home).unwrap();
        let notifier = ToastNotifier::new(&home);
        assert!(notifier.registered, "the AppUserModelID registered under HKCU");
        let key = windows_registry::CURRENT_USER.open(registration_key()).unwrap();
        assert_eq!(key.get_string("DisplayName").unwrap(), "Shenzhen Friends");
        assert!(key.get_string("IconUri").unwrap().ends_with("notify-icon.png"));
        assert_eq!(notifier.permission(), Permission::NotNeeded, "notifications on for Shenzhen Friends");
        let request = Request {
            key: "message:i_toast_test".into(),
            kind: "message",
            channel: "messages",
            conversation_id: Some("c_toast_test".into()),
            thread: "c_toast_test".into(),
            title: "Mei & <Co>".into(),
            body: "Can you check the bracket?".into(),
            time: "2026-10-21T08:12:03Z".into(),
            reply: None,
            open: Open {
                url: "shenzhen3d://friends/conversation/c_toast_test".into(),
                app_id: "com.shenzhen3d.viewer".into(),
                app_path: None,
            },
        };
        notifier.post(&request);
        assert!(shown() >= 1, "the toast is in the Action Center");
        notifier.withdraw("c_toast_test");
        assert_eq!(shown(), 0, "withdrawn with its conversation");
        let _ = std::fs::remove_dir_all(&home);
    }
}

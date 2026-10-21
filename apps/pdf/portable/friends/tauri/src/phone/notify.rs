//! A phone's notifier (ADR 0017): the core inside the app decides what notifies and this hands each request to the
//! plugin's Kotlin (`android/…/notify/`) or Swift (`ios/Sources/Notifications.swift`) half, which posts it. What the
//! person does with a notification comes back on a channel: a tap (`open`, whose URL the app routes as it routes a
//! Friends link), a reply (Android's RemoteInput) and changes of the system's permission.
//!
//! Every call returns at once on the native side, so the core's thread is never held for long. On Android the
//! channels' names, the background service's words and its URL come from the catalog and the app's scheme, here.

use serde_json::{json, Value};
use szfriends_core::presentation::catalog;
use szfriends_helper::notify::{Permission, Response};
#[cfg(any(target_os = "android", target_os = "ios"))]
pub use native::PhoneNotifier;

/// What the platform reports: a response for the core, or the system's permission changing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    Response(Response),
    Permission(Permission),
}

fn permission_of(text: &str) -> Permission {
    match text {
        "granted" => Permission::Granted,
        "denied" => Permission::Denied,
        _ => Permission::NotAsked,
    }
}

/// An event the native side sent, as the core hears it.
pub fn parse_event(value: &Value) -> Option<Event> {
    let key = || value["key"].as_str().map(str::to_owned);
    match value["kind"].as_str()? {
        "open" => Some(Event::Response(Response::Open { key: key()? })),
        "reply" => {
            let text = value["text"].as_str()?.to_owned();
            Some(Event::Response(Response::Reply { key: key()?, text }))
        }
        "permission" => Some(Event::Permission(permission_of(value["state"].as_str()?))),
        _ => None,
    }
}

fn text(key: &str) -> &'static str {
    catalog::english().get(key).copied().unwrap_or_default()
}

/// The Android channels' names, by the ids the Kotlin side gives them.
pub fn channel_names() -> Value {
    json!({
        "friends.messages": text("notify.channel.messages"),
        "friends.files": text("notify.channel.files"),
        "friends.requests": text("notify.channel.requests"),
        "friends.background": text("notify.channel.background"),
    })
}

/// The background service's notification: its title, its body with the app's name, and its tap.
pub fn background_payload(on: bool, app_name: &str, settings_url: &str) -> Value {
    json!({
        "on": on,
        "title": text("notify.background.title"),
        "body": text("notify.background.body").replace("{app}", app_name),
        "url": settings_url,
    })
}

#[cfg(any(target_os = "android", target_os = "ios"))]
mod native {
    use std::sync::{Arc, Mutex};

    use serde_json::{json, Value};
    use szfriends_helper::notify::{Notifier, Open, Permission, Request};
    use tauri::ipc::{Channel, InvokeResponseBody};
    use tauri::plugin::PluginHandle;
    use tauri::Runtime;

    use super::{background_payload, channel_names, parse_event, permission_of, Event};

    /// Where events go once the core listens; until then they wait (a tap that launched the app).
    type Listener = Arc<dyn Fn(Event) + Send + Sync>;

    #[derive(Default)]
    struct Shared {
        permission: Option<Permission>,
        listener: Option<Listener>,
        waiting: Vec<Event>,
    }

    pub struct PhoneNotifier<R: Runtime> {
        handle: PluginHandle<R>,
        /// `<scheme>://friends`: the background notification's tap opens Friends (the hosts route no settings page).
        settings_url: String,
        app_name: String,
        shared: Arc<Mutex<Shared>>,
    }

    impl<R: Runtime> std::fmt::Debug for PhoneNotifier<R> {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.debug_struct("PhoneNotifier").field("permission", &self.permission()).finish()
        }
    }

    impl<R: Runtime> PhoneNotifier<R> {
        /// Hands the native side its channel and the channels' names, and reads the permission.
        pub fn start(handle: PluginHandle<R>, scheme: &str, app_name: &str) -> Arc<Self> {
            let shared: Arc<Mutex<Shared>> = Arc::default();
            let events = shared.clone();
            let channel: Channel = Channel::new(move |body| {
                let InvokeResponseBody::Json(text) = body else { return Ok(()) };
                let Some(event) = serde_json::from_str::<Value>(&text).ok().as_ref().and_then(parse_event) else {
                    return Ok(());
                };
                let listener = {
                    let mut shared = events.lock().unwrap_or_else(|e| e.into_inner());
                    if let Event::Permission(permission) = &event {
                        shared.permission = Some(*permission);
                    }
                    match shared.listener.clone() {
                        Some(listener) => listener,
                        None => {
                            shared.waiting.push(event);
                            return Ok(());
                        }
                    }
                };
                listener(event);
                Ok(())
            });
            let answer = handle.run_mobile_plugin::<Value>("notifySetup", json!({"channel": channel, "names": channel_names()}));
            if let Some(state) = answer.as_ref().ok().and_then(|a| a["permission"].as_str()) {
                shared.lock().unwrap_or_else(|e| e.into_inner()).permission = Some(permission_of(state));
            }
            Arc::new(Self {
                handle,
                settings_url: format!("{scheme}://friends"),
                app_name: app_name.to_owned(),
                shared,
            })
        }

        /// Where taps, replies and permission changes go from now on, those that waited first.
        pub fn listen(&self, listener: impl Fn(Event) + Send + Sync + 'static) {
            let listener: Listener = Arc::new(listener);
            let waiting = {
                let mut shared = self.shared.lock().unwrap_or_else(|e| e.into_inner());
                shared.listener = Some(listener.clone());
                std::mem::take(&mut shared.waiting)
            };
            for event in waiting {
                listener(event);
            }
        }

        /// "Stay reachable in the background" (Android): the foreground service runs while it is on, and again after a
        /// restart. Whether Android started it (it refuses while the app is in the background; it then starts with the
        /// app in front).
        pub fn set_background(&self, on: bool) -> bool {
            let payload = background_payload(on, &self.app_name, &self.settings_url);
            self.call("notifyBackground", payload)["done"].as_bool().unwrap_or(false)
        }

        fn call(&self, command: &str, payload: Value) -> Value {
            self.handle.run_mobile_plugin::<Value>(command, payload).unwrap_or_default()
        }
    }

    impl<R: Runtime> Notifier for PhoneNotifier<R> {
        fn post(&self, request: &Request) {
            self.call("notifyPost", request.to_json());
        }

        fn withdraw(&self, thread: &str) {
            self.call("notifyWithdraw", json!({"thread": thread}));
        }

        fn permission(&self) -> Permission {
            let known = self.shared.lock().unwrap_or_else(|e| e.into_inner()).permission;
            known.unwrap_or_else(|| permission_of(self.call("notifyPermission", json!({}))["permission"].as_str().unwrap_or("")))
        }

        fn ask(&self) {
            self.call("notifyAsk", json!({}));
        }

        /// A phone's tap opens the app on the request's URL by itself.
        fn open(&self, _open: &Open) {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn events_from_the_native_side() {
        let open = parse_event(&json!({"kind": "open", "key": "message:i_1"}));
        assert_eq!(open, Some(Event::Response(Response::Open { key: "message:i_1".into() })));
        let reply = parse_event(&json!({"kind": "reply", "key": "message:i_1", "text": "On my way"}));
        assert_eq!(reply, Some(Event::Response(Response::Reply { key: "message:i_1".into(), text: "On my way".into() })));
        for (state, permission) in
            [("granted", Permission::Granted), ("denied", Permission::Denied), ("not_asked", Permission::NotAsked)]
        {
            assert_eq!(parse_event(&json!({"kind": "permission", "state": state})), Some(Event::Permission(permission)));
        }
        assert_eq!(parse_event(&json!({"kind": "reply", "key": "message:i_1"})), None);
        assert_eq!(parse_event(&json!({"kind": "open"})), None);
        assert_eq!(parse_event(&json!({"kind": "other", "key": "k"})), None);
    }

    #[test]
    fn the_catalog_names_the_channels_and_the_background_notification() {
        let names = channel_names();
        assert_eq!(names["friends.messages"], "Messages");
        assert_eq!(names["friends.files"], "Files");
        assert_eq!(names["friends.requests"], "Requests");
        assert_eq!(names["friends.background"], "Reachable in the background");
        let payload = background_payload(true, "Shenzhen 3D", "shenzhen3d://friends");
        assert_eq!(payload["title"], "Friends is reachable");
        assert_eq!(payload["body"], "Messages and files still arrive while Shenzhen 3D is closed.");
        assert_eq!(payload["url"], "shenzhen3d://friends");
    }
}

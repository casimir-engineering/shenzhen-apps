//! Updates on Android (docs/UPDATES.md § Android): the app's Kotlin UpdatePlugin
//! (gen/android/app/src/main/java/com/shenzhen3d/viewer/UpdatePlugin.kt) checks GitHub Releases, downloads and
//! verifies the APK and hands it to PackageInstaller. The page's window.shenzhenUpdates (src/core/android-updates.ts)
//! reaches it through `android_updates`; every action answers at once with the state, and later states arrive on the
//! channel the page subscribed with.

use serde_json::{Value, json};
use tauri::ipc::Channel;
use tauri::plugin::{Builder, PluginHandle, TauriPlugin};
use tauri::{Manager, State, Wry};

pub struct Updates(PluginHandle<Wry>);

/// Registers the Kotlin plugin; it checks on launch and daily by itself.
pub fn plugin() -> TauriPlugin<Wry> {
    Builder::<Wry>::new("szupdates")
        .setup(|app, api| {
            let handle = api.register_android_plugin("com.shenzhen3d.viewer", "UpdatePlugin")?;
            app.manage(Updates(handle));
            Ok(())
        })
        .build()
}

const ACTIONS: [&str; 5] = ["getState", "check", "download", "install", "configure"];

fn call(
    handle: PluginHandle<Wry>,
    action: String,
    payload: Value,
) -> impl FnOnce() -> Result<Value, String> {
    move || {
        handle
            .run_mobile_plugin::<Value>(&action, payload)
            .map_err(|e| e.to_string())
    }
}

#[tauri::command]
pub async fn android_updates(
    updates: State<'_, Updates>,
    action: String,
    args: Option<Value>,
) -> Result<Value, String> {
    if !ACTIONS.contains(&action.as_str()) {
        return Err(format!("unknown action {action}"));
    }
    let payload = args.filter(Value::is_object).unwrap_or_else(|| json!({}));
    tauri::async_runtime::spawn_blocking(call(updates.0.clone(), action, payload))
        .await
        .map_err(|e| e.to_string())?
}

/// The page's channel, on which every later state arrives.
#[tauri::command]
pub async fn android_updates_subscribe(
    updates: State<'_, Updates>,
    channel: Channel<Value>,
) -> Result<Value, String> {
    let payload = json!({ "channel": channel });
    tauri::async_runtime::spawn_blocking(call(updates.0.clone(), "subscribe".into(), payload))
        .await
        .map_err(|e| e.to_string())?
}

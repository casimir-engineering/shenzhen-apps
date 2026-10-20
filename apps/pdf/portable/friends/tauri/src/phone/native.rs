//! The plugin's Kotlin (`android/`) and Swift (`ios/`) side, called from Rust: where the app's private files are,
//! the key store, the share sheet and links. The same native class answers Nearby's calls (`crate::nearby`), which
//! ask for their permissions when the core powers Bluetooth up (on `activate`). Each call blocks its thread until the
//! platform answers, so none is made on the main thread.

use std::path::PathBuf;
use std::sync::Arc;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::json;
use tauri::plugin::PluginHandle;
use tauri::Runtime;
#[cfg(target_os = "ios")]
use zeroize::Zeroizing;

use super::keys::{hex, unhex};
#[cfg(target_os = "android")]
use super::keys::{Sealer, Unsealed};

#[cfg(target_os = "ios")]
tauri::ios_plugin_binding!(init_plugin_szfriends);

/// The Kotlin class's package and name.
#[cfg(target_os = "android")]
const ANDROID_PACKAGE: &str = "com.shenzhen.friends";

/// The platform half of the plugin, registered when the app starts (it only answers calls; it starts nothing).
pub struct Native<R: Runtime>(PluginHandle<R>);

impl<R: Runtime> Clone for Native<R> {
    fn clone(&self) -> Self {
        Self(self.0.clone())
    }
}

impl<R: Runtime> std::fmt::Debug for Native<R> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Native")
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Dirs {
    base: String,
    /// Android's SDK version; none on iOS.
    #[serde(default)]
    sdk: Option<u32>,
    /// The device's name as its system shows it ("Pixel 9", "iPhone"): what the person's other computers call it.
    #[serde(default)]
    name: Option<String>,
}

/// A MediaStore item's size now (`downloadSize`), and a readable copy of it (`downloadCopy`).
#[derive(Deserialize)]
#[cfg_attr(target_os = "ios", allow(dead_code))]
struct MediaItem {
    size: Option<u64>,
    path: Option<String>,
}

/// Where `publishDownload` put a received file: a path or a content URI, and the name it got.
#[derive(Deserialize)]
#[cfg_attr(target_os = "ios", allow(dead_code))]
struct Published {
    location: String,
    name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Secret {
    secret: Option<String>,
    #[serde(default)]
    #[cfg_attr(target_os = "ios", allow(dead_code))]
    key_gone: bool,
}

#[derive(Deserialize)]
#[cfg_attr(target_os = "ios", allow(dead_code))]
struct Sealed {
    sealed: String,
}

#[derive(Deserialize)]
struct Done {
    #[serde(default)]
    done: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Item<'a> {
    alias: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<String>,
}

impl<R: Runtime> Native<R> {
    pub fn register<C: DeserializeOwned>(api: &tauri::plugin::PluginApi<R, C>) -> Result<Self, String> {
        #[cfg(target_os = "android")]
        let handle = api.register_android_plugin(ANDROID_PACKAGE, "FriendsPlugin");
        #[cfg(target_os = "ios")]
        let handle = api.register_ios_plugin(init_plugin_szfriends);
        handle.map(Self).map_err(|e| e.to_string())
    }

    /// The registered plugin, which answers Nearby's commands too (`crate::nearby::install`).
    pub fn handle(&self) -> PluginHandle<R> {
        self.0.clone()
    }

    fn call<T: DeserializeOwned>(&self, command: &str, payload: impl Serialize) -> Result<T, String> {
        self.0.run_mobile_plugin(command, payload).map_err(|e| e.to_string())
    }

    /// The private directory Friends keeps its files in (Android's no-backup directory, iOS's Application Support),
    /// and Android's SDK version.
    pub fn dirs(&self) -> Option<(PathBuf, Option<u32>)> {
        let dirs: Dirs = self.call("dirs", json!({})).ok()?;
        if let Some(name) = dirs.name.as_deref() {
            szfriends_helper::service::set_local_device_name(name);
        }
        Some((PathBuf::from(dirs.base), dirs.sdk)).filter(|(p, _)| p.is_absolute())
    }

    /// Keeps `path` out of backups (iOS); checked at every start. Android's no-backup directory needs nothing.
    pub fn exclude_from_backup(&self, path: &std::path::Path) -> bool {
        let answer: Result<Done, _> = self.call("excludeFromBackup", json!({"path": path.to_string_lossy()}));
        answer.is_ok_and(|d| d.done)
    }

    /// The system's share sheet for a received file (Save to Files is one of its choices on iOS; Android offers
    /// saving and sharing).
    pub fn share(&self, path: &str) -> bool {
        let answer: Result<Done, _> = self.call("share", json!({"path": path}));
        answer.is_ok_and(|d| d.done)
    }

    pub fn open_url(&self, url: &str) -> bool {
        let answer: Result<Done, _> = self.call("openUrl", json!({"url": url}));
        answer.is_ok_and(|d| d.done)
    }

    #[cfg(target_os = "ios")]
    pub fn keychain_read(&self, account: &str) -> Result<Option<Zeroizing<Vec<u8>>>, String> {
        let answer: Secret = self.call("keychainRead", Item { alias: account, data: None })?;
        match answer.secret {
            Some(text) => unhex(&text).map(Some).ok_or_else(|| "not hex".into()),
            None => Ok(None),
        }
    }

    #[cfg(target_os = "ios")]
    pub fn keychain_add(&self, account: &str, secret: &[u8]) -> Result<(), String> {
        let done: Done = self.call("keychainAdd", Item { alias: account, data: Some(hex(secret)) })?;
        done.done.then_some(()).ok_or_else(|| "not added".into())
    }

    #[cfg(target_os = "ios")]
    pub fn keychain_delete(&self, account: &str) -> Result<(), String> {
        let done: Done = self.call("keychainDelete", Item { alias: account, data: None })?;
        done.done.then_some(()).ok_or_else(|| "not deleted".into())
    }
}

/// Android's public Downloads, through the Kotlin side's MediaStore (`publishDownload`).
#[cfg(target_os = "android")]
pub struct MediaStoreDownloads<R: Runtime>(pub Native<R>);

#[cfg(target_os = "android")]
impl<R: Runtime> szfriends_core::store::ExternalPublisher for MediaStoreDownloads<R> {
    fn publish(&self, staged: &std::path::Path, name: &str) -> std::io::Result<(String, String)> {
        let answer: Published = self
            .0
            .call("publishDownload", json!({"path": staged.to_string_lossy(), "name": name}))
            .map_err(std::io::Error::other)?;
        Ok((answer.location, answer.name))
    }

    fn size(&self, location: &str) -> Option<u64> {
        let answer: MediaItem = self.0.call("downloadSize", json!({"location": location})).ok()?;
        answer.size
    }

    fn copy_out(&self, location: &str) -> Option<std::path::PathBuf> {
        let answer: MediaItem = self.0.call("downloadCopy", json!({"location": location})).ok()?;
        answer.path.map(std::path::PathBuf::from)
    }
}

#[cfg(target_os = "android")]
impl<R: Runtime> Sealer for Native<R> {
    fn seal(&self, alias: &str, secret: &[u8]) -> Result<Vec<u8>, String> {
        let sealed: Sealed = self.call("seal", Item { alias, data: Some(hex(secret)) })?;
        unhex(&sealed.sealed).map(|v| v.to_vec()).ok_or_else(|| "not hex".into())
    }

    fn unseal(&self, alias: &str, sealed: &[u8]) -> Result<Unsealed, String> {
        let answer: Secret = self.call("unseal", Item { alias, data: Some(hex(sealed)) })?;
        if answer.key_gone {
            return Ok(Unsealed::KeyGone);
        }
        let text = answer.secret.ok_or("no secret")?;
        unhex(&text).map(Unsealed::Secret).ok_or_else(|| "not hex".into())
    }

    fn forget(&self, alias: &str) -> Result<(), String> {
        let done: Done = self.call("forget", Item { alias, data: None })?;
        done.done.then_some(()).ok_or_else(|| "not forgotten".into())
    }
}

#[cfg(target_os = "ios")]
impl<R: Runtime> super::keys::Keychain for Native<R> {
    fn read(&self, account: &str) -> Result<Option<Zeroizing<Vec<u8>>>, String> {
        self.keychain_read(account)
    }

    fn add(&self, account: &str, secret: &[u8]) -> Result<(), String> {
        self.keychain_add(account, secret)
    }

    fn delete(&self, account: &str) -> Result<(), String> {
        self.keychain_delete(account)
    }
}

/// The person's own key store on this phone.
pub fn key_store<R: Runtime>(native: &Native<R>, base: &std::path::Path) -> super::Keys {
    let native = Arc::new(native.clone());
    #[cfg(target_os = "android")]
    {
        let directory = base.join("FriendsKeys");
        Arc::new(move || Box::new(super::keys::SealedFileKeyStore::new(directory.clone(), native.clone())))
    }
    #[cfg(target_os = "ios")]
    {
        let _ = base;
        Arc::new(move || Box::new(super::keys::KeychainKeyStore::new(native.clone())))
    }
}

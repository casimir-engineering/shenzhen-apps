//! Updates on Windows, Linux and iOS (docs/UPDATES.md § Windows and Linux, § iOS). The page's
//! window.shenzhenUpdates (src/core/native-updates.ts) calls `app_updates`; every action answers at once with the
//! state, and later states arrive on the channel the page subscribed with, as on Android.
//!
//! - Windows (NSIS or MSI) and Linux AppImage: the newest release carrying a `latest.json` with an entry for this
//!   install, downloaded and checked twice (its minisign signature, by the key whose public half tauri.conf.json
//!   carries, and its line in the release's `SHA256SUMS.txt`), then installed in place by Tauri's updater.
//! - Linux deb and rpm: a package manager installs those, so the app only says a newer version exists and opens its
//!   package's download.
//! - iPhone and iPad: the registered-devices app of the newest release with an install manifest, opened through
//!   iOS's own installer (an itms-services link); only devices the developer account registered can install it.
//!
//! Checks run a few seconds after launch and then daily while the app runs, when "Check daily" is on and the
//! connection is not metered (Windows and NetworkManager say when it is); "Check for updates" checks at once.

use crate::release_feed::{self, Release, Version};
use serde::Serialize;
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::ipc::Channel;
use tauri::{AppHandle, Manager, Runtime, State};

const OWNER: &str = "casimir-engineering";
const REPOSITORY: &str = "shenzhen-3D";
const API: &str = "https://api.github.com";
const DAY_MS: u64 = 24 * 60 * 60 * 1000;

/// What this install updates with.
#[derive(Clone, Debug, PartialEq)]
enum Kind {
    /// An installer Tauri's updater runs in place: the `latest.json` key (`windows-x86_64-nsis`…).
    #[cfg_attr(target_os = "ios", allow(dead_code))]
    InPlace(String),
    /// A deb or rpm: the package's extension; the app opens its download.
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    Package(&'static str),
    /// Anything else on a desktop (a bare executable): the release page.
    #[cfg_attr(target_os = "ios", allow(dead_code))]
    Page,
    /// iPhone and iPad: iOS installs the registered-devices app from the release's manifest.
    #[cfg_attr(not(target_os = "ios"), allow(dead_code))]
    Ios,
}

fn kind() -> Kind {
    #[cfg(target_os = "ios")]
    return Kind::Ios;
    #[cfg(not(target_os = "ios"))]
    {
        use tauri::utils::config::BundleType;
        let os = if cfg!(windows) { "windows" } else { "linux" };
        let arch = std::env::consts::ARCH;
        match tauri::utils::platform::bundle_type() {
            Some(BundleType::Nsis) => Kind::InPlace(format!("{os}-{arch}-nsis")),
            Some(BundleType::Msi) => Kind::InPlace(format!("{os}-{arch}-msi")),
            Some(BundleType::AppImage) => Kind::InPlace(format!("{os}-{arch}-appimage")),
            Some(BundleType::Deb) => Kind::Package("deb"),
            Some(BundleType::Rpm) => Kind::Package("rpm"),
            _ => Kind::Page,
        }
    }
}

/// The page's view of the updater: the shape of src/core/updates.ts's UpdateState.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateState {
    supported: bool,
    version: String,
    status: &'static str,
    automatic: bool,
    repository: &'static str,
    access: &'static str,
    prereleases: bool,
    connected: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    available_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    progress: Option<f64>,
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    last_checked: Option<u64>,
    platform: &'static str,
    /// The newer version is a download to install by hand (deb, rpm), not an update the app installs.
    download_only: bool,
}

/// What the last check found, ready for Update.
#[derive(Clone)]
enum Found {
    #[cfg(not(target_os = "ios"))]
    InPlace {
        update: tauri_plugin_updater::Update,
        version: Version,
        sums_url: String,
    },
    /// Opened in the browser (deb, rpm, the release page) or by iOS (an itms-services link).
    Link(String),
}

struct Inner {
    state: UpdateState,
    found: Option<Found>,
    #[cfg(not(target_os = "ios"))]
    downloaded: Option<Vec<u8>>,
    channels: Vec<Channel<Value>>,
    /// A check, download or install is running.
    busy: bool,
}

pub struct Updates {
    inner: Mutex<Inner>,
    kind: Kind,
    settings: Option<PathBuf>,
    api: String,
    current: Version,
}

type Shared = Arc<Updates>;

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or_default()
}

/// The releases API: GitHub, or for test builds the mock that `SHENZHEN_3D_UPDATES_API` names
/// (scripts/updates/mock-github.mjs).
fn api_base() -> String {
    #[cfg(feature = "updates-test-api")]
    if let Ok(api) = std::env::var("SHENZHEN_3D_UPDATES_API") {
        if api.starts_with("http://127.0.0.1:") {
            return api.trim_end_matches('/').to_string();
        }
    }
    API.to_string()
}

/// Test builds: a line in the run's log (`SHENZHEN_3D_UPDATES_TEST_LOG`) and on stderr.
#[cfg(feature = "updates-test-api")]
pub fn test_log(line: &str) {
    use std::io::Write;
    eprintln!("shenzhen-3d updates: {line}");
    if let Ok(path) = std::env::var("SHENZHEN_3D_UPDATES_TEST_LOG") {
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
        {
            // One write per line, so lines written at the same time do not interleave.
            let _ = file.write_all(format!("{} {line}\n", now_ms()).as_bytes());
        }
    }
}

fn platform_name() -> &'static str {
    if cfg!(target_os = "ios") {
        "ios"
    } else if cfg!(windows) {
        "windows"
    } else {
        "linux"
    }
}

/// Registers the updater: its state, the flag that tells the page to offer Updates, and the daily checks.
pub fn plugin<R: Runtime>() -> tauri::plugin::TauriPlugin<R> {
    // Read by src/core/native-updates.ts before the page's first render, so the footer offers Updates.
    #[allow(unused_mut)]
    let mut script = format!(
        "Object.defineProperty(window, '__SHENZHEN_NATIVE_UPDATES__', {{ value: '{}' }});",
        platform_name()
    );
    // Test builds: the page driver of the update tests (tests/updates/drive-update.js), which uses the Updates
    // dialog as a person would.
    #[cfg(feature = "updates-test-api")]
    if let Ok(path) = std::env::var("SHENZHEN_3D_UPDATES_TEST_PAGE") {
        match std::fs::read_to_string(&path) {
            Ok(driver) => script.push_str(&driver),
            Err(error) => test_log(&format!("no page driver at {path}: {error}")),
        }
    }
    tauri::plugin::Builder::<R>::new("szappupdates")
        .js_init_script(script)
        .setup(|app, _api| {
            let settings = app
                .path()
                .app_config_dir()
                .ok()
                .map(|dir| dir.join("updates.json"));
            let saved: Value = settings
                .as_ref()
                .and_then(|path| std::fs::read(path).ok())
                .and_then(|bytes| serde_json::from_slice(&bytes).ok())
                .unwrap_or(Value::Null);
            let version = app.package_info().version.to_string();
            let current = Version::parse(&version).unwrap_or(Version(0, 0, 0));
            let kind = kind();
            #[cfg(feature = "updates-test-api")]
            test_log(&format!(
                "started {version} as {kind:?}, API {}",
                api_base()
            ));
            let updates = Arc::new(Updates {
                inner: Mutex::new(Inner {
                    state: UpdateState {
                        supported: true,
                        version,
                        status: "idle",
                        automatic: saved["automatic"].as_bool().unwrap_or(true),
                        repository: OWNER,
                        access: "public",
                        prereleases: true,
                        connected: false,
                        available_version: None,
                        progress: None,
                        message: String::new(),
                        last_checked: saved["lastChecked"].as_u64(),
                        platform: platform_name(),
                        download_only: matches!(kind, Kind::Package(_) | Kind::Page),
                    },
                    found: None,
                    #[cfg(not(target_os = "ios"))]
                    downloaded: None,
                    channels: Vec::new(),
                    busy: false,
                }),
                kind,
                settings,
                api: api_base(),
                current,
            });
            app.manage(updates.clone());
            let app = app.clone();
            tauri::async_runtime::spawn(async move { daily(app, updates).await });
            Ok(())
        })
        .build()
}

/// A few seconds after launch, then whenever a day has passed since the last check, while the app runs.
async fn daily<R: Runtime>(app: AppHandle<R>, updates: Shared) {
    tokio::time::sleep(Duration::from_secs(5)).await;
    let mut first = true;
    loop {
        let (automatic, last) = {
            let inner = updates.inner.lock().unwrap();
            (inner.state.automatic, inner.state.last_checked.unwrap_or(0))
        };
        if automatic && (first || now_ms().saturating_sub(last) >= DAY_MS) && !metered() {
            if let Some(before) = begin_check(&updates) {
                run_check(&app, &updates, true, before).await;
            }
        }
        first = false;
        tokio::time::sleep(Duration::from_secs(60 * 60)).await;
    }
}

impl Updates {
    fn state(&self) -> UpdateState {
        self.inner.lock().unwrap().state.clone()
    }

    /// Changes the state and tells the page.
    fn publish(&self, change: impl FnOnce(&mut UpdateState)) -> UpdateState {
        let mut inner = self.inner.lock().unwrap();
        change(&mut inner.state);
        let state = inner.state.clone();
        let value = serde_json::to_value(&state).unwrap_or(Value::Null);
        #[cfg(feature = "updates-test-api")]
        test_log(&format!("state {value}"));
        inner
            .channels
            .retain(|channel| channel.send(value.clone()).is_ok());
        state
    }

    fn save(&self) {
        let Some(path) = &self.settings else { return };
        let state = self.state();
        let value = json!({ "automatic": state.automatic, "lastChecked": state.last_checked });
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let _ = std::fs::write(path, serde_json::to_vec_pretty(&value).unwrap_or_default());
    }

    /// Marks the updater busy; false when it already was.
    fn start(&self) -> bool {
        let mut inner = self.inner.lock().unwrap();
        !std::mem::replace(&mut inner.busy, true)
    }

    fn finish(&self) {
        self.inner.lock().unwrap().busy = false;
    }
}

fn client() -> Result<reqwest::Client, String> {
    // Tauri's updater installs the same provider before its own requests; ours may come first.
    let _ = rustls::crypto::ring::default_provider().install_default();
    reqwest::Client::builder()
        .user_agent(concat!("Shenzhen-3D/", env!("SHENZHEN_3D_VERSION")))
        .timeout(Duration::from_secs(60))
        .build()
        .map_err(|error| error.to_string())
}

async fn get(url: &str) -> Result<Vec<u8>, String> {
    let response = client()?
        .get(url)
        .header("Accept", "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .send()
        .await
        .map_err(|error| error.to_string())?;
    if !response.status().is_success() {
        return Err(format!("{url} answered {}", response.status()));
    }
    Ok(response
        .bytes()
        .await
        .map_err(|error| error.to_string())?
        .to_vec())
}

async fn releases(api: &str) -> Result<Vec<Release>, String> {
    release_feed::parse_releases(
        &get(&format!(
            "{api}/repos/{OWNER}/{REPOSITORY}/releases?per_page=30"
        ))
        .await?,
    )
}

const UP_TO_DATE: &str = "You are up to date.";
const CHECK_FAILED: &str = "Couldn't check for updates. Check your connection and try again.";

/// Starts a check unless something is running or an update is downloaded or being installed; answers the state
/// before it.
fn begin_check(updates: &Shared) -> Option<UpdateState> {
    if matches!(updates.state().status, "ready" | "installing") || !updates.start() {
        return None;
    }
    let before = updates.state();
    updates.publish(|s| {
        s.status = "checking";
        s.progress = None;
        s.message = "Checking for updates…".into();
    });
    Some(before)
}

async fn run_check<R: Runtime>(
    app: &AppHandle<R>,
    updates: &Shared,
    automatic: bool,
    before: UpdateState,
) {
    let result = find(app, updates).await;
    match result {
        Ok(Some((version, found, size))) => {
            let message = available_message(&updates.kind, version, size);
            updates.inner.lock().unwrap().found = Some(found);
            updates.publish(|s| {
                s.status = "available";
                s.available_version = Some(version.to_string());
                s.message = message;
                s.last_checked = Some(now_ms());
            });
        }
        Ok(None) => {
            updates.inner.lock().unwrap().found = None;
            updates.publish(|s| {
                s.status = "idle";
                s.available_version = None;
                s.message = UP_TO_DATE.into();
                s.last_checked = Some(now_ms());
            });
        }
        Err(error) => {
            log::warn!("update check failed: {error}");
            #[cfg(feature = "updates-test-api")]
            test_log(&format!("check failed: {error}"));
            // A daily check that fails says nothing; the next one tries again.
            updates.publish(|s| {
                if automatic {
                    s.status = before.status;
                    s.message = before.message;
                } else {
                    s.status = "error";
                    s.message = CHECK_FAILED.into();
                }
            });
        }
    }
    updates.save();
    updates.finish();
}

fn megabytes(size: u64) -> String {
    format!("{:.0} MB", (size as f64 / 1_000_000.0).max(1.0))
}

fn available_message(kind: &Kind, version: Version, size: u64) -> String {
    match kind {
        Kind::InPlace(_) if metered() => format!(
            "You're on a metered connection. The update is about {}.",
            megabytes(size)
        ),
        Kind::InPlace(_) => String::new(),
        Kind::Package(extension) => format!(
            "Download the new .{extension} package and install it the way you installed this one."
        ),
        Kind::Page => format!("Download Shenzhen 3D {version} from its release page."),
        Kind::Ios => {
            "Only iPhones and iPads registered for testing Shenzhen 3D can install it.".into()
        }
    }
}

/// The newest release this install can update to, what Update will do, and the download's size.
async fn find<R: Runtime>(
    app: &AppHandle<R>,
    updates: &Shared,
) -> Result<Option<(Version, Found, u64)>, String> {
    #[cfg(target_os = "ios")]
    let _ = app;
    let list = releases(&updates.api).await?;
    let current = updates.current;
    match &updates.kind {
        #[cfg(not(target_os = "ios"))]
        Kind::InPlace(target) => {
            // Newest first; a release without a manifest entry for this install is passed over.
            for (version, release) in release_feed::newer(&list, current) {
                let (Some(manifest), Some(sums)) = (
                    release.asset("latest.json"),
                    release.asset("SHA256SUMS.txt"),
                ) else {
                    continue;
                };
                let bytes = get(&manifest.browser_download_url).await?;
                let Ok(parsed) = release_feed::parse_manifest(&bytes) else {
                    continue;
                };
                let Some(entry) = parsed.entry(target, version) else {
                    continue;
                };
                let size = release_feed::file_name(&entry.url)
                    .and_then(|name| release.asset(&name).map(|asset| asset.size))
                    .unwrap_or(0);
                let update = installer(app, &manifest.browser_download_url, target).await?;
                let Some(update) = update else { continue };
                if Version::parse(&update.version) != Some(version) {
                    continue;
                }
                let sums_url = sums.browser_download_url.clone();
                return Ok(Some((
                    version,
                    Found::InPlace {
                        update,
                        version,
                        sums_url,
                    },
                    size,
                )));
            }
            Ok(None)
        }
        Kind::Package(extension) => Ok(release_feed::pick(&list, current, |release| {
            release_feed::linux_package(release, extension, std::env::consts::ARCH)
        })
        .map(|(version, _, asset)| {
            (
                version,
                Found::Link(asset.browser_download_url.clone()),
                asset.size,
            )
        })),
        Kind::Page => Ok(release_feed::pick(&list, current, |release| {
            release
                .asset("latest.json")
                .map(|_| release.html_url.clone())
        })
        .map(|(version, _, page)| (version, Found::Link(page), 0))),
        Kind::Ios => Ok(
            release_feed::pick(&list, current, release_feed::ios_install).map(
                |(version, _, (manifest, ipa))| {
                    let link = release_feed::itms_services_link(&manifest.browser_download_url);
                    (version, Found::Link(link), ipa.size)
                },
            ),
        ),
        #[allow(unreachable_patterns)]
        _ => Ok(None),
    }
}

/// Tauri's updater, pointed at one release's manifest.
#[cfg(not(target_os = "ios"))]
async fn installer<R: Runtime>(
    app: &AppHandle<R>,
    manifest_url: &str,
    target: &str,
) -> Result<Option<tauri_plugin_updater::Update>, String> {
    use tauri_plugin_updater::UpdaterExt;
    let url = manifest_url
        .parse()
        .map_err(|_| "bad manifest URL".to_string())?;
    app.updater_builder()
        .endpoints(vec![url])
        .map_err(|error| error.to_string())?
        .target(target)
        .timeout(Duration::from_secs(60 * 10))
        .build()
        .map_err(|error| error.to_string())?
        .check()
        .await
        .map_err(|error| error.to_string())
}

/// Update: downloads and checks the installer, or opens the download or iOS's installer. A download goes on in
/// the background; the answer is the state once it has started.
fn download<R: Runtime>(app: &AppHandle<R>, updates: &Shared) {
    let found = updates.inner.lock().unwrap().found.clone();
    match found {
        None => {}
        Some(Found::Link(link)) => {
            let opened = open(app, &link);
            updates.publish(|s| {
                s.message = match (&updates.kind, opened) {
                    (Kind::Ios, true) => {
                        "Tap Install when your iPhone or iPad asks. Shenzhen 3D closes while the new version \
                         installs."
                            .into()
                    }
                    (Kind::Ios, false) => {
                        "This iPhone or iPad couldn't start the installation. Only devices registered for testing \
                         Shenzhen 3D can install it."
                            .into()
                    }
                    (_, true) => s.message.clone(),
                    (_, false) => format!("Couldn't open the download. It is at {link}"),
                };
            });
        }
        #[cfg(not(target_os = "ios"))]
        Some(Found::InPlace {
            update,
            version,
            sums_url,
        }) => {
            if !updates.start() {
                return;
            }
            updates.publish(|s| {
                s.status = "downloading";
                s.progress = Some(0.0);
                s.message = "Downloading update…".into();
            });
            let (app, updates) = (app.clone(), updates.clone());
            tauri::async_runtime::spawn(async move {
                let result = fetch_and_verify(&app, &updates, &update, version, &sums_url).await;
                match result {
                    Ok(bytes) => {
                        updates.inner.lock().unwrap().downloaded = Some(bytes);
                        updates.publish(|s| {
                            s.status = "ready";
                            s.progress = Some(100.0);
                            s.message =
                                "Update ready. Save your projects before restarting.".into();
                        });
                    }
                    Err(Refused::Mismatch(error)) => {
                        log::warn!("update download refused: {error}");
                        #[cfg(feature = "updates-test-api")]
                        test_log(&format!("download refused: {error}"));
                        updates.publish(|s| {
                        s.status = "available";
                        s.progress = None;
                        s.message = "The download didn't match the published update, so it wasn't installed. \
                                     Try again later."
                            .into();
                    });
                    }
                    Err(Refused::Unfinished(error)) => {
                        log::warn!("update download failed: {error}");
                        #[cfg(feature = "updates-test-api")]
                        test_log(&format!("download failed: {error}"));
                        updates.publish(|s| {
                            s.status = "available";
                            s.progress = None;
                            s.message =
                                "The download didn't finish. Check your connection and try again."
                                    .into();
                        });
                    }
                }
                updates.finish();
            });
        }
    }
}

/// Why a download is not installed: it is not the published file, or it did not arrive.
#[cfg(not(target_os = "ios"))]
enum Refused {
    Mismatch(String),
    Unfinished(String),
}

#[cfg(not(target_os = "ios"))]
async fn fetch_and_verify<R: Runtime>(
    app: &AppHandle<R>,
    updates: &Shared,
    update: &tauri_plugin_updater::Update,
    version: Version,
    sums_url: &str,
) -> Result<Vec<u8>, Refused> {
    let mut received = 0usize;
    let mut last = 0.0;
    let bytes = update
        .download(
            |chunk, total| {
                received += chunk;
                if let Some(total) = total.filter(|t| *t > 0) {
                    let percent = (received as f64 * 100.0 / total as f64).min(99.0);
                    if percent - last >= 1.0 {
                        last = percent;
                        updates.publish(|s| s.progress = Some(percent.floor()));
                    }
                }
            },
            || {},
        )
        .await
        .map_err(|error| match error {
            tauri_plugin_updater::Error::Minisign(_)
            | tauri_plugin_updater::Error::SignedVersionMismatch { .. }
            | tauri_plugin_updater::Error::MissingSignedVersion => {
                Refused::Mismatch(error.to_string())
            }
            // A signature that does not even decode, or the connection: try again.
            other => Refused::Unfinished(other.to_string()),
        })?;
    // Tauri's updater checked the signature while downloading; the app checks it again, and the release's
    // checksum, before anything runs the file.
    let key = app
        .config()
        .plugins
        .0
        .get("updater")
        .and_then(|updater| updater["pubkey"].as_str())
        .unwrap_or_default()
        .to_string();
    release_feed::verify_bundle(&bytes, &update.signature, &key, version)
        .map_err(Refused::Mismatch)?;
    let name = release_feed::file_name(update.download_url.as_str())
        .ok_or_else(|| Refused::Mismatch("no file name".into()))?;
    let sums = get(sums_url).await.map_err(Refused::Unfinished)?;
    let sums = String::from_utf8(sums)
        .map_err(|_| Refused::Mismatch("SHA256SUMS.txt is not text".into()))?;
    let expected = release_feed::checksum_for(&sums, &name)
        .ok_or_else(|| Refused::Mismatch(format!("{name} is not in SHA256SUMS.txt")))?;
    let actual = release_feed::sha256_hex(&bytes);
    if actual != expected {
        return Err(Refused::Mismatch(format!(
            "{name}: SHA-256 {actual}, SHA256SUMS.txt says {expected}"
        )));
    }
    Ok(bytes)
}

/// Restart & install: Windows hands over to the installer, which closes the app and starts the new version;
/// an AppImage is replaced, then the app starts again.
#[cfg(not(target_os = "ios"))]
fn install<R: Runtime>(app: &AppHandle<R>, updates: &Shared) -> Result<(), String> {
    let (found, bytes) = {
        let mut inner = updates.inner.lock().unwrap();
        (inner.found.clone(), inner.downloaded.take())
    };
    let (Some(Found::InPlace { update, .. }), Some(bytes)) = (found, bytes) else {
        return Err("nothing downloaded".into());
    };
    updates.publish(|s| {
        s.status = "installing";
        s.message = "Installing the update and restarting…".into();
    });
    #[cfg(feature = "updates-test-api")]
    test_log(&format!(
        "installing {} bytes from {}",
        bytes.len(),
        update.download_url
    ));
    // Windows: the installer is started and this process ends here.
    update.install(&bytes).map_err(|error| error.to_string())?;
    #[cfg(feature = "updates-test-api")]
    test_log("installed; restarting");
    app.restart();
}

fn open<R: Runtime>(app: &AppHandle<R>, link: &str) -> bool {
    #[cfg(feature = "updates-test-api")]
    test_log(&format!("opening {link}"));
    #[cfg(target_os = "ios")]
    {
        return ios_open(app, link);
    }
    #[cfg(target_os = "linux")]
    {
        let _ = app;
        return std::process::Command::new("xdg-open")
            .arg(link)
            .spawn()
            .is_ok();
    }
    #[cfg(windows)]
    {
        let _ = app;
        use std::os::windows::process::CommandExt;
        return std::process::Command::new("rundll32")
            .args(["url.dll,FileProtocolHandler", link])
            .creation_flags(0x0800_0000) // CREATE_NO_WINDOW
            .spawn()
            .is_ok();
    }
    #[allow(unreachable_code)]
    {
        let _ = (app, link);
        false
    }
}

#[cfg(target_os = "ios")]
fn ios_open<R: Runtime>(app: &AppHandle<R>, link: &str) -> bool {
    let link = link.to_string();
    app.run_on_main_thread(move || {
        use objc2_foundation::{MainThreadMarker, NSDictionary, NSString, NSURL};
        use objc2_ui_kit::UIApplication;
        let Some(mtm) = MainThreadMarker::new() else {
            return;
        };
        let Some(url) = NSURL::URLWithString(&NSString::from_str(&link)) else {
            return;
        };
        let application = UIApplication::sharedApplication(mtm);
        let options = NSDictionary::new();
        let done = block2::RcBlock::new(|opened: objc2::runtime::Bool| {
            #[cfg(feature = "updates-test-api")]
            test_log(&format!("iOS opened the link: {}", opened.as_bool()));
            let _ = opened;
        });
        // SAFETY: an empty options dictionary is of the expected type.
        unsafe { application.openURL_options_completionHandler(&url, &options, Some(&done)) };
    })
    .is_ok()
}

/// Whether the system says the connection is metered. Unknown counts as not metered.
fn metered() -> bool {
    #[cfg(windows)]
    {
        use windows::Networking::Connectivity::{NetworkCostType, NetworkInformation};
        let cost = || -> windows::core::Result<bool> {
            let profile = NetworkInformation::GetInternetConnectionProfile()?;
            let cost = profile.GetConnectionCost()?;
            let kind = cost.NetworkCostType()?;
            Ok(kind == NetworkCostType::Fixed
                || kind == NetworkCostType::Variable
                || cost.OverDataLimit()?
                || cost.Roaming()?)
        };
        return cost().unwrap_or(false);
    }
    #[cfg(target_os = "linux")]
    {
        // NetworkManager's Metered: 1 yes, 3 guessed yes (2 and 4 no, 0 unknown).
        let output = std::process::Command::new("gdbus")
            .args([
                "call",
                "--system",
                "--dest",
                "org.freedesktop.NetworkManager",
                "--object-path",
                "/org/freedesktop/NetworkManager",
                "--method",
                "org.freedesktop.DBus.Properties.Get",
                "org.freedesktop.NetworkManager",
                "Metered",
            ])
            .output();
        return match output {
            Ok(out) if out.status.success() => {
                let text = String::from_utf8_lossy(&out.stdout);
                text.contains("uint32 1>") || text.contains("uint32 3>")
            }
            _ => false,
        };
    }
    #[allow(unreachable_code)]
    false
}

#[tauri::command]
pub async fn app_updates<R: Runtime>(
    app: AppHandle<R>,
    updates: State<'_, Shared>,
    action: String,
    args: Option<Value>,
) -> Result<UpdateState, String> {
    let updates: Shared = updates.inner().clone();
    match action.as_str() {
        "getState" => {}
        "check" => {
            if let Some(before) = begin_check(&updates) {
                let (app, updates) = (app.clone(), updates.clone());
                tauri::async_runtime::spawn(async move {
                    run_check(&app, &updates, false, before).await
                });
            }
        }
        "download" => download(&app, &updates),
        "install" =>
        {
            #[cfg(not(target_os = "ios"))]
            if updates.state().status == "ready" {
                if let Err(error) = install(&app, &updates) {
                    log::warn!("update install failed: {error}");
                    updates.publish(|s| {
                        s.status = "error";
                        s.message =
                            "The update couldn't be installed. Check for updates to try again."
                                .into();
                    });
                }
            }
        }
        #[cfg(feature = "updates-test-api")]
        "report" => {
            let text = args
                .as_ref()
                .and_then(|a| a["text"].as_str())
                .unwrap_or_default();
            test_log(&format!("page {text}"));
        }
        "configure" => {
            if let Some(automatic) = args.as_ref().and_then(|a| a["automatic"].as_bool()) {
                updates.publish(|s| s.automatic = automatic);
                updates.save();
            }
        }
        other => return Err(format!("unknown action {other}")),
    }
    Ok(updates.state())
}

/// The page's channel, on which every later state arrives.
#[tauri::command]
pub async fn app_updates_subscribe(
    updates: State<'_, Shared>,
    channel: Channel<Value>,
) -> Result<UpdateState, String> {
    let mut inner = updates.inner.lock().unwrap();
    inner.channels.push(channel);
    Ok(inner.state.clone())
}

//! tauri-plugin-szfriends: Shenzhen Friends in a Tauri app (ADR 0015 § 4).
//!
//! The plugin gives the app's main window `window.shenzhenFriends`, exactly the `FriendsBridge` the Electron
//! preload gives Shenzhen 3D's Mac app, so one React UI serves both shells. Behind it:
//!
//! | Where | Mode | Talks to |
//! |---|---|---|
//! | Windows, Linux | client | the Rust helper, spawned from the app's per-user copy (`szfriends-helper`) |
//! | macOS | client | the Objective-C helper the app embeds, shared with the Mac's other Friends apps |
//! | Android, iOS | embedded | the core in this process, over an in-memory channel carrying the same frames |
//!
//! `init` registers commands and a guest script and nothing else: the plugin locates nothing, reads nothing and
//! starts nothing until the page's first `join()`, which the page sends after its first paint. Grant the plugin's
//! `szfriends:default` permission to the main window only, in a capability with no remote URLs.

mod commands;
mod drops;
mod files;
mod host;
mod link;
#[cfg(target_os = "macos")]
mod mac_signing;
#[cfg(any(target_os = "android", target_os = "ios"))]
mod nearby;
mod open;
#[cfg_attr(not(any(target_os = "android", target_os = "ios")), allow(dead_code))]
mod phone;
mod router;
#[cfg(any(test, target_os = "android", target_os = "ios"))]
mod streams;
mod urls;
mod validate;

use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use tauri::plugin::{Builder, TauriPlugin};
use tauri::{AppHandle, Manager, RunEvent, Runtime, WindowEvent};

/// Where the app's embedded helper is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Helper {
    /// Where the app's bundle puts it: beside the app's executable on Windows and Linux (`szfriends-helper[.exe]`),
    /// `Contents/Helpers/Shenzhen Friends.app` on a Mac. Phones run the core in-process instead.
    Bundled,
    /// A helper binary (Windows, Linux) or `.app` bundle (Mac) for development runs, which should also give a
    /// Friends home of their own (`Config::state_dir`).
    At(PathBuf),
}

/// Opens received files in the app (Open in a conversation).
pub type OpenFiles<R> = Arc<dyn Fn(&AppHandle<R>, Vec<PathBuf>) + Send + Sync>;

pub use host::{ShareMenu, LINK_DAYS};

/// Shows, hides, enables or disables the app's File ▸ Copy Download Link (called on any thread, when it changes).
pub type ShareMenuHook<R> = Arc<dyn Fn(&AppHandle<R>, ShareMenu) + Send + Sync>;

/// What the app says about itself, and what it lets Friends do.
pub struct Config<R: Runtime> {
    /// hello's `app_id`, `app_name` (the helper names the app with it in its words) and `app_version`.
    pub app_id: String,
    pub app_name: String,
    pub app_version: String,
    /// BCP 47; "en" when unknown.
    pub locale: String,
    /// PROTOCOL.md § Capabilities the panel implements.
    pub capabilities: Vec<String>,
    /// Lowercase extensions the app opens: received files in these formats offer Open.
    pub open_formats: Vec<String>,
    /// Extensions `stage` accepts; empty accepts any plain name (dropped files are staged too on phones).
    pub staged_extensions: Vec<String>,
    /// The app's URL scheme for Friends links (`<scheme>://friends/link#…`).
    pub link_scheme: String,
    /// The windows that get the bridge; the capability granting the commands must name the same.
    pub windows: Vec<String>,
    pub helper: Helper,
    /// The animal set's directory (`manifest.json`, `svg/`); None looks where the app's bundle puts it.
    pub animals: Option<PathBuf>,
    /// Where the bridge keeps the Friends setting and staged files; None uses the app's own data and config
    /// directories. Test runs give a directory of their own.
    pub data_dir: Option<PathBuf>,
    /// A development or test run's Friends home instead of the person's own (`$SZFRIENDS_STATE_DIR` is never read
    /// by the plugin). Honoured only in debug builds and with the plugin's `test-homes` feature, so a release
    /// build always serves the person's own Friends.
    pub state_dir: Option<PathBuf>,
    /// Phones: run the core in-process. Off until the app ships Friends on phones.
    pub embedded: bool,
    pub open_files: Option<OpenFiles<R>>,
    /// The app's File ▸ Copy Download Link; its choice goes to [`copy_download_link`]. None: the page's header only.
    pub share_menu: Option<ShareMenuHook<R>>,
}

impl<R: Runtime> std::fmt::Debug for Config<R> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Config").field("app_id", &self.app_id).field("helper", &self.helper).finish()
    }
}

/// The plugin's managed state: the host, made on the first command.
pub struct Friends<R: Runtime> {
    config: std::sync::Mutex<Option<Config<R>>>,
    host: OnceLock<Arc<host::Host<R>>>,
    /// The windows the plugin serves (Config::windows), known before the host starts.
    windows: Vec<String>,
    /// Files the system reported dropped on those windows.
    drops: drops::Drops,
}

impl<R: Runtime> std::fmt::Debug for Friends<R> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Friends").field("started", &self.host.get().is_some()).finish()
    }
}

impl<R: Runtime> Friends<R> {
    fn host(&self, app: &AppHandle<R>) -> Arc<host::Host<R>> {
        self.host
            .get_or_init(|| {
                let config = self.config.lock().unwrap_or_else(|e| e.into_inner()).take().expect("configured once");
                let located = locate(app, &config);
                host::Host::new(app.clone(), config, located)
            })
            .clone()
    }

    fn started(&self) -> Option<&Arc<host::Host<R>>> {
        self.host.get()
    }

    /// A Friends link URL opened in the app (a deep link): its card opens in the focused window once Friends is
    /// ready. False when it is not one of the app's well-formed Friends links.
    pub fn open_link(&self, app: &AppHandle<R>, url: &str) -> bool {
        self.host(app).open_link(url)
    }
}

/// Files the app learned were dropped on window `label` (for instance from Tauri's own drag and drop events, when the
/// app turns them on): the page's next drop of files with the same names and sizes sends them from these paths. The
/// plugin already listens for drops on the windows it serves, so most apps never call this.
pub fn native_drop<R: Runtime>(app: &AppHandle<R>, label: &str, paths: &[PathBuf]) {
    if let Some(friends) = app.try_state::<Friends<R>>() {
        if friends.windows.iter().any(|w| w == label) {
            friends.drops.record(label, None, paths);
        }
    }
}

/// File ▸ Copy Download Link chosen in the app's menu: the focused window, when it has a model open and Friends makes
/// links, makes one that works for `days` (7, 1 or 30). False when nothing was asked of a window.
pub fn copy_download_link<R: Runtime>(app: &AppHandle<R>, days: u32) -> bool {
    app.try_state::<Friends<R>>().and_then(|f| f.started().cloned()).is_some_and(|host| host.copy_download_link(days))
}

/// The file manager's name, for "Show in Finder" and its kin (phones send received files to the share sheet
/// instead: the `files.share` capability).
pub(crate) fn reveal_in() -> &'static str {
    if cfg!(target_os = "macos") {
        "Finder"
    } else if cfg!(windows) {
        "File Explorer"
    } else {
        "Files"
    }
}

/// Where Friends' pieces are for this run.
pub(crate) struct Located {
    pub connector: Arc<dyn link::Connector>,
    pub state_dir: PathBuf,
    pub animals: Option<PathBuf>,
    /// Phones: the setting and staged files beside Friends, in the private directory kept out of backups.
    pub data_dir: Option<PathBuf>,
}

/// The animal set the app's bundle carries (Tauri resources), unless the app names one.
#[cfg(any(target_os = "linux", windows))]
fn bundled_animals<R: Runtime>(app: &AppHandle<R>, config: &Config<R>) -> Option<PathBuf> {
    config.animals.clone().or_else(|| app.path().resource_dir().ok().map(|d| d.join("friends").join("animals")))
}

/// The development or test home the app named, where this build honours one.
#[allow(dead_code)]
fn test_home<R: Runtime>(config: &Config<R>) -> Option<PathBuf> {
    let allowed = cfg!(debug_assertions) || cfg!(feature = "test-homes");
    config.state_dir.clone().filter(|p| allowed && p.is_absolute())
}

/// Where Friends' pieces are for this run, or None when Friends is not offered.
#[allow(unused_variables)]
fn locate<R: Runtime>(app: &AppHandle<R>, config: &Config<R>) -> Option<Located> {
    #[cfg(any(target_os = "linux", windows))]
    {
        let helper = match &config.helper {
            Helper::At(path) => path.clone(),
            Helper::Bundled => {
                let executable = std::env::current_exe().ok()?;
                let name = if cfg!(windows) { "szfriends-helper.exe" } else { "szfriends-helper" };
                executable.parent()?.join(name)
            }
        };
        if !helper.is_file() {
            return None;
        }
        let connector = link::desktop::HelperConnector::new(Some(helper), test_home(config))?;
        let state_dir = connector.state_dir().to_path_buf();
        let animals = bundled_animals(app, config);
        return Some(Located { connector: Arc::new(connector), state_dir, animals, data_dir: None });
    }
    #[cfg(target_os = "macos")]
    {
        let bundle = match &config.helper {
            Helper::At(path) => path.clone(),
            Helper::Bundled => {
                let executable = std::env::current_exe().ok()?;
                executable.parent()?.parent()?.join("Helpers").join("Shenzhen Friends.app")
            }
        };
        let helper = link::mac::MacHelper::from_bundle(&bundle)?;
        if !runs_here(&helper.executable) {
            return None;
        }
        let team = mac_signing::own_team();
        let connector = link::mac::MacConnector::new(Some(helper), team, test_home(config))?;
        let state_dir = connector.state_dir().to_path_buf();
        // The helper bundle carries the set where the helper itself reads it.
        let animals = config.animals.clone().unwrap_or_else(|| bundle.join("Contents/Resources/Friends/animals"));
        return Some(Located { connector: Arc::new(connector), state_dir, animals: Some(animals), data_dir: None });
    }
    #[cfg(any(target_os = "android", target_os = "ios"))]
    {
        if !config.embedded {
            return None;
        }
        let native = app.try_state::<phone::native::Native<R>>()?.inner().clone();
        // Android's no-backup directory, or iOS's Application Support with Friends excluded from backups.
        let base = native.base()?;
        let (state_dir, keys): (PathBuf, phone::Keys) = match test_home(config) {
            // A test home keeps its key in a file of its own, as the befriend tool seeds it.
            Some(home) => {
                let keys = home.join("keys");
                (home, Arc::new(move || Box::new(szfriends_identity::keystore::FileKeyStore::new(keys.clone()))))
            }
            None => (base.join("Friends"), phone::native::key_store(&native, &base)),
        };
        phone::keys::private_directory(&state_dir).ok()?;
        if cfg!(target_os = "ios") && !native.exclude_from_backup(&state_dir) {
            link::log("Friends could not be kept out of backups; it stays off");
            return None;
        }
        let connector = link::embedded::EmbeddedConnector::new(state_dir.clone(), keys);
        let animals = config.animals.clone().or_else(|| phone::animals::unpack(&base));
        return Some(Located { connector: Arc::new(connector), state_dir, animals, data_dir: Some(base) });
    }
    #[allow(unreachable_code)]
    None
}

/// Whether this Mac can run the helper: an arm64-only helper on an Intel Mac reports Friends unavailable rather
/// than a helper that cannot start (ADR 0015 § 2).
#[cfg(target_os = "macos")]
fn runs_here(executable: &std::path::Path) -> bool {
    use std::io::Read;
    let mut header = [0u8; 8];
    let read = std::fs::File::open(executable).and_then(|mut f| f.read_exact(&mut header));
    if read.is_err() {
        return false;
    }
    const ARM64: [u8; 4] = [0x0c, 0x00, 0x00, 0x01];
    const X86_64: [u8; 4] = [0x07, 0x00, 0x00, 0x01];
    let thin = header[..4] == [0xcf, 0xfa, 0xed, 0xfe];
    let own = if cfg!(target_arch = "aarch64") { ARM64 } else { X86_64 };
    // A universal binary carries both slices; a thin one must be ours.
    !thin || header[4..8] == own
}

const GUEST: &str = include_str!("../guest/bridge.js");
/// The most a phone stages of one dropped file: its bytes cross into Rust in one piece, so a larger file is refused
/// before it is read.
pub const STAGED_DROP_LIMIT: u64 = 250 * 1000 * 1000;

/// The plugin. Registers its commands and the guest script, and nothing more.
pub fn init<R: Runtime>(config: Config<R>) -> TauriPlugin<R> {
    let windows = serde_json::to_string(&config.windows).unwrap_or_else(|_| "[]".into());
    let served = config.windows.clone();
    // Phones give the page no path for a dropped file, so the panel stages its bytes, up to this many.
    let staged_drops = if cfg!(any(target_os = "android", target_os = "ios")) { STAGED_DROP_LIMIT } else { 0 };
    let guest = GUEST
        .replace("__SZFRIENDS_WINDOWS__", &windows)
        .replace("__SZFRIENDS_STAGED_DROP_LIMIT__", &staged_drops.to_string())
        .replace("__SZFRIENDS_DRAG_OVER__", if cfg!(target_os = "macos") { "true" } else { "false" });
    Builder::new("szfriends")
        .js_init_script(guest)
        .invoke_handler(tauri::generate_handler![
            commands::join,
            commands::status,
            commands::send,
            commands::set_enabled,
            commands::image,
            commands::animal,
            commands::animals,
            commands::classify,
            commands::stage,
            commands::token,
            commands::open_file,
            commands::show_file,
            commands::open_settings,
            commands::open_url,
            commands::shareable,
            drops::drop_paths,
            drops::drag_over,
        ])
        .setup(move |app, _api| {
            // Phones: the plugin's Kotlin or Swift half, registered once (Tauri keeps one per plugin). It answers calls
            // for the key store, backups and sharing, and Nearby's, which find people for the core; nothing starts here.
            #[cfg(any(target_os = "android", target_os = "ios"))]
            match phone::native::Native::register(&_api) {
                Ok(native) => {
                    nearby::install(native.handle());
                    app.manage(native);
                }
                Err(error) => link::log(&format!("no platform half: {error}")),
            }
            let windows = config.windows.clone();
            app.manage(Friends {
                config: std::sync::Mutex::new(Some(config)),
                host: OnceLock::new(),
                windows,
                drops: drops::Drops::default(),
            });
            Ok(())
        })
        .on_page_load(|webview, payload| {
            // A reload or navigation starts a new page: the old page's subscriptions go with it.
            if payload.event() == tauri::webview::PageLoadEvent::Started {
                if let Some(host) = webview.state::<Friends<R>>().started() {
                    host.forget(webview.label());
                }
            }
        })
        .on_webview_ready(move |webview| {
            if served.iter().any(|w| w == webview.label()) {
                drops::listen(&webview);
            }
        })
        .on_window_ready(|window| {
            let app = window.app_handle().clone();
            let label = window.label().to_owned();
            window.on_window_event(move |event| match event {
                WindowEvent::Focused(_) => {
                    if let Some(host) = app.state::<Friends<R>>().started() {
                        host.refresh_share_menu();
                    }
                }
                WindowEvent::Destroyed => {
                    if let Some(host) = app.state::<Friends<R>>().started() {
                        host.forget(&label);
                    }
                }
                // Phones: Friends follows the app into the background and back (`phone`'s grace period).
                #[cfg(any(target_os = "android", target_os = "ios"))]
                WindowEvent::Suspended | WindowEvent::Resumed => {
                    if let Some(host) = app.state::<Friends<R>>().started() {
                        host.foreground(matches!(event, WindowEvent::Resumed));
                    }
                }
                // An app that turns on Tauri's own drag and drop gets the paths this way.
                WindowEvent::DragDrop(tauri::DragDropEvent::Drop { paths, .. }) => native_drop(&app, &label, paths),
                _ => {}
            });
        })
        .on_event(|app, event| {
            if let RunEvent::Exit = event {
                if let Some(host) = app.state::<Friends<R>>().started() {
                    host.dispose();
                }
            }
        })
        .build()
}

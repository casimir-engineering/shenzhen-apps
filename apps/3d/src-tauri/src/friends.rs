//! Shenzhen Friends in the Tauri shell (docs/FRIENDS.md § Tauri), behind the `friends` feature: the pinned
//! tauri-plugin-szfriends gives the main window `window.shenzhenFriends`, the bridge the Electron preload gives the
//! Mac app, so the React panel in `src/friends/` runs unchanged. The plugin registers its commands and nothing else
//! at launch; Friends starts on the page's first `join()`, after its first paint.

use std::path::PathBuf;
use std::sync::Arc;

/// What the panel implements (PROTOCOL.md § Capabilities), as the Electron host says it: `#` offers the open
/// model, files may be dropped, `@` mentions friends, a list row's menu opens on right-click (a long press on
/// phones), and people nearby show how they were found. Phones have nothing to drop files from, so their composer
/// does not suggest it.
#[cfg(desktop)]
const CAPABILITIES: &[&str] = &[
    "attach.items",
    "drop.files",
    "mentions",
    "list.menu",
    "nearby.found",
];
#[cfg(mobile)]
const CAPABILITIES: &[&str] = &["attach.items", "mentions", "list.menu", "nearby.found"];

/// The formats the viewer opens, the same list as `bundle.fileAssociations`: received files in these offer Open.
pub const OPEN_FORMATS: &[&str] = &[
    "sz3d", "step", "stp", "iges", "igs", "brep", "brp", "stl", "obj", "glb", "gltf", "3mf", "ply",
    "off", "fbx", "dae", "wrl", "vrml", "dxf", "dwg", "svg",
];

pub fn plugin() -> tauri::plugin::TauriPlugin<tauri::Wry> {
    #[cfg(all(target_os = "android", debug_assertions))]
    android_test_environment();
    // A development or test run uses a Friends home of its own, as the Electron app does, so trying the panel
    // never reaches the person's own Friends identity, and may name a helper of its own (else the one the app
    // carries). Only debug and smoke builds look: a release build always serves the person's own Friends.
    let home = std::env::var_os("SZFRIENDS_STATE_DIR")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .filter(|_| cfg!(debug_assertions) || cfg!(feature = "friends-smoke"));
    let helper = std::env::var_os("SHENZHEN_3D_FRIENDS_HELPER")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute() && home.is_some())
        .map_or(tauri_plugin_szfriends::Helper::Bundled, |path| {
            tauri_plugin_szfriends::Helper::At(path)
        });
    let open: tauri_plugin_szfriends::OpenFiles<tauri::Wry> =
        Arc::new(|app: &tauri::AppHandle, paths: Vec<PathBuf>| {
            crate::native_open::queue(app, paths)
        });
    tauri_plugin_szfriends::init(tauri_plugin_szfriends::Config {
        app_id: "com.shenzhen3d.viewer".into(),
        app_name: "Shenzhen 3D".into(),
        app_version: env!("CARGO_PKG_VERSION").into(),
        locale: "en".into(),
        capabilities: CAPABILITIES.iter().map(|c| (*c).to_owned()).collect(),
        open_formats: OPEN_FORMATS.iter().map(|f| (*f).to_owned()).collect(),
        // Projects the app saves, and files dropped where the webview gives no path: any plain name.
        staged_extensions: Vec::new(),
        link_scheme: crate::friends_links::SCHEME.into(),
        windows: vec!["main".into()],
        helper,
        state_dir: home.clone(),
        // Test runs keep the Friends setting and staged files in a directory of their own.
        data_dir: home
            .as_ref()
            .and(std::env::var_os("SHENZHEN_3D_FRIENDS_DATA"))
            .map(PathBuf::from)
            .filter(|p| p.is_absolute()),
        animals: std::env::var_os("SHENZHEN_3D_FRIENDS_ANIMALS")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute()),
        // Phones run the core in the app's own process (ADR 0015 § 3), with the Keystore or the Keychain.
        embedded: cfg!(mobile),
        open_files: Some(open),
        // Phones have no File menu: the panel's header offers Copy Download Link.
        #[cfg(desktop)]
        share_menu: Some(Arc::new(share_menu)),
        #[cfg(mobile)]
        share_menu: None,
    })
}

/// Debug builds on Android, which start with no environment of their own: a test run's Friends home and loopback
/// routes from `files/friends-test.env` in the app's private directory (written with `adb shell run-as`), as
/// `SZFRIENDS_STATE_DIR` and `SZFRIENDS_TEST_LOOPBACK` give them on desktops and in the iOS simulator.
#[cfg(all(target_os = "android", debug_assertions))]
fn android_test_environment() {
    let file = "/data/data/com.shenzhen3d.viewer/files/friends-test.env";
    let Ok(text) = std::fs::read_to_string(file) else {
        return;
    };
    for (key, value) in text.lines().filter_map(|line| line.split_once('=')) {
        if matches!(key, "SZFRIENDS_STATE_DIR" | "SZFRIENDS_TEST_LOOPBACK") {
            // SAFETY: at startup, before the plugin or the core starts a thread that reads the environment.
            unsafe { std::env::set_var(key, value) };
        }
    }
}

/// File ▸ Copy Download Link: the submenu's id, and each expiry's item id.
#[cfg(desktop)]
const LINK_MENU: &str = "friends-copy-download-link";
#[cfg(desktop)]
const LINK_ITEM: &str = "friends-link-";

/// The expiry chosen in File ▸ Copy Download Link, from the menu item's id.
#[cfg(desktop)]
pub fn link_choice(id: &str) -> Option<u32> {
    let days = id.strip_prefix(LINK_ITEM)?.parse().ok()?;
    tauri_plugin_szfriends::LINK_DAYS
        .contains(&days)
        .then_some(days)
}

/// Copy Download Link in the File menu, after Open File…, as the Electron app has it: there while Friends makes
/// download links, enabled while the focused window has a model open. Shenzhen 3D's own words, as in the other apps.
#[cfg(desktop)]
fn share_menu(app: &tauri::AppHandle, menu: tauri_plugin_szfriends::ShareMenu) {
    use tauri::menu::{IsMenuItem, MenuItem, Submenu};
    let Some(file) = app
        .menu()
        .and_then(|bar| bar.get("file"))
        .and_then(|item| item.as_submenu().cloned())
    else {
        return;
    };
    let existing = file
        .get(LINK_MENU)
        .and_then(|item| item.as_submenu().cloned());
    let shown = match (menu.offered, existing) {
        (true, Some(submenu)) => submenu,
        (true, None) => {
            let label = |days: u32| match days {
                1 => "For 1 Day".to_owned(),
                days => format!("For {days} Days"),
            };
            let made: tauri::Result<Submenu<tauri::Wry>> = (|| {
                let items: Vec<MenuItem<tauri::Wry>> = tauri_plugin_szfriends::LINK_DAYS
                    .iter()
                    .map(|days| {
                        MenuItem::with_id(
                            app,
                            format!("{LINK_ITEM}{days}"),
                            label(*days),
                            true,
                            None::<&str>,
                        )
                    })
                    .collect::<tauri::Result<_>>()?;
                let refs: Vec<&dyn IsMenuItem<tauri::Wry>> =
                    items.iter().map(|i| i as &dyn IsMenuItem<_>).collect();
                Submenu::with_id_and_items(
                    app,
                    LINK_MENU,
                    "Copy Download Link",
                    menu.enabled,
                    &refs,
                )
            })();
            let Ok(submenu) = made else { return };
            let items = file.items().unwrap_or_default();
            let open = items.iter().position(|item| item.id() == "open");
            let _ = file.insert(&submenu, open.map_or(items.len(), |at| at + 1));
            submenu
        }
        (false, Some(submenu)) => {
            let _ = file.remove(&submenu);
            return;
        }
        (false, None) => return,
    };
    let _ = shown.set_enabled(menu.enabled);
}

#[cfg(test)]
mod tests {
    #[test]
    fn open_formats_are_the_file_associations() {
        let config: serde_json::Value =
            serde_json::from_str(include_str!("../tauri.conf.json")).unwrap();
        let mut associated: Vec<String> = config["bundle"]["fileAssociations"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|a| {
                a["ext"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|e| e.as_str().unwrap().to_owned())
            })
            .collect();
        let mut ours: Vec<String> = super::OPEN_FORMATS
            .iter()
            .map(|f| (*f).to_owned())
            .collect();
        associated.sort();
        ours.sort();
        assert_eq!(ours, associated);
    }

    #[test]
    fn the_menu_offers_7_1_and_30_days_and_nothing_else() {
        assert_eq!(super::link_choice("friends-link-7"), Some(7));
        assert_eq!(super::link_choice("friends-link-1"), Some(1));
        assert_eq!(super::link_choice("friends-link-30"), Some(30));
        for other in [
            "friends-link-2",
            "friends-link-",
            "friends-link-x",
            "open",
            "friends-copy-download-link",
        ] {
            assert_eq!(super::link_choice(other), None, "{other}");
        }
    }

    #[test]
    fn friends_commands_go_to_the_main_window_only_and_no_remote_page() {
        // build.rs declares it in Friends builds only, so builds without the feature carry no such permission.
        let capability: serde_json::Value =
            serde_json::from_str(include_str!("../capabilities/friends/capability.json")).unwrap();
        assert_eq!(capability["windows"], serde_json::json!(["main"]));
        assert!(capability.get("remote").is_none());
        assert!(capability.get("webviews").is_none());
        assert_eq!(
            capability["permissions"],
            serde_json::json!(["szfriends:default"])
        );
    }
}

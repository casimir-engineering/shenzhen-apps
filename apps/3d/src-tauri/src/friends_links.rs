//! Friends URLs opened from outside the app: a `shenzhen3d://friends/link#<payload>` URL clicked in a browser, a
//! message or another app opens the link's card in the focused window once Friends is ready (PROTOCOL.md § Links),
//! and a notification's `shenzhen3d://friends/conversation/<id>` (or `shenzhen3d://friends`) opens the panel on
//! that conversation (or the list; § Notifications), as the Electron app does. The plugin checks each URL before
//! anything is sent; anything else is left alone.
//!
//! The systems hand the app its links in their own ways. A Mac and iOS report them with the files the app is asked
//! to open (`RunEvent::Opened`, src/lib.rs), from the `CFBundleURLTypes` a Friends build declares. Windows and Linux
//! start the app with the link as its argument (the installers and the deb and rpm desktop entries register the
//! scheme from `plugins.deep-link` in src-tauri/friends/tauri.conf.json); a second launch hands its link, or its
//! files, to the app already running. Android delivers them to the activity through the intent filter
//! tauri-plugin-deep-link adds to Friends builds from src-tauri/friends/phones.conf.json.

use tauri::Manager;

/// The app's Friends link scheme, as the plugin is configured with it (src/friends.rs).
pub const SCHEME: &str = "shenzhen3d";

/// Whether `url` is in the app's Friends link scheme; the plugin checks the rest.
pub fn is_link(url: &str) -> bool {
    url.split_once(':')
        .is_some_and(|(scheme, _)| scheme.eq_ignore_ascii_case(SCHEME))
}

/// Gives each Friends URL among `urls` to the plugin, which shows the link's card or the conversation in the main
/// window once Friends is ready, and brings that window to the front.
pub fn open<I, S>(app: &tauri::AppHandle, urls: I)
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let Some(friends) = app.try_state::<tauri_plugin_szfriends::Friends<tauri::Wry>>() else {
        return;
    };
    let mut opened = false;
    for url in urls.into_iter().filter(|url| is_link(url.as_ref())) {
        // The URL carries a link's secret: it is never logged.
        if friends.open_link(app, url.as_ref()) {
            opened = true;
        } else {
            log::warn!("Not a Friends link this app can open");
        }
    }
    if let (true, Some(window)) = (opened, app.get_webview_window("main")) {
        let _ = window.show();
        #[cfg(desktop)]
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

/// Windows and Linux: one app at a time, so that a link or a file opened while the app runs reaches the running
/// app. This plugin goes first, as a second launch must hand over before anything else starts. Android: the
/// deep-link plugin, which hears the activity's links.
#[cfg(any(windows, target_os = "linux", target_os = "android"))]
pub fn plugins(builder: tauri::Builder<tauri::Wry>) -> tauri::Builder<tauri::Wry> {
    #[cfg(any(windows, target_os = "linux"))]
    let builder = builder.plugin(tauri_plugin_single_instance::init(second_launch));
    #[cfg(target_os = "android")]
    let builder = builder.plugin(tauri_plugin_deep_link::init());
    builder
}

/// A second launch on Windows or Linux, which ends once it has handed over: its links open their cards and its files
/// open in the window in front, as the Electron app does.
#[cfg(any(windows, target_os = "linux"))]
fn second_launch(app: &tauri::AppHandle, argv: Vec<String>, cwd: String) {
    let (links, others): (Vec<String>, Vec<String>) = argv.into_iter().skip(1).partition(|arg| is_link(arg));
    let cwd = std::path::PathBuf::from(cwd);
    let files = others
        .into_iter()
        .filter(|arg| !arg.starts_with('-'))
        .map(|arg| cwd.join(arg))
        .collect();
    crate::native_open::queue(app, files);
    open(app, links);
}

/// At setup: the link the app was started with, and on Android every later one.
#[cfg(any(windows, target_os = "linux", target_os = "android"))]
pub fn listen(app: &tauri::AppHandle) {
    #[cfg(any(windows, target_os = "linux"))]
    open(app, std::env::args().skip(1));
    #[cfg(target_os = "android")]
    {
        use tauri_plugin_deep_link::DeepLinkExt;
        if let Ok(Some(urls)) = app.deep_link().get_current() {
            open(app, urls.iter().map(|url| url.as_str()));
        }
        let handle = app.clone();
        app.deep_link().on_open_url(move |event| {
            open(&handle, event.urls().iter().map(|url| url.as_str()));
        });
    }
}

#[cfg(test)]
mod tests {
    use super::{is_link, SCHEME};

    fn config(file: &str) -> serde_json::Value {
        let path = format!("{}/friends/{file}", env!("CARGO_MANIFEST_DIR"));
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    #[test]
    fn only_the_app_scheme_is_a_friends_link() {
        assert!(is_link("shenzhen3d://friends/link#d.AQ"));
        assert!(is_link("SHENZHEN3D://friends/link#d.AQ"));
        assert!(is_link("shenzhen3d://friends/conversation/c_mei"));
        for other in [
            "file:///Users/a/Gearbox.step",
            "https://example.com/shenzhen3d:",
            "shenzhenpdf://friends/link#d.AQ",
            "C:\\Models\\Gearbox.step",
            "/home/a/shenzhen3d:x",
            "",
        ] {
            assert!(!is_link(other), "{other}");
        }
    }

    #[test]
    fn the_scheme_is_the_one_the_plugin_is_given() {
        assert!(include_str!("friends.rs").contains("link_scheme: crate::friends_links::SCHEME.into()"));
    }

    #[test]
    fn desktop_friends_builds_register_the_scheme() {
        // The Windows installers, the deb and rpm desktop entries and the Mac's Info.plist take it from here (the
        // Tauri bundler reads it whether or not the app carries the deep-link plugin).
        for file in ["tauri.conf.json", "mac.conf.json"] {
            let schemes = &config(file)["plugins"]["deep-link"]["desktop"]["schemes"];
            assert_eq!(schemes, &serde_json::json!([SCHEME]), "{file}");
        }
    }

    #[test]
    fn phone_friends_builds_register_the_scheme() {
        // Android: the deep-link plugin's intent filter, for the scheme alone (no web links to verify).
        let mobile = &config("phones.conf.json")["plugins"]["deep-link"]["mobile"];
        assert_eq!(
            mobile,
            &serde_json::json!([{ "scheme": [SCHEME], "host": "friends", "appLink": false }])
        );
        // iOS: the keys merged into the app's Info.plist.
        let plist = include_str!("../friends/ios/Info.plist");
        let types = plist.split("<key>CFBundleURLTypes</key>").nth(1).unwrap();
        let schemes = types.split("<key>CFBundleURLSchemes</key>").nth(1).unwrap();
        let listed = schemes.split("</array>").next().unwrap();
        assert_eq!(listed.matches("<string>").count(), 1);
        assert!(listed.contains(&format!("<string>{SCHEME}</string>")));
    }

    #[test]
    fn builds_without_friends_claim_no_scheme() {
        let base: serde_json::Value = serde_json::from_str(include_str!("../tauri.conf.json")).unwrap();
        assert!(base.get("plugins").is_none_or(|p| p.get("deep-link").is_none()));
        let manifest = include_str!("../gen/android/app/src/main/AndroidManifest.xml");
        assert!(!manifest.contains(&format!("android:scheme=\"{SCHEME}\"")));
        let info = include_str!("../gen/apple/shenzhen-3d_iOS/Info.plist");
        assert!(!info.contains("CFBundleURLTypes"));
    }
}

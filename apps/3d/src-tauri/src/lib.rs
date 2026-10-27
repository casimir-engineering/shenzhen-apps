#[cfg(target_os = "android")]
mod android_updates;
#[cfg(any(windows, target_os = "linux", target_os = "ios"))]
mod app_updates;
#[cfg(feature = "friends")]
mod friends;
#[cfg(feature = "friends")]
mod friends_links;
#[cfg(windows)]
mod hidden_windows;
mod native_open;
#[cfg(any(windows, target_os = "linux", target_os = "ios", test))]
mod release_feed;
#[cfg(feature = "friends-smoke")]
mod smoke;
#[cfg(any(desktop, test))]
mod window_bounds;
#[cfg(desktop)]
use tauri::{Emitter, Manager};

#[cfg(desktop)]
fn desktop_menu(app: &tauri::App) -> tauri::Result<()> {
    use tauri::menu::{Menu, MenuItem, PredefinedMenuItem as P, Submenu};
    let item = |id, label, shortcut| MenuItem::with_id(app, id, label, true, Some(shortcut));
    let settings = item("settings", "Settings…", "CmdOrCtrl+,")?;
    let open = item("open", "Open File…", "CmdOrCtrl+O")?;
    let new = item("new-window", "New Window", "CmdOrCtrl+N")?;
    let export = item("export", "Export Measurements…", "CmdOrCtrl+Shift+E")?;
    let fit = item("fit", "Fit Model", "CmdOrCtrl+0")?;
    let iso = item("isometric", "Isometric View", "Shift+7")?;
    let front = item("front", "Front View", "Shift+1")?;
    let top = item("top", "Top View", "Shift+5")?;
    let right = item("right", "Right View", "Shift+4")?;
    let back = item("back", "Back View", "Shift+2")?;
    let left = item("left", "Left View", "Shift+3")?;
    let bottom = item("bottom", "Bottom View", "Shift+6")?;
    let clear = item("clear", "Clear Measurements", "CmdOrCtrl+Backspace")?;
    let point = item("point", "Point Measurement", "CmdOrCtrl+Shift+P")?;
    let feature = item("feature", "Feature Measurement", "CmdOrCtrl+Shift+F")?;
    let help = item("help", "Navigation & Shortcuts", "CmdOrCtrl+/")?;
    // The id lets Friends add File ▸ Copy Download Link after Open File… (src/friends.rs).
    let file = Submenu::with_id_and_items(
        app,
        "file",
        "File",
        true,
        &[
            &new,
            &open,
            &P::separator(app)?,
            &export,
            &P::separator(app)?,
            &P::close_window(app, None)?,
        ],
    )?;
    let edit = Submenu::with_items(
        app,
        "Edit",
        true,
        &[
            &P::undo(app, None)?,
            &P::redo(app, None)?,
            &P::separator(app)?,
            &P::cut(app, None)?,
            &P::copy(app, None)?,
            &P::paste(app, None)?,
            &P::select_all(app, None)?,
        ],
    )?;
    let measure = Submenu::with_items(
        app,
        "Measure",
        true,
        &[&point, &feature, &P::separator(app)?, &clear],
    )?;
    let view = Submenu::with_items(
        app,
        "View",
        true,
        &[
            &fit,
            &P::separator(app)?,
            &iso,
            &front,
            &back,
            &left,
            &right,
            &top,
            &bottom,
            &P::separator(app)?,
            &P::fullscreen(app, None)?,
        ],
    )?;
    let window = Submenu::with_items(
        app,
        "Window",
        true,
        &[&P::minimize(app, None)?, &P::maximize(app, None)?],
    )?;
    let help_menu = Submenu::with_items(app, "Help", true, &[&help])?;
    let about = P::about(
        app,
        Some("About Shenzhen 3D"),
        Some(tauri::menu::AboutMetadata {
            name: Some("Shenzhen 3D".into()),
            version: Some(app.package_info().version.to_string()),
            comments: Some("Local-first CAD, mesh and drawing viewer".into()),
            ..Default::default()
        }),
    )?;
    #[cfg(target_os = "macos")]
    let app_menu = Submenu::with_items(
        app,
        "Shenzhen 3D",
        true,
        &[
            &about,
            &settings,
            &P::separator(app)?,
            &P::services(app, None)?,
            &P::separator(app)?,
            &P::hide(app, None)?,
            &P::hide_others(app, None)?,
            &P::show_all(app, None)?,
            &P::separator(app)?,
            &P::quit(app, None)?,
        ],
    )?;
    #[cfg(target_os = "macos")]
    let menu = Menu::with_items(
        app,
        &[
            &app_menu, &file, &edit, &measure, &view, &window, &help_menu,
        ],
    )?;
    #[cfg(not(target_os = "macos"))]
    let menu = {
        help_menu.append(&about)?;
        edit.append(&P::separator(app)?)?;
        edit.append(&settings)?;
        file.append(&P::quit(app, None)?)?;
        Menu::with_items(app, &[&file, &edit, &measure, &view, &window, &help_menu])?
    };
    app.set_menu(menu)?;
    app.on_menu_event(|app, event| {
        let action = event.id().as_ref();
        #[cfg(feature = "friends")]
        if let Some(days) = friends::link_choice(action) {
            tauri_plugin_szfriends::copy_download_link(app, days);
            return;
        }
        if action == "new-window" {
            let label = format!(
                "viewer-{}",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis()
            );
            if let Err(error) =
                tauri::WebviewWindowBuilder::new(app, label, tauri::WebviewUrl::default())
                    .title("Shenzhen 3D")
                    .inner_size(1440.0, 960.0)
                    .min_inner_size(360.0, 560.0)
                    .disable_drag_drop_handler()
                    .build()
            {
                log::error!("Could not open viewer: {error}");
            }
        } else if let Some(window) = app
            .webview_windows()
            .values()
            .find(|window| window.is_focused().unwrap_or(false))
        {
            let _ = window.emit("native-menu", serde_json::json!({"action": action}));
        }
    });
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = tauri::Builder::default().manage(native_open::NativeOpenFiles::default());
    #[cfg(all(feature = "friends", any(windows, target_os = "linux", target_os = "android")))]
    let builder = friends_links::plugins(builder);
    #[cfg(all(
        not(feature = "friends-smoke"),
        not(any(windows, target_os = "linux", target_os = "ios", target_os = "android"))
    ))]
    let builder = builder.invoke_handler(tauri::generate_handler![
        native_open::take_native_open_files
    ]);
    // Android updates itself from GitHub Releases (src/android_updates.rs, docs/UPDATES.md § Android).
    #[cfg(all(not(feature = "friends-smoke"), target_os = "android"))]
    let builder = builder
        .plugin(android_updates::plugin())
        .invoke_handler(tauri::generate_handler![
            native_open::take_native_open_files,
            android_updates::android_updates,
            android_updates::android_updates_subscribe
        ]);
    // Windows, Linux and iOS update themselves from GitHub Releases (src/app_updates.rs, docs/UPDATES.md).
    #[cfg(all(
        not(feature = "friends-smoke"),
        any(windows, target_os = "linux", target_os = "ios")
    ))]
    let builder = builder
        .plugin(app_updates::plugin())
        .invoke_handler(tauri::generate_handler![
            native_open::take_native_open_files,
            app_updates::app_updates,
            app_updates::app_updates_subscribe
        ]);
    #[cfg(all(not(feature = "friends-smoke"), any(windows, target_os = "linux")))]
    let builder = builder.plugin(tauri_plugin_updater::Builder::new().build());
    let builder = builder
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init());
    #[cfg(desktop)]
    let builder = builder.plugin(window_bounds::plugin());
    #[cfg(feature = "friends")]
    let builder = builder.plugin(friends::plugin());
    #[cfg(feature = "friends-smoke")]
    let builder = builder
        .manage(smoke::Checks::default())
        .invoke_handler(tauri::generate_handler![
            native_open::take_native_open_files,
            smoke::smoke_checks,
            smoke::smoke_report,
            smoke::smoke_native_drop,
            smoke::smoke_link_ready
        ])
        .on_page_load(smoke::page_loaded);
    builder
        .setup(|_app| {
            // A close aimed at the app's hidden windows closes its windows instead (src/hidden_windows.rs).
            #[cfg(windows)]
            hidden_windows::pass_on(_app.handle());
            #[cfg(desktop)]
            desktop_menu(_app)?;
            // After the menu: on Windows the menu bar is part of the frame the window is sized with.
            #[cfg(desktop)]
            window_bounds::restore(_app.handle());
            #[cfg(all(feature = "friends", any(windows, target_os = "linux", target_os = "android")))]
            friends_links::listen(_app.handle());
            #[cfg(desktop)]
            if cfg!(debug_assertions) {
                _app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }
            #[cfg(desktop)]
            native_open::queue(
                _app.handle(),
                std::env::args_os()
                    .skip(1)
                    .map(std::path::PathBuf::from)
                    .collect(),
            );
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("Could not start Shenzhen 3D")
        .run(|_app, _event| {
            #[cfg(any(target_os = "macos", target_os = "ios"))]
            if let tauri::RunEvent::Opened { urls } = _event {
                #[cfg(feature = "friends")]
                friends_links::open(_app, urls.iter().map(|url| url.as_str()));
                native_open::queue(
                    _app,
                    urls.into_iter()
                        .filter_map(|url| url.to_file_path().ok())
                        .collect(),
                );
            }
        });
}

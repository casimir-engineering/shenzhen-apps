use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::{Emitter, Manager};
use tauri_plugin_fs::FsExt;

#[derive(Default)]
pub struct NativeOpenFiles(Mutex<HashMap<String, VecDeque<Vec<String>>>>);

// Only OS-delivered paths enter this queue; the renderer cannot grant itself paths. Android delivers none outside
// Friends' Open.
#[cfg_attr(all(target_os = "android", not(feature = "friends")), allow(dead_code))]
pub fn queue(app: &tauri::AppHandle, paths: Vec<PathBuf>) {
    let files: Vec<String> = paths
        .into_iter()
        .take(256)
        .filter_map(|path| path.canonicalize().ok())
        .filter(|path| path.is_file())
        .filter(|path| app.fs_scope().allow_file(path).is_ok())
        .map(|path| path.to_string_lossy().into_owned())
        .collect();
    if files.is_empty() {
        return;
    }
    let windows = app.webview_windows();
    let window = windows
        .values()
        .find(|window| window.is_focused().unwrap_or(false))
        .or_else(|| windows.get("main"));
    let label = window.map(|window| window.label()).unwrap_or("main");
    if let Ok(mut pending) = app.state::<NativeOpenFiles>().0.lock() {
        let batches = pending.entry(label.into()).or_default();
        if batches.len() >= 16 {
            batches.pop_front();
        }
        batches.push_back(files);
    }
    if let Some(window) = window {
        let _ = window.emit("native-open-files", ());
        let _ = window.show();
        #[cfg(desktop)]
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

#[tauri::command]
pub fn take_native_open_files(
    window: tauri::WebviewWindow,
    state: tauri::State<'_, NativeOpenFiles>,
) -> Vec<Vec<String>> {
    state
        .0
        .lock()
        .ok()
        .and_then(|mut pending| pending.remove(window.label()))
        .map(|batches| batches.into_iter().collect())
        .unwrap_or_default()
}

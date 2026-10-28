//! Files dropped on a window, as the system reported them, so a desktop sends each file from where it is instead of
//! a copy of its bytes (ADR 0015 § 4). The page keeps the browser's own drag and drop, which is what lets Friends
//! show where a drop will land; the system's report of the same drop gives the paths the browser hides:
//!
//! - Windows: the page hands the dropped files to WebView2 (`postMessageWithAdditionalObjects`), which knows their
//!   paths;
//! - Linux: WebKitGTK's `drag-data-received` on the window's webview, the URI list the file manager offered;
//! - macOS: the drag pasteboard, which holds the last drag's file URLs until the next drag, read only when this
//!   window's page received the drop of a drag the system saw over this window ([`drag_over`]: the button down and
//!   the pointer inside it), while the pasteboard's change count is still that drag's and the button is up again.
//!   One drag is read for one window only, however long ago it started.
//!
//! The page asks with the dropped files' names and sizes ([`drop_paths`]); every file must match one the system
//! reported, or none is given and the panel refuses the drop. Phones have no such report: there the panel stages the
//! files' bytes instead (`stage`). An app that learns of drops itself can report them with [`crate::native_drop`].

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod mac;
#[cfg(windows)]
mod windows;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Deserialize;
use tauri::{AppHandle, Runtime, State, Webview};

use crate::Friends;

/// The marker before the ticket in the page's WebView2 message (Windows; the guest script says the same).
#[cfg(windows)]
pub const MESSAGE_PREFIX: &str = "szfriends-drop:";
/// Reports kept per window; a drop the page never asks about is forgotten after this long.
const KEPT: usize = 4;
const KEPT_FOR: Duration = Duration::from_secs(10 * 60);
/// How long the page's question waits for WebView2's report of the same drop, which comes on its own channel.
const TICKET_WAIT: Duration = Duration::from_millis(1500);
const MAX_FILES: usize = 100;

/// One regular file the system reported.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Dropped {
    pub name: String,
    pub size: u64,
    pub path: String,
}

#[derive(Debug)]
struct Report {
    ticket: Option<String>,
    files: Vec<Dropped>,
    at: Instant,
}

/// The latest reports per window, and on a Mac the drag each window last had over it.
#[derive(Debug, Default)]
pub struct Drops {
    reports: Mutex<HashMap<String, Vec<Report>>>,
    /// Window label to the drag pasteboard's change count while a drag was over that window. The next drag changes
    /// the count, so an entry names one drag only.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    armed: Mutex<HashMap<String, isize>>,
}

impl Drops {
    /// A drag (the drag pasteboard at `count`) is over window `label` now.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    pub fn arm(&self, label: &str, count: isize) {
        self.armed.lock().unwrap_or_else(|e| e.into_inner()).insert(label.to_owned(), count);
    }

    /// The change count of the drag last seen over window `label`; used up.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    pub fn disarm(&self, label: &str) -> Option<isize> {
        self.armed.lock().unwrap_or_else(|e| e.into_inner()).remove(label)
    }

    /// The drag at `count` was dropped on window `label`, and the pasteboard still holds its `paths`: they are that
    /// window's, and no other window the same drag passed over may ask for them.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    pub fn record_drag(&self, label: &str, count: isize, paths: &[PathBuf]) {
        self.armed.lock().unwrap_or_else(|e| e.into_inner()).retain(|_, armed| *armed != count);
        self.record(label, None, paths);
    }

    /// A drop the system reported on window `label`; `ticket` names the page's question it answers (Windows).
    pub fn record(&self, label: &str, ticket: Option<String>, paths: &[PathBuf]) {
        let files: Vec<Dropped> = paths.iter().take(MAX_FILES).filter_map(|p| dropped(p)).collect();
        let mut map = self.reports.lock().unwrap_or_else(|e| e.into_inner());
        let reports = map.entry(label.to_owned()).or_default();
        reports.retain(|r| r.at.elapsed() < KEPT_FOR);
        if reports.len() >= KEPT {
            reports.remove(0);
        }
        reports.push(Report { ticket, files, at: Instant::now() });
    }

    fn has_ticket(&self, label: &str, ticket: &str) -> bool {
        let map = self.reports.lock().unwrap_or_else(|e| e.into_inner());
        map.get(label).is_some_and(|r| r.iter().any(|r| r.ticket.as_deref() == Some(ticket)))
    }

    /// The paths of `wanted` (name and size, in order), all from one report, newest first: the report for `ticket`
    /// or one without a ticket. The report is used up.
    pub fn take(&self, label: &str, wanted: &[(String, u64)], ticket: Option<&str>) -> Option<Vec<String>> {
        let mut map = self.reports.lock().unwrap_or_else(|e| e.into_inner());
        let reports = map.get_mut(label)?;
        reports.retain(|r| r.at.elapsed() < KEPT_FOR);
        let (index, paths) = reports.iter().enumerate().rev().find_map(|(index, report)| {
            let fits = report.ticket.is_none() || report.ticket.as_deref() == ticket;
            fits.then(|| matching(&report.files, wanted)).flatten().map(|paths| (index, paths))
        })?;
        reports.remove(index);
        Some(paths)
    }
}

/// `path` as a dropped file: a regular file (not a link or a folder) with a plain path and a UTF-8 name.
pub fn dropped(path: &Path) -> Option<Dropped> {
    let metadata = std::fs::symlink_metadata(path).ok().filter(|m| m.is_file())?;
    let name = path.file_name()?.to_str()?.to_owned();
    let text = path.to_str().filter(|p| crate::validate::plain_path(p))?.to_owned();
    Some(Dropped { name, size: metadata.len(), path: text })
}

/// Each wanted file matched to a different reported one by name and size, or None.
pub fn matching(files: &[Dropped], wanted: &[(String, u64)]) -> Option<Vec<String>> {
    if wanted.is_empty() || wanted.len() > files.len() {
        return None;
    }
    let mut used = vec![false; files.len()];
    wanted
        .iter()
        .map(|(name, size)| {
            let index = (0..files.len()).find(|&i| !used[i] && files[i].name == *name && files[i].size == *size)?;
            used[index] = true;
            Some(files[index].path.clone())
        })
        .collect()
}

/// Starts listening for the system's reports on a window the plugin serves (Linux and Windows; a Mac reads the drag
/// pasteboard when asked). Wry webviews only; other runtimes have no system webview to listen to.
#[allow(unused_variables)]
pub fn listen<R: Runtime>(webview: &Webview<R>) {
    #[cfg(any(windows, target_os = "linux"))]
    {
        use tauri::Manager;
        if std::any::TypeId::of::<R>() != std::any::TypeId::of::<tauri::Wry>() {
            return;
        }
        let app = webview.app_handle().clone();
        let label = webview.label().to_owned();
        let report = move |ticket: Option<String>, paths: Vec<PathBuf>| {
            if let Some(friends) = app.try_state::<Friends<R>>() {
                friends.drops.record(&label, ticket, &paths);
            }
        };
        #[cfg(windows)]
        windows::listen(webview, report);
        #[cfg(target_os = "linux")]
        linux::listen(webview, report);
    }
}

#[derive(Debug, Deserialize)]
pub struct Wanted {
    name: String,
    size: u64,
}

/// Paste in a composer: the files on the system clipboard (copied in Finder or a Linux file manager), as their
/// paths, whatever they are (the page classifies them as it does a drop's); none for text or a picture. Windows has
/// none here: WebView2 hands the page pasted files with their paths itself, as it does dropped ones.
#[tauri::command]
pub async fn clipboard_files<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
    friends: State<'_, Friends<R>>,
) -> Result<Vec<String>, String> {
    if !friends.windows.iter().any(|window| window == webview.label()) {
        return Err("Friends request is not allowed".into());
    }
    #[cfg(target_os = "macos")]
    let paths = mac::general_pasteboard(&app).await;
    #[cfg(target_os = "linux")]
    let paths = linux::clipboard_paths(&app).await;
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    let paths: Vec<PathBuf> = {
        let _ = &app;
        Vec::new()
    };
    Ok(paths.into_iter().take(MAX_FILES).filter_map(|path| path.to_str().map(str::to_owned)).collect())
}

/// The paths of files just dropped on this window, by their names and sizes as the page sees them, in order; None
/// when the system did not report every one of them (a phone, or a drop from an app that gives no file).
#[tauri::command]
pub async fn drop_paths<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
    friends: State<'_, Friends<R>>,
    files: Vec<Wanted>,
    ticket: Option<String>,
) -> Result<Option<Vec<String>>, String> {
    let label = webview.label().to_owned();
    if !friends.windows.contains(&label) {
        return Err("Friends request is not allowed".into());
    }
    if files.is_empty() || files.len() > MAX_FILES {
        return Ok(None);
    }
    let wanted: Vec<(String, u64)> = files.into_iter().map(|f| (f.name, f.size)).collect();
    // Only the drag the system saw over this very window, once dropped (the button is up again; the page's question
    // follows its drop event), and only while the pasteboard still holds that drag.
    #[cfg(target_os = "macos")]
    if let Some(count) = friends.drops.disarm(&label) {
        let board = mac::drag_pasteboard(&app).await;
        if board.count == Some(count) && !board.button_down {
            friends.drops.record_drag(&label, count, &board.paths);
        }
    }
    let _ = &app;
    if let Some(ticket) = ticket.as_deref().filter(|t| t.len() <= 64) {
        let started = Instant::now();
        while !friends.drops.has_ticket(&label, ticket) && started.elapsed() < TICKET_WAIT {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
    Ok(friends.drops.take(&label, &wanted, ticket.as_deref()))
}

/// The page saw files dragged over this window (a Mac only; elsewhere nothing to do): if the system agrees, with the
/// mouse button down and the pointer inside the window, that drag's drop may be asked about.
#[tauri::command]
pub async fn drag_over<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
    friends: State<'_, Friends<R>>,
) -> Result<(), String> {
    let label = webview.label().to_owned();
    if !friends.windows.contains(&label) {
        return Err("Friends request is not allowed".into());
    }
    #[cfg(target_os = "macos")]
    {
        let window = webview.window();
        let inside = match (app.cursor_position(), window.outer_position(), window.outer_size()) {
            (Ok(cursor), Ok(origin), Ok(size)) => {
                let (left, top) = (f64::from(origin.x), f64::from(origin.y));
                (left..left + f64::from(size.width)).contains(&cursor.x)
                    && (top..top + f64::from(size.height)).contains(&cursor.y)
            }
            _ => false,
        };
        if let Some(count) = if inside { mac::dragging(&app).await } else { None } {
            friends.drops.arm(&label, count);
        }
    }
    let _ = &app;
    Ok(())
}

#[cfg(test)]
#[path = "../tests/drops.rs"]
mod tests;

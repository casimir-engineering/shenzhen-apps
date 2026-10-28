//! Linux: WebKitGTK asks the file manager for a drag's URI list as soon as the drag enters the window, before the
//! page sees the drop, so the paths are known by the time the page asks. Only local `file:` URIs count.

use std::path::PathBuf;

use gtk::prelude::WidgetExt;
use tauri::{AppHandle, Runtime, Webview};

use super::MAX_FILES;

pub fn listen<R: Runtime>(webview: &Webview<R>, report: impl Fn(Option<String>, Vec<PathBuf>) + Send + 'static) {
    let _ = webview.with_webview(move |platform| {
        platform.inner().connect_drag_data_received(move |_, _, _, _, data, _, _| {
            let paths = local_paths(&data.uris());
            if !paths.is_empty() {
                report(None, paths);
            }
        });
    });
}

/// The local files a URI list names, in order.
fn local_paths(uris: &[gtk::glib::GString]) -> Vec<PathBuf> {
    uris.iter()
        .take(MAX_FILES)
        .filter_map(|uri| gtk::glib::filename_from_uri(uri).ok())
        .filter(|(_, host)| host.as_deref().is_none_or(|h| h.is_empty() || h == "localhost"))
        .map(|(path, _)| path)
        .collect()
}

/// The files on the clipboard (copied in a file manager, which offers them as a URI list), read on the main thread.
pub async fn clipboard_paths<R: Runtime>(app: &AppHandle<R>) -> Vec<PathBuf> {
    let (sender, receiver) = tokio::sync::oneshot::channel();
    let asked = app.run_on_main_thread(move || {
        let clipboard = gtk::Clipboard::get(&gtk::gdk::SELECTION_CLIPBOARD);
        let _ = sender.send(local_paths(&clipboard.wait_for_uris()));
    });
    if asked.is_err() {
        return Vec::new();
    }
    receiver.await.unwrap_or_default()
}

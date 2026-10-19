//! Linux: WebKitGTK asks the file manager for a drag's URI list as soon as the drag enters the window, before the
//! page sees the drop, so the paths are known by the time the page asks. Only local `file:` URIs count.

use std::path::PathBuf;

use gtk::prelude::WidgetExt;
use tauri::{Runtime, Webview};

use super::MAX_FILES;

pub fn listen<R: Runtime>(webview: &Webview<R>, report: impl Fn(Option<String>, Vec<PathBuf>) + Send + 'static) {
    let _ = webview.with_webview(move |platform| {
        platform.inner().connect_drag_data_received(move |_, _, _, _, data, _, _| {
            let paths: Vec<PathBuf> = data
                .uris()
                .iter()
                .take(MAX_FILES)
                .filter_map(|uri| gtk::glib::filename_from_uri(uri).ok())
                .filter(|(_, host)| host.as_deref().is_none_or(|h| h.is_empty() || h == "localhost"))
                .map(|(path, _)| path)
                .collect();
            if !paths.is_empty() {
                report(None, paths);
            }
        });
    });
}

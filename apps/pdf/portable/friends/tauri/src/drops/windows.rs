//! Windows: the page hands the files of a drop to WebView2 with `postMessageWithAdditionalObjects`, and WebView2 gives
//! each as an `ICoreWebView2File` with the path the browser keeps from the page. Only files the person dropped or
//! picked carry a path, so the page cannot name any other file this way. Wry's own handler sees the same message and
//! ignores it.

use std::path::PathBuf;

use tauri::{Runtime, Webview};
use webview2_com::Microsoft::Web::WebView2::Win32::{ICoreWebView2File, ICoreWebView2WebMessageReceivedEventArgs2};
use webview2_com::{take_pwstr, WebMessageReceivedEventHandler};
use windows_core::{Interface, PWSTR};

use super::{MAX_FILES, MESSAGE_PREFIX};

pub fn listen<R: Runtime>(webview: &Webview<R>, report: impl Fn(Option<String>, Vec<PathBuf>) + Send + 'static) {
    let _ = webview.with_webview(move |platform| unsafe {
        let Ok(core) = platform.controller().CoreWebView2() else { return };
        let handler = WebMessageReceivedEventHandler::create(Box::new(move |_, args| {
            let Some(args) = args else { return Ok(()) };
            let mut text = PWSTR::null();
            if args.TryGetWebMessageAsString(&mut text).is_err() {
                return Ok(());
            }
            let text = take_pwstr(text);
            let Some(ticket) = text.strip_prefix(MESSAGE_PREFIX).filter(|t| !t.is_empty() && t.len() <= 64) else {
                return Ok(());
            };
            let Ok(objects) =
                args.cast::<ICoreWebView2WebMessageReceivedEventArgs2>().and_then(|a| a.AdditionalObjects())
            else {
                return Ok(());
            };
            let mut count = 0u32;
            objects.Count(&mut count)?;
            let mut paths = Vec::new();
            for index in 0..count.min(MAX_FILES as u32) {
                let Ok(file) = objects.GetValueAtIndex(index).and_then(|o| o.cast::<ICoreWebView2File>()) else {
                    continue;
                };
                let mut path = PWSTR::null();
                if file.Path(&mut path).is_ok() {
                    let path = take_pwstr(path);
                    if !path.is_empty() {
                        paths.push(PathBuf::from(path));
                    }
                }
            }
            report(Some(ticket.to_owned()), paths);
            Ok(())
        }));
        let mut token = 0i64;
        let _ = core.add_WebMessageReceived(&handler, &mut token);
    });
}

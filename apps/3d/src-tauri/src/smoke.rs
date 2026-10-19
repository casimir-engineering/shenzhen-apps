//! Test builds only (`friends-smoke`): the Friends smoke (scripts/friends/tauri-smoke.mjs) runs a script of its own
//! in the main window once the page has loaded, as a person would use the panel. When that passes, a second window
//! opens and checks that it has no Friends bridge and cannot call Friends' commands; then the app prints every check
//! and quits. Nothing of this is in a release build.

use std::sync::Mutex;

use tauri::webview::{PageLoadEvent, PageLoadPayload};
use tauri::{Manager, Webview};

/// The second window's label: one the Friends capability does not name.
const SECOND: &str = "viewer-smoke";

const SECOND_WINDOW_CHECKS: &str = r#"(async () => {
  const lines = [];
  let ok = typeof window.shenzhenFriends === "undefined";
  lines.push(`${ok ? "ok" : "not ok"} a second window has no Friends bridge`);
  try {
    await window.__TAURI_INTERNALS__.invoke("plugin:szfriends|status");
    lines.push("not ok a second window can call Friends");
    ok = false;
  } catch {
    lines.push("ok a second window cannot call Friends commands");
  }
  await window.__TAURI_INTERNALS__.invoke("smoke_report", { ok, lines });
})();"#;

/// The main window's checks, kept until the second window reports.
#[derive(Default)]
pub struct Checks(Mutex<Vec<String>>);

/// Runs `$SHENZHEN_3D_SMOKE` (a file of JavaScript) in the main window, and the second window's checks there.
pub fn page_loaded(webview: &Webview, payload: &PageLoadPayload<'_>) {
    if payload.event() != PageLoadEvent::Finished {
        return;
    }
    let script = match webview.label() {
        "main" => match std::env::var_os("SHENZHEN_3D_SMOKE").map(std::fs::read_to_string) {
            Some(Ok(script)) => script,
            Some(Err(error)) => {
                return fail(
                    webview.app_handle(),
                    &format!("could not read the script: {error}"),
                );
            }
            None => return,
        },
        SECOND => SECOND_WINDOW_CHECKS.to_owned(),
        _ => return,
    };
    if let Err(error) = webview.eval(script) {
        fail(
            webview.app_handle(),
            &format!("could not run the script: {error}"),
        );
    }
}

fn fail(app: &tauri::AppHandle, why: &str) {
    println!("SMOKE-FAILED {why}");
    app.exit(2);
}

/// The main window's checks: on success the second window opens; on failure the run ends here. Async, as a command
/// that opens a window must be (on Windows a synchronous one deadlocks).
#[tauri::command]
pub async fn smoke_checks(app: tauri::AppHandle, ok: bool, lines: Vec<String>) {
    if !ok {
        return smoke_report(app, false, lines);
    }
    if let Some(checks) = app.try_state::<Checks>() {
        checks.0.lock().map(|mut kept| kept.extend(lines)).ok();
    }
    let built = tauri::WebviewWindowBuilder::new(&app, SECOND, tauri::WebviewUrl::default())
        .title("Shenzhen 3D")
        .build();
    if let Err(error) = built {
        fail(&app, &format!("no second window: {error}"));
    }
}

/// The last report: every check printed, then the app quits with 0 when all passed.
#[tauri::command]
pub fn smoke_report(app: tauri::AppHandle, ok: bool, lines: Vec<String>) {
    let mut all: Vec<String> = app
        .try_state::<Checks>()
        .and_then(|checks| checks.0.lock().ok().map(|kept| kept.clone()))
        .unwrap_or_default();
    all.extend(lines);
    for line in &all {
        println!("SMOKE {line}");
    }
    println!("{}", if ok { "SMOKE-PASSED" } else { "SMOKE-FAILED" });
    app.exit(if ok { 0 } else { 1 });
}

/// The system's report of a drop on the main window, as the plugin's drop listener receives it from WebView2,
/// WebKitGTK or the drag pasteboard, for a file the runner wrote: a script cannot make the system drag a file.
#[tauri::command]
pub fn smoke_native_drop(app: tauri::AppHandle, path: String) {
    tauri_plugin_szfriends::native_drop(&app, "main", &[std::path::PathBuf::from(path)]);
}

/// Windows and Linux: the page waits for a Friends link, which the runner opens as the system does, by starting the
/// app again with the link as its argument; that launch hands it to this app (src/friends_links.rs) and ends.
#[tauri::command]
pub fn smoke_link_ready() {
    println!("SMOKE-LINK-READY");
}

//! The plugin's commands: the `FriendsBridge` methods, each refused unless it comes from a window the plugin serves
//! (the capability already grants them to the main window only; this is the second lock). Everything that touches
//! the disk or a process runs off the main thread.

use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{json, Value};
use tauri::ipc::{Channel, InvokeBody, Request, Response};
use tauri::{AppHandle, Runtime, State, Webview};

use crate::host::Host;
use crate::Friends;

type Answer<T> = Result<T, String>;

fn allowed<R: Runtime>(app: &AppHandle<R>, friends: &Friends<R>, webview: &Webview<R>) -> Answer<Arc<Host<R>>> {
    let host = friends.host(app);
    if host.config.windows.iter().any(|w| w == webview.label()) {
        Ok(host)
    } else {
        Err("Friends request is not allowed".into())
    }
}

/// The host, when Friends runs in this build; most methods mean nothing otherwise.
fn available<R: Runtime>(app: &AppHandle<R>, friends: &Friends<R>, webview: &Webview<R>) -> Answer<Arc<Host<R>>> {
    let host = allowed(app, friends, webview)?;
    if host.status()["available"] == true {
        Ok(host)
    } else {
        Err("Friends is not available".into())
    }
}

async fn blocking<T: Send + 'static>(work: impl FnOnce() -> T + Send + 'static) -> Answer<T> {
    tauri::async_runtime::spawn_blocking(work).await.map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn join<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
    friends: State<'_, Friends<R>>,
    events: Channel<Value>,
) -> Answer<Value> {
    let host = allowed(&app, &friends, &webview)?;
    let label = webview.label().to_owned();
    blocking(move || host.join(&label, events)).await
}

#[tauri::command]
pub async fn status<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
    friends: State<'_, Friends<R>>,
) -> Answer<Value> {
    let host = allowed(&app, &friends, &webview)?;
    Ok(host.status())
}

#[tauri::command]
pub async fn send<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
    friends: State<'_, Friends<R>>,
    kind: Value,
    fields: Value,
) -> Answer<Value> {
    let host = available(&app, &friends, &webview)?;
    Ok(host.send(webview.label(), &kind, &fields).await)
}

#[tauri::command]
pub async fn set_enabled<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
    friends: State<'_, Friends<R>>,
    enabled: bool,
) -> Answer<Value> {
    let host = available(&app, &friends, &webview)?;
    blocking(move || host.set_enabled(enabled)).await
}

/// A preview or a picture from the Friends state directory, as a small JSON header (kind, width, height) and the
/// image's bytes; nothing when it fails any check.
#[tauri::command]
pub async fn image<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
    friends: State<'_, Friends<R>>,
    kind: String,
    path: String,
    width: Option<u32>,
    height: Option<u32>,
) -> Answer<Response> {
    let host = available(&app, &friends, &webview)?;
    let state_dir = host.state_dir();
    let read = blocking(move || crate::files::read_helper_image(state_dir.as_deref(), &kind, &path, (width, height)));
    let Some((size, bytes)) = read.await? else { return Ok(Response::new(Vec::new())) };
    let header = json!({"type": size.kind, "width": size.width, "height": size.height}).to_string();
    let mut body = (header.len() as u32).to_be_bytes().to_vec();
    body.extend_from_slice(header.as_bytes());
    body.extend_from_slice(&bytes);
    Ok(Response::new(body))
}

#[tauri::command]
pub async fn animal<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
    friends: State<'_, Friends<R>>,
    set: Value,
    index: Value,
) -> Answer<Value> {
    let host = available(&app, &friends, &webview)?;
    blocking(move || host.animals().and_then(|a| a.animal(&set, &index)).unwrap_or(Value::Null)).await
}

#[tauri::command]
pub async fn animals<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
    friends: State<'_, Friends<R>>,
) -> Answer<Value> {
    let host = available(&app, &friends, &webview)?;
    blocking(move || host.animals().and_then(|a| a.list()).unwrap_or(Value::Null)).await
}

#[tauri::command]
pub async fn classify<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
    friends: State<'_, Friends<R>>,
    paths: Value,
) -> Answer<Vec<&'static str>> {
    available(&app, &friends, &webview)?;
    let Some(list) = paths.as_array().filter(|l| l.len() <= 100).cloned() else { return Ok(Vec::new()) };
    blocking(move || {
        list.iter()
            .map(|p| match p.as_str() {
                Some(path) if crate::validate::plain_path(path) => crate::files::classify_path(path),
                _ => "missing",
            })
            .collect()
    })
    .await
}

/// A project the page made, or the bytes of files dropped without a path: written privately for sending. The
/// bytes come as the request's body, the name in its `szfriends-name` header.
#[tauri::command]
pub async fn stage<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
    friends: State<'_, Friends<R>>,
    request: Request<'_>,
) -> Answer<String> {
    let host = available(&app, &friends, &webview)?;
    let name = request
        .headers()
        .get("szfriends-name")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| tauri::Url::parse(&format!("x:/{v}")).ok())
        .and_then(|u| u.path_segments().and_then(|mut s| s.next().map(percent_decode)))
        .ok_or("Invalid project name")?;
    let bytes = match request.body() {
        InvokeBody::Raw(bytes) if bytes.len() <= crate::files::MAX_STAGED_BYTES => bytes.clone(),
        // Android's WebView sends a page's bytes as a JSON array of numbers (its requests carry no body).
        InvokeBody::Json(Value::Array(numbers)) if numbers.len() <= crate::files::MAX_STAGED_BYTES => numbers
            .iter()
            .map(|n| n.as_u64().and_then(|n| u8::try_from(n).ok()))
            .collect::<Option<Vec<u8>>>()
            .ok_or("Invalid project")?,
        _ => return Err("Invalid project".into()),
    };
    let outgoing = host.outgoing().ok_or("Could not stage")?;
    let kinds = host.config.staged_extensions.clone();
    let file = blocking(move || crate::files::stage(&outgoing, &name, &bytes, &kinds)).await?;
    let file = file.map_err(str::to_owned)?;
    file.to_str().map(str::to_owned).ok_or_else(|| "Could not stage".into())
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = |b: u8| (b as char).to_digit(16);
        match (bytes[i], bytes.get(i + 1).copied().and_then(hex), bytes.get(i + 2).copied().and_then(hex)) {
            (b'%', Some(high), Some(low)) => {
                out.push((high * 16 + low) as u8);
                i += 3;
            }
            (byte, _, _) => {
                out.push(byte);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[tauri::command]
pub async fn token<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
    friends: State<'_, Friends<R>>,
) -> Answer<String> {
    allowed(&app, &friends, &webview)?;
    let mut bytes = [0u8; 16];
    szfriends_crypto::random_bytes(&mut bytes);
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// Opens a received file in the app: only a file the service offered to open, in a format the app opens.
#[tauri::command]
pub async fn open_file<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
    friends: State<'_, Friends<R>>,
    path: String,
) -> Answer<bool> {
    let host = available(&app, &friends, &webview)?;
    if !crate::validate::plain_path(&path) || !host.was_offered(&path) {
        return Ok(false);
    }
    let extension = PathBuf::from(&path).extension().and_then(|e| e.to_str()).map(str::to_lowercase);
    if !extension.is_some_and(|e| host.config.open_formats.contains(&e)) {
        return Ok(false);
    }
    let checked = path.clone();
    if blocking(move || crate::files::classify_path(&checked)).await? != "file" {
        return Ok(false);
    }
    let Some(open) = host.config.open_files.clone() else { return Ok(false) };
    open(&app, vec![PathBuf::from(path)]);
    Ok(true)
}

#[tauri::command]
pub async fn show_file<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
    friends: State<'_, Friends<R>>,
    path: String,
) -> Answer<bool> {
    let host = available(&app, &friends, &webview)?;
    if !crate::validate::plain_path(&path) {
        return Ok(false);
    }
    // Phones: only a received file a snapshot offered goes to the share sheet, and never a folder.
    #[cfg(any(target_os = "android", target_os = "ios"))]
    {
        use tauri::Manager;
        let native = app.try_state::<crate::phone::native::Native<R>>().map(|n| n.inner().clone());
        let Some(native) = native.filter(|_| host.was_offered(&path)) else { return Ok(false) };
        return blocking(move || crate::files::classify_path(&path) == "file" && native.share(&path)).await;
    }
    #[allow(unreachable_code)]
    {
        let _ = host;
        blocking(move || crate::files::classify_path(&path) != "missing" && crate::open::reveal(path.as_ref())).await
    }
}

#[tauri::command]
pub async fn open_settings<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
    friends: State<'_, Friends<R>>,
    target: Value,
) -> Answer<bool> {
    available(&app, &friends, &webview)?;
    let Some(url) = target.as_str().and_then(crate::urls::settings_url) else { return Ok(false) };
    let url = url.to_owned();
    blocking(move || system_open(&app, &url)).await
}

#[tauri::command]
pub async fn open_url<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
    friends: State<'_, Friends<R>>,
    url: Value,
) -> Answer<bool> {
    available(&app, &friends, &webview)?;
    let Some(url) = url.as_str().and_then(crate::urls::external_url) else { return Ok(false) };
    blocking(move || system_open(&app, &url)).await
}

/// A checked URL to the system: the platform half on phones, the opener program on desktops.
fn system_open<R: Runtime>(app: &AppHandle<R>, url: &str) -> bool {
    #[cfg(any(target_os = "android", target_os = "ios"))]
    {
        use tauri::Manager;
        return app.try_state::<crate::phone::native::Native<R>>().is_some_and(|native| native.open_url(url));
    }
    #[allow(unreachable_code)]
    {
        let _ = app;
        crate::open::open_url(url)
    }
}

/// Whether this window has a model open, for File ▸ Copy Download Link in the app's menu (`share.rs`).
#[tauri::command]
pub async fn shareable<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
    friends: State<'_, Friends<R>>,
    value: bool,
) -> Answer<()> {
    let host = allowed(&app, &friends, &webview)?;
    let label = webview.label().to_owned();
    blocking(move || host.set_shareable(&label, value)).await
}

//! The plugin's invoke handler: what `tauri::generate_handler!` would build for the commands, with one task for all
//! of them. The macro gives each async command a task type of its own, and with it a copy of the runtime's task code
//! (spawning, polling, cancelling, for both schedulers): about 7 KB per command in a phone's library (ADR 0015 § 12).
//! Here every command runs inside one future, behind a `dyn`. The commands, their names, their arguments (read by
//! `CommandArg` under the same keys) and their replies are the macro's; the permissions are checked before any handler
//! runs, as for every plugin.

use std::future::Future;
use std::pin::Pin;

use tauri::ipc::{CommandArg, CommandItem, Invoke, InvokeError, InvokeMessage, InvokeResponseBody, IpcResponse};
use tauri::utils::acl::resolved::ResolvedCommand;
use tauri::Runtime;

use crate::{commands, drops};

/// Every command, by the name the page invokes (build.rs's list, which grants them).
const COMMANDS: &[&str] = &[
    "join",
    "status",
    "send",
    "set_enabled",
    "image",
    "animal",
    "animals",
    "classify",
    "stage",
    "token",
    "open_file",
    "show_file",
    "open_settings",
    "open_url",
    "shareable",
    "choose_files",
    "shared_files",
    "drop_paths",
    "clipboard_files",
    "drag_over",
];

type Reply = Result<InvokeResponseBody, InvokeError>;

pub(crate) fn handle<R: Runtime>(invoke: Invoke<R>) -> bool {
    let Some(name) = COMMANDS.iter().copied().find(|name| *name == invoke.message.command()) else { return false };
    let Invoke { message, resolver, acl } = invoke;
    let task: Pin<Box<dyn Future<Output = Reply> + Send>> = Box::pin(run(name, message, acl));
    resolver.respond_async_serialized(task);
    true
}

/// One argument, as the macro reads it: by its parameter's name (in camelCase; every name here is one word).
fn arg<'a, R: Runtime, T: CommandArg<'a, R>>(
    name: &'static str,
    key: &'static str,
    message: &'a InvokeMessage<R>,
    acl: &'a Option<Vec<ResolvedCommand>>,
) -> Result<T, InvokeError> {
    T::from_command(CommandItem { plugin: Some("szfriends"), name, key, message, acl })
}

/// A command's answer as the macro sends it: the value serialized as JSON (a `Response` as its own body), an error
/// as its message.
fn reply<T: IpcResponse, E: Into<InvokeError>>(answer: Result<T, E>) -> Reply {
    Ok(answer.map_err(Into::into)?.body()?)
}

async fn run<R: Runtime>(name: &'static str, message: InvokeMessage<R>, acl: Option<Vec<ResolvedCommand>>) -> Reply {
    macro_rules! a {
        ($key:literal) => {
            arg(name, $key, &message, &acl)?
        };
    }
    // The first three arguments of every command: the app, the calling webview and the plugin's state.
    macro_rules! call {
        ($path:path $(, $key:literal)*) => {
            reply($path(a!("app"), a!("webview"), a!("friends") $(, a!($key))*).await)
        };
    }
    match name {
        "join" => call!(commands::join, "events"),
        "status" => call!(commands::status),
        "send" => call!(commands::send, "kind", "fields"),
        "set_enabled" => call!(commands::set_enabled, "enabled"),
        "image" => call!(commands::image, "kind", "path", "width", "height"),
        "animal" => call!(commands::animal, "set", "index"),
        "animals" => call!(commands::animals),
        "classify" => call!(commands::classify, "paths"),
        "stage" => call!(commands::stage, "request"),
        "token" => call!(commands::token),
        "open_file" => call!(commands::open_file, "path"),
        "show_file" => call!(commands::show_file, "path"),
        "open_settings" => call!(commands::open_settings, "target"),
        "open_url" => call!(commands::open_url, "url"),
        "shareable" => call!(commands::shareable, "value"),
        "choose_files" => call!(commands::choose_files),
        "shared_files" => call!(commands::shared_files),
        "drop_paths" => call!(drops::drop_paths, "files", "ticket"),
        "clipboard_files" => call!(drops::clipboard_files),
        _ => call!(drops::drag_over),
    }
}

//! macOS: the drag pasteboard keeps the file URLs of the last drag until the next one starts, so when the page asks
//! about a drop it has just received, the pasteboard still holds that drop's files. Its change count names the drag:
//! the plugin reads the files only for the drag it saw over its own window. Read on the main thread.

use std::path::PathBuf;

use objc2_app_kit::{NSEvent, NSPasteboard, NSPasteboardNameDrag, NSPasteboardTypeFileURL};
use objc2_foundation::NSURL;
use tauri::{AppHandle, Runtime};

use super::MAX_FILES;

/// The drag pasteboard as it is now.
#[derive(Debug, Default)]
pub struct DragBoard {
    pub paths: Vec<PathBuf>,
    /// None when it could not be read.
    pub count: Option<isize>,
    /// The primary mouse button is down: a drag may still be going on.
    pub button_down: bool,
}

/// The drag pasteboard's files and change count, and whether the button is down.
pub async fn drag_pasteboard<R: Runtime>(app: &AppHandle<R>) -> DragBoard {
    on_main_thread(app, || {
        let board = unsafe { NSPasteboard::pasteboardWithName(NSPasteboardNameDrag) };
        let button_down = NSEvent::pressedMouseButtons() & 1 != 0;
        DragBoard { paths: read_board(&board), count: Some(board.changeCount()), button_down }
    })
    .await
    .unwrap_or_default()
}

/// The drag pasteboard's change count while the primary mouse button is down (a drag in progress), else None.
pub async fn dragging<R: Runtime>(app: &AppHandle<R>) -> Option<isize> {
    on_main_thread(app, || {
        let down = NSEvent::pressedMouseButtons() & 1 != 0;
        down.then(|| unsafe { NSPasteboard::pasteboardWithName(NSPasteboardNameDrag) }.changeCount())
    })
    .await
    .flatten()
}

async fn on_main_thread<R: Runtime, T: Send + 'static>(
    app: &AppHandle<R>,
    work: impl FnOnce() -> T + Send + 'static,
) -> Option<T> {
    let (sender, receiver) = tokio::sync::oneshot::channel();
    app.run_on_main_thread(move || {
        let _ = sender.send(work());
    })
    .ok()?;
    receiver.await.ok()
}

/// The file paths of `board`'s items, in order.
fn read_board(board: &NSPasteboard) -> Vec<PathBuf> {
    let Some(items) = board.pasteboardItems() else { return Vec::new() };
    items
        .iter()
        .take(MAX_FILES)
        .filter_map(|item| {
            let text = item.stringForType(unsafe { NSPasteboardTypeFileURL })?;
            // Finder offers file reference URLs (file:///.file/id=…); their file path URL names the file.
            let url = NSURL::URLWithString(&text)?.filePathURL()?;
            Some(PathBuf::from(url.path()?.to_string()))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use objc2_app_kit::{NSPasteboard, NSPasteboardTypeFileURL};
    use objc2_foundation::{NSString, NSURL};

    /// On a pasteboard of the test's own, never the drag pasteboard: Finder's file reference URLs and plain file
    /// URLs both give the file's path.
    #[test]
    fn file_urls_and_file_reference_urls_give_the_path() {
        let path = std::env::temp_dir().join(format!("szf-drop, a test {}.stl", std::process::id()));
        std::fs::write(&path, b"solid").unwrap();
        let path = std::fs::canonicalize(&path).unwrap();
        let board = NSPasteboard::pasteboardWithUniqueName();
        let url = NSURL::fileURLWithPath(&NSString::from_str(path.to_str().unwrap()));
        for written in [url.fileReferenceURL().unwrap_or_else(|| url.clone()), url.clone()] {
            board.clearContents();
            let text = written.absoluteString().unwrap();
            assert!(board.setString_forType(&text, unsafe { NSPasteboardTypeFileURL }));
            assert_eq!(super::read_board(&board), vec![path.clone()], "{text}");
        }
        // Gone from the pasteboard server too (releaseGlobally, which the bindings leave out).
        let _: () = unsafe { objc2::msg_send![&*board, releaseGlobally] };
        std::fs::remove_file(&path).unwrap();
    }
}

//! Windows: a request to close one of the app's hidden windows closes the app's windows instead, so the app ends
//! however Windows asks it to close.
//!
//! Besides its main window, the app owns two hidden top-level windows: tao's event target ("Tao Thread Event
//! Target"), through which the event loop receives everything that is not a window's own message, and, in Friends
//! builds, tauri-plugin-single-instance's window, which a second launch hands its arguments to. Both have the
//! WS_VISIBLE style (layered and transparent, so nothing shows). A minimized window goes to the bottom of the Z
//! order, so while the main window is minimized these two come first among the app's visible windows, and whatever
//! closes "the app" by closing its first visible window (taskkill without /f does) sent its WM_CLOSE to one of them.
//! They left it to DefWindowProc, which destroyed them, and the main window stayed open. With the single-instance
//! window gone, a later launch found no one to hand over to; with the event target gone, the event loop could no
//! longer act on the exit Tauri asks for when the last window closes, so closing the main window then left the
//! process running with no window, its Friends helper still connected.
//!
//! Here both windows answer WM_CLOSE by passing it on to the app's own visible windows, which close as when the
//! person closes them; when the last one closes, the app ends. The hidden windows themselves stay.

use std::ffi::c_void;

type Hwnd = *mut c_void;
type SubclassProc = unsafe extern "system" fn(Hwnd, u32, usize, isize, usize, usize) -> isize;

const WM_CLOSE: u32 = 0x0010;
const WM_NCDESTROY: u32 = 0x0082;
/// This module's subclass on a window, among others a window may have.
const SUBCLASS_ID: usize = 0x535a_3344; // "SZ3D"

#[link(name = "user32")]
unsafe extern "system" {
    fn EnumThreadWindows(thread: u32, callback: unsafe extern "system" fn(Hwnd, isize) -> i32, param: isize) -> i32;
    fn GetClassNameW(hwnd: Hwnd, name: *mut u16, max: i32) -> i32;
    fn GetWindowThreadProcessId(hwnd: Hwnd, process: *mut u32) -> u32;
    fn IsWindowVisible(hwnd: Hwnd) -> i32;
    fn PostMessageW(hwnd: Hwnd, msg: u32, wparam: usize, lparam: isize) -> i32;
}

#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetCurrentThreadId() -> u32;
}

#[link(name = "comctl32")]
unsafe extern "system" {
    fn SetWindowSubclass(hwnd: Hwnd, proc: SubclassProc, id: usize, data: usize) -> i32;
    fn RemoveWindowSubclass(hwnd: Hwnd, proc: SubclassProc, id: usize) -> i32;
    fn GetWindowSubclass(hwnd: Hwnd, proc: SubclassProc, id: usize, data: *mut usize) -> i32;
    fn DefSubclassProc(hwnd: Hwnd, msg: u32, wparam: usize, lparam: isize) -> isize;
}

/// tao's event target window.
const EVENT_TARGET_CLASS: &str = "Tao Thread Event Target";

/// Whether a window of this class is one of the app's hidden windows: tao's event target, or the single-instance
/// window, whose class is the app's identifier (with a version when the plugin is built with `semver`) and "-sic".
pub fn is_hidden_class(class: &str, identifier: &str) -> bool {
    class == EVENT_TARGET_CLASS || (class.starts_with(identifier) && class.ends_with("-sic"))
}

unsafe extern "system" fn pass_close_on(
    hwnd: Hwnd,
    msg: u32,
    wparam: usize,
    lparam: isize,
    _id: usize,
    _data: usize,
) -> isize {
    match msg {
        WM_CLOSE => {
            // SAFETY: a query on this window, which exists while it handles the message.
            let thread = unsafe { GetWindowThreadProcessId(hwnd, std::ptr::null_mut()) };
            for window in app_windows(thread) {
                // SAFETY: posting to a window of this thread; a window gone meanwhile only fails the post.
                unsafe { PostMessageW(window, WM_CLOSE, 0, 0) };
            }
            0
        }
        WM_NCDESTROY => {
            // SAFETY: the window is ours and still exists while it handles WM_NCDESTROY.
            unsafe {
                RemoveWindowSubclass(hwnd, pass_close_on, SUBCLASS_ID);
                DefSubclassProc(hwnd, msg, wparam, lparam)
            }
        }
        // SAFETY: the message goes on to the window's own procedure, as it would without this subclass.
        _ => unsafe { DefSubclassProc(hwnd, msg, wparam, lparam) },
    }
}

/// Makes `hwnd` pass WM_CLOSE on to the app's windows instead of closing. Call on the thread that created it.
pub fn pass_on_close(hwnd: Hwnd) -> bool {
    // SAFETY: subclassing a window of this thread; the procedure only changes what WM_CLOSE does.
    unsafe { SetWindowSubclass(hwnd, pass_close_on, SUBCLASS_ID, 0) != 0 }
}

fn passes_on_close(hwnd: Hwnd) -> bool {
    let mut data = 0;
    // SAFETY: a query on a window of this thread.
    unsafe { GetWindowSubclass(hwnd, pass_close_on, SUBCLASS_ID, &mut data) != 0 }
}

/// The visible top-level windows of `thread` that a person closes: all but the hidden ones that pass WM_CLOSE on.
fn app_windows(thread: u32) -> Vec<Hwnd> {
    thread_windows(thread)
        .into_iter()
        // SAFETY: a query on a window that existed when listed.
        .filter(|&window| unsafe { IsWindowVisible(window) } != 0 && !passes_on_close(window))
        .collect()
}

fn class_of(hwnd: Hwnd) -> String {
    let mut name = [0u16; 256];
    // SAFETY: `name` holds as many characters as is passed.
    let length = unsafe { GetClassNameW(hwnd, name.as_mut_ptr(), name.len() as i32) };
    String::from_utf16_lossy(&name[..length.max(0) as usize])
}

/// The top-level windows `thread` created.
fn thread_windows(thread: u32) -> Vec<Hwnd> {
    unsafe extern "system" fn collect(hwnd: Hwnd, param: isize) -> i32 {
        // SAFETY: `param` is the vector `thread_windows` passes, alive for the whole enumeration.
        unsafe { (*(param as *mut Vec<Hwnd>)).push(hwnd) };
        1
    }
    let mut found: Vec<Hwnd> = Vec::new();
    // SAFETY: the callback only pushes into `found`, which outlives the call.
    unsafe { EnumThreadWindows(thread, collect, &mut found as *mut Vec<Hwnd> as isize) };
    found
}

/// Makes the app's hidden windows pass WM_CLOSE on. Call from `setup`, on the main thread: the event loop and the
/// plugins' windows exist by then.
pub fn pass_on<R: tauri::Runtime>(app: &tauri::AppHandle<R>) {
    let identifier = &app.config().identifier;
    // SAFETY: a plain query.
    for hwnd in thread_windows(unsafe { GetCurrentThreadId() }) {
        let class = class_of(hwnd);
        if is_hidden_class(&class, identifier) && !pass_on_close(hwnd) {
            log::warn!("The hidden window {class} closes on WM_CLOSE");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_hidden_windows_pass_close_on() {
        let id = "com.shenzhen3d.viewer";
        assert!(is_hidden_class("Tao Thread Event Target", id));
        assert!(is_hidden_class("com.shenzhen3d.viewer-sic", id));
        assert!(is_hidden_class("com.shenzhen3d.viewer_0.2-sic", id));
        for other in [
            "Tauri Window",
            "com.shenzhen3d.viewer-siw",
            "org.other.app-sic",
            "MSCTFIME UI",
            "IME",
            "",
        ] {
            assert!(!is_hidden_class(other, id), "{other}");
        }
    }

    #[link(name = "user32")]
    unsafe extern "system" {
        fn CreateWindowExW(
            ex: u32,
            class: *const u16,
            name: *const u16,
            style: u32,
            x: i32,
            y: i32,
            w: i32,
            h: i32,
            parent: Hwnd,
            menu: Hwnd,
            instance: Hwnd,
            param: *mut c_void,
        ) -> Hwnd;
        fn SendMessageW(hwnd: Hwnd, msg: u32, wparam: usize, lparam: isize) -> isize;
        fn PeekMessageW(msg: *mut [usize; 8], hwnd: Hwnd, min: u32, max: u32, remove: u32) -> i32;
        fn DispatchMessageW(msg: *const [usize; 8]) -> isize;
        fn IsWindow(hwnd: Hwnd) -> i32;
        fn DestroyWindow(hwnd: Hwnd) -> i32;
    }

    /// A top-level window of this thread whose procedure leaves WM_CLOSE to DefWindowProc, as tao's event target's
    /// does ("Static", a system class), visible or not.
    fn window(visible: bool) -> Hwnd {
        const WS_POPUP: u32 = 0x8000_0000;
        const WS_VISIBLE: u32 = 0x1000_0000;
        let class: Vec<u16> = "Static\0".encode_utf16().collect();
        let style = if visible { WS_POPUP | WS_VISIBLE } else { WS_POPUP };
        let null = std::ptr::null_mut();
        // SAFETY: a zero-sized top-level window of this thread.
        let hwnd = unsafe {
            CreateWindowExW(
                0,
                class.as_ptr(),
                std::ptr::null(),
                style,
                0,
                0,
                0,
                0,
                null,
                null,
                null,
                null,
            )
        };
        assert!(!hwnd.is_null());
        hwnd
    }

    /// Delivers what was posted to this thread's windows.
    fn pump() {
        let mut msg = [0usize; 8];
        // SAFETY: the usual message loop, on this thread's queue; `msg` is larger than a MSG.
        while unsafe { PeekMessageW(&mut msg, std::ptr::null_mut(), 0, 0, 1) } != 0 {
            unsafe { DispatchMessageW(&msg) };
        }
    }

    /// Real windows: WM_CLOSE destroys a plain one; sent to a hidden window that passes it on, it closes the
    /// thread's visible windows instead (as the main window, when the main window is minimized and so comes after
    /// the hidden ones), and the hidden windows stay until the app destroys them.
    #[test]
    fn wm_close_to_a_hidden_window_closes_the_app_windows() {
        // SAFETY (all below): messages to windows this test made, on the thread that made them.
        let plain = window(false);
        unsafe { SendMessageW(plain, WM_CLOSE, 0, 0) };
        assert_eq!(unsafe { IsWindow(plain) }, 0, "WM_CLOSE destroys a plain window");

        let (target, single) = (window(true), window(true));
        assert!(pass_on_close(target) && pass_on_close(single));
        let main = window(true);
        let thread = unsafe { GetCurrentThreadId() };
        assert!(thread_windows(thread).contains(&main));
        assert_eq!(app_windows(thread), [main], "only the visible window a person closes");

        unsafe { SendMessageW(single, WM_CLOSE, 0, 0) };
        pump();
        assert_eq!(
            unsafe { IsWindow(main) },
            0,
            "the app's window received WM_CLOSE and closed"
        );
        assert!(
            unsafe { IsWindow(target) != 0 && IsWindow(single) != 0 },
            "the hidden windows stay"
        );
        unsafe { SendMessageW(target, WM_CLOSE, 0, 0) };
        pump();
        assert_ne!(
            unsafe { IsWindow(target) },
            0,
            "with no window left to close, nothing closes"
        );
        assert_eq!(class_of(target), "Static");
        assert!(unsafe { DestroyWindow(target) != 0 && DestroyWindow(single) != 0 });
        assert_eq!(unsafe { IsWindow(target) }, 0, "the app can still destroy them");
    }
}

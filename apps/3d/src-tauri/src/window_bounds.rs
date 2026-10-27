//! The main window opens where, and at the size, it was last left (desktop only).
//!
//! Why not tauri-plugin-window-state: it restores a window as soon as it is created, which is before `setup` gives the
//! window its menu. On Windows the menu bar then takes its height from the window's content, and the plugin saves that
//! smaller content size on close, so the window lost one menu bar's height on every launch (39 px at 200 %) until it was
//! a few pixels tall: it also never applied the window's minimum size. Here the window is placed after the menu exists,
//! the content size is checked after placing it and corrected once, and what is placed is always clamped to the
//! minimum size and to a display's work area. The pure part (`place`, `observe`, `migrate`) is tested below; the
//! Tauri part only measures the window and the displays and applies the result.
//!
//! Saved: the outer position and the content (inner) size in physical pixels, the scale they were measured at, and
//! whether the window was maximized. The bounds are those of the window when neither minimized nor maximized, so
//! un-maximizing it after a launch returns it to the size it had before it was maximized.
use serde::{Deserialize, Serialize};

/// What is written to disk.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Saved {
    /// Outer position, physical pixels.
    pub x: i32,
    pub y: i32,
    /// Content size, physical pixels.
    pub width: u32,
    pub height: u32,
    /// The scale factor the sizes were measured at.
    pub scale: f64,
    #[serde(default)]
    pub maximized: bool,
}

/// A display's work area (without the taskbar or Dock), physical pixels, and its scale factor.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Area {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub scale: f64,
}

/// Where the window goes: outer position and content size in physical pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Placement {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub scale: f64,
    pub maximized: bool,
}

/// The window's minimum and default content sizes, logical pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Limits {
    pub min: (f64, f64),
    pub default: (f64, f64),
}

/// The window as it is now, as `observe` takes it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Observed {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub scale: f64,
    pub minimized: bool,
    pub maximized: bool,
}

/// What to remember after the window moved, resized, or is closing: its bounds when it is a normal window; when it is
/// maximized, the bounds it had before and that it is maximized; when minimized (or of no size), what was known.
pub fn observe(last: Option<Saved>, now: Observed) -> Option<Saved> {
    if now.minimized || now.width == 0 || now.height == 0 {
        return last;
    }
    if now.maximized {
        return last.map(|saved| Saved {
            maximized: true,
            ..saved
        });
    }
    Some(Saved {
        x: now.x,
        y: now.y,
        width: now.width,
        height: now.height,
        scale: now.scale,
        maximized: false,
    })
}

fn scaled(value: u32, from: f64, to: f64) -> u32 {
    if from > 0.0 && to > 0.0 {
        (value as f64 * to / from).round() as u32
    } else {
        value
    }
}

fn overlap(a: (i64, i64, i64, i64), b: (i64, i64, i64, i64)) -> i64 {
    let w = (a.0 + a.2).min(b.0 + b.2) - a.0.max(b.0);
    let h = (a.1 + a.3).min(b.1 + b.3) - a.1.max(b.1);
    if w > 0 && h > 0 { w * h } else { 0 }
}

/// Where to put the window saved as `saved`. `displays` are the work areas, the primary display first; `frame` is the
/// window's outer size minus its content size (title bar, borders and, on Windows, the menu bar) measured at
/// `frame_scale`. The window goes on the display it overlaps most, or centred on the primary display when it overlaps
/// none (the display it was on is gone); its content is at least the minimum size and the whole window fits in that
/// display's work area (the work area wins when both cannot hold); and it is moved inside that work area.
pub fn place(
    saved: &Saved,
    displays: &[Area],
    frame: (u32, u32),
    frame_scale: f64,
    limits: &Limits,
) -> Option<Placement> {
    let primary = displays.first()?;
    let frame_at = |scale: f64| {
        (
            scaled(frame.0, frame_scale, scale),
            scaled(frame.1, frame_scale, scale),
        )
    };
    let saved_frame = frame_at(saved.scale);
    let outer = (
        saved.x as i64,
        saved.y as i64,
        (saved.width + saved_frame.0) as i64,
        (saved.height + saved_frame.1) as i64,
    );
    let area_rect = |a: &Area| (a.x as i64, a.y as i64, a.width as i64, a.height as i64);
    let best = displays
        .iter()
        .map(|area| (overlap(outer, area_rect(area)), area))
        .max_by_key(|(shared, _)| *shared)
        .filter(|(shared, _)| *shared > 0)
        .map(|(_, area)| area);
    let area = best.unwrap_or(primary);
    let (frame_w, frame_h) = frame_at(area.scale);
    let fit = |size: u32, min: f64, room: u32, frame: u32| {
        let max = room.saturating_sub(frame).max(1);
        let min = ((min * area.scale).round() as u32).min(max);
        scaled(size, saved.scale, area.scale).clamp(min, max)
    };
    let width = fit(saved.width, limits.min.0, area.width, frame_w);
    let height = fit(saved.height, limits.min.1, area.height, frame_h);
    let (outer_w, outer_h) = ((width + frame_w) as i64, (height + frame_h) as i64);
    let inside = |at: i64, start: i32, room: u32, size: i64| {
        at.clamp(
            start as i64,
            (start as i64 + room as i64 - size).max(start as i64),
        )
    };
    let (x, y) = if best.is_some() {
        (
            inside(saved.x as i64, area.x, area.width, outer_w),
            inside(saved.y as i64, area.y, area.height, outer_h),
        )
    } else {
        (
            area.x as i64 + (area.width as i64 - outer_w).max(0) / 2,
            area.y as i64 + (area.height as i64 - outer_h).max(0) / 2,
        )
    };
    Some(Placement {
        x: x as i32,
        y: y as i32,
        width,
        height,
        scale: area.scale,
        maximized: saved.maximized,
    })
}

/// The main window's entry in tauri-plugin-window-state's `.window-state.json`, which earlier versions wrote.
#[derive(Clone, Copy, Debug, Deserialize)]
pub struct Old {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    #[serde(default)]
    pub maximized: bool,
}

/// What earlier versions saved, as this version saves it. On Windows their saved height lost a menu bar's height on
/// every launch, so it cannot be trusted: a window shorter than the default height opens at the default height (the
/// work area still limits it). Elsewhere it was right and is kept. `place` then clamps both as usual.
pub fn migrate(old: Old, displays: &[Area], limits: &Limits, shrank: bool) -> Option<Saved> {
    let scale = displays
        .iter()
        .find(|a| {
            (a.x as i64..a.x as i64 + a.width as i64).contains(&(old.x as i64))
                && (a.y as i64..a.y as i64 + a.height as i64).contains(&(old.y as i64))
        })
        .or(displays.first())?
        .scale;
    let height = if shrank {
        old.height.max((limits.default.1 * scale).round() as u32)
    } else {
        old.height
    };
    Some(Saved {
        x: old.x,
        y: old.y,
        width: old.width,
        height,
        scale,
        maximized: old.maximized,
    })
}

#[cfg(desktop)]
pub use runtime::{plugin, restore};

#[cfg(desktop)]
mod runtime {
    use super::*;
    use std::path::PathBuf;
    use std::sync::Mutex;
    use tauri::{
        AppHandle, Manager, PhysicalPosition, PhysicalSize, RunEvent, Runtime, WebviewWindow,
        Window, WindowEvent,
        plugin::{Builder, TauriPlugin},
    };

    const LABEL: &str = "main";
    const FILE: &str = "window-bounds.json";
    const OLD_FILE: &str = ".window-state.json";

    /// The main window's last normal bounds, kept up to date while it moves and resizes, written when it closes or
    /// the app quits.
    struct Tracked(Mutex<Option<Saved>>);

    fn path<R: Runtime>(app: &AppHandle<R>, name: &str) -> Option<PathBuf> {
        app.path().app_config_dir().ok().map(|dir| dir.join(name))
    }

    fn limits<R: Runtime>(app: &AppHandle<R>) -> Limits {
        let config = app.config().app.windows.iter().find(|w| w.label == LABEL);
        Limits {
            min: (
                config.and_then(|w| w.min_width).unwrap_or(360.0),
                config.and_then(|w| w.min_height).unwrap_or(560.0),
            ),
            default: (
                config.map_or(1440.0, |w| w.width),
                config.map_or(960.0, |w| w.height),
            ),
        }
    }

    fn displays<R: Runtime>(window: &WebviewWindow<R>) -> Vec<Area> {
        let area = |m: &tauri::Monitor| {
            let work = m.work_area();
            Area {
                x: work.position.x,
                y: work.position.y,
                width: work.size.width,
                height: work.size.height,
                scale: m.scale_factor(),
            }
        };
        let primary = window.primary_monitor().ok().flatten();
        let mut all: Vec<Area> = window
            .available_monitors()
            .unwrap_or_default()
            .iter()
            .map(area)
            .collect();
        if let Some(primary) = primary.as_ref().map(area) {
            all.retain(|a| *a != primary);
            all.insert(0, primary);
        }
        all
    }

    fn saved<R: Runtime>(
        app: &AppHandle<R>,
        window: &WebviewWindow<R>,
        limits: &Limits,
    ) -> Option<Saved> {
        if let Some(saved) = path(app, FILE)
            .and_then(|file| std::fs::read(file).ok())
            .and_then(|bytes| serde_json::from_slice::<Saved>(&bytes).ok())
        {
            return Some(saved);
        }
        let old: serde_json::Value =
            serde_json::from_slice(&std::fs::read(path(app, OLD_FILE)?).ok()?).ok()?;
        let old: Old = serde_json::from_value(old.get(LABEL)?.clone()).ok()?;
        migrate(old, &displays(window), limits, cfg!(windows))
    }

    fn now<R: Runtime>(window: &Window<R>) -> Option<Observed> {
        let position = window.outer_position().ok()?;
        let size = window.inner_size().ok()?;
        let (minimized, maximized) = shown_as(window);
        Some(Observed {
            x: position.x,
            y: position.y,
            width: size.width,
            height: size.height,
            scale: window.scale_factor().ok()?,
            minimized,
            maximized,
        })
    }

    /// Whether the window is minimized or maximized now. On Windows, tao updates its own maximized flag only when the
    /// size message arrives, after the move a maximize makes: asked then, it says "not maximized" and the maximized
    /// bounds would be kept as the normal ones. Windows itself already knows.
    fn shown_as<R: Runtime>(window: &Window<R>) -> (bool, bool) {
        #[cfg(windows)]
        if let Ok(hwnd) = window.hwnd() {
            #[link(name = "user32")]
            unsafe extern "system" {
                fn IsIconic(hwnd: *mut std::ffi::c_void) -> i32;
                fn IsZoomed(hwnd: *mut std::ffi::c_void) -> i32;
            }
            let hwnd = hwnd.0 as *mut std::ffi::c_void;
            // SAFETY: plain queries on the window's own handle, which lives as long as `window`.
            return unsafe { (IsIconic(hwnd) != 0, IsZoomed(hwnd) != 0) };
        }
        (
            window.is_minimized().unwrap_or(false),
            window.is_maximized().unwrap_or(false),
        )
    }

    fn track<R: Runtime>(window: &Window<R>) {
        if let Some(now) = now(window) {
            let tracked = window.state::<Tracked>();
            let mut last = tracked.0.lock().unwrap();
            *last = observe(*last, now);
        }
    }

    fn save<R: Runtime>(app: &AppHandle<R>) {
        let Some(saved) = *app.state::<Tracked>().0.lock().unwrap() else {
            return;
        };
        let Some(file) = path(app, FILE) else { return };
        if let Some(dir) = file.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(bytes) = serde_json::to_vec_pretty(&saved) {
            let _ = std::fs::write(file, bytes);
        }
    }

    /// Keeps the main window's bounds and writes them when it closes or the app quits.
    pub fn plugin<R: Runtime>() -> TauriPlugin<R> {
        Builder::new("window-bounds")
            .setup(|app, _| {
                app.manage(Tracked(Mutex::new(None)));
                Ok(())
            })
            .on_window_ready(|window| {
                if window.label() != LABEL {
                    return;
                }
                let main = window.clone();
                window.on_window_event(move |event| match event {
                    WindowEvent::Moved(_)
                    | WindowEvent::Resized(_)
                    | WindowEvent::ScaleFactorChanged { .. } => track(&main),
                    WindowEvent::CloseRequested { .. } => {
                        track(&main);
                        save(main.app_handle());
                    }
                    _ => {}
                });
            })
            .on_event(|app, event| {
                if let RunEvent::Exit = event {
                    save(app);
                }
            })
            .build()
    }

    /// Puts the main window where it was last left. Call once its menu is set: on Windows the menu bar is part of the
    /// window's frame, and a window sized before it has one loses the menu bar's height from its content.
    pub fn restore<R: Runtime>(app: &AppHandle<R>) {
        let Some(window) = app.get_webview_window(LABEL) else {
            return;
        };
        let limits = limits(app);
        let Some(saved) = saved(app, &window, &limits) else {
            return;
        };
        let (Ok(outer), Ok(inner), Ok(scale)) = (
            window.outer_size(),
            window.inner_size(),
            window.scale_factor(),
        ) else {
            return;
        };
        let frame = (
            outer.width.saturating_sub(inner.width),
            outer.height.saturating_sub(inner.height),
        );
        let Some(placed) = place(&saved, &displays(&window), frame, scale, &limits) else {
            return;
        };
        let _ = window.set_position(PhysicalPosition::new(placed.x, placed.y));
        let wanted = PhysicalSize::new(placed.width, placed.height);
        let _ = window.set_size(wanted);
        // Windows sizes the frame for a one-line menu bar: if the bar wraps, or the frame is otherwise not what it
        // assumed, the content comes out smaller than asked. Ask again for the difference, once.
        #[cfg(windows)]
        if let Ok(got) = window.inner_size() {
            if got != wanted {
                let _ = window.set_size(PhysicalSize::new(
                    (wanted.width * 2).saturating_sub(got.width),
                    (wanted.height * 2).saturating_sub(got.height),
                ));
            }
        }
        *app.state::<Tracked>().0.lock().unwrap() = Some(Saved {
            x: placed.x,
            y: placed.y,
            width: placed.width,
            height: placed.height,
            scale: placed.scale,
            maximized: false,
        });
        track(&window.as_ref().window());
        if placed.maximized {
            let _ = window.maximize();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIMITS: Limits = Limits {
        min: (360.0, 560.0),
        default: (1440.0, 960.0),
    };
    /// The Windows 11 VM's display at 200 %: 3600 × 2036, taskbar 96 px.
    const VM: Area = Area {
        x: 0,
        y: 0,
        width: 3600,
        height: 1940,
        scale: 2.0,
    };
    /// Its window frame with the menu bar: borders 26 px wide, title bar, borders and menu bar 110 px high.
    const FRAME: (u32, u32) = (26, 110);

    fn saved(x: i32, y: i32, width: u32, height: u32) -> Saved {
        Saved {
            x,
            y,
            width,
            height,
            scale: 2.0,
            maximized: false,
        }
    }

    fn normal(p: &Placement) -> Observed {
        Observed {
            x: p.x,
            y: p.y,
            width: p.width,
            height: p.height,
            scale: p.scale,
            minimized: false,
            maximized: false,
        }
    }

    /// The window as launched N times: placed from what was saved, then closed as it is, saved again.
    fn relaunch(mut state: Saved, displays: &[Area], times: usize) -> Vec<Saved> {
        (0..times)
            .map(|_| {
                let placed = place(&state, displays, FRAME, 2.0, &LIMITS).unwrap();
                state = observe(Some(state), normal(&placed)).unwrap();
                state
            })
            .collect()
    }

    #[test]
    fn bounds_are_the_same_after_every_launch() {
        let first = saved(245, 45, 2160, 1500);
        for state in relaunch(first, &[VM], 20) {
            assert_eq!(state, first);
        }
    }

    /// One launch on Windows as the VM showed it: the frame without the menu bar is 26 × 71 px and the menu bar 39 px.
    /// The window's outer size is set from the content size and the frame known when it is placed; the content is
    /// what remains once the menu bar is in the frame; that content is what is saved on close.
    fn windows_launch(state: Saved, menu_when_placed: bool) -> Saved {
        const MENU: u32 = 39;
        let frame_then = if menu_when_placed {
            FRAME
        } else {
            (FRAME.0, FRAME.1 - MENU)
        };
        let placed = place(&state, &[VM], frame_then, 2.0, &LIMITS).unwrap();
        let outer_height = placed.height + frame_then.1;
        observe(
            Some(state),
            Observed {
                height: outer_height - FRAME.1,
                ..normal(&placed)
            },
        )
        .unwrap()
    }

    #[test]
    fn a_window_placed_before_its_menu_bar_shrank_and_one_placed_after_does_not() {
        let mut before = saved(245, 45, 2160, 1500);
        let mut after = before;
        for _ in 0..5 {
            before = windows_launch(before, false);
            after = windows_launch(after, true);
        }
        assert_eq!(
            before.height,
            1500 - 5 * 39,
            "what 0.2.3 did, with the minimum size now holding the floor"
        );
        assert_eq!(after, saved(245, 45, 2160, 1500));
        for _ in 0..20 {
            before = windows_launch(before, false);
        }
        assert_eq!(
            before.height,
            1120 - 39,
            "even then, never below the minimum by more than the menu bar"
        );
    }

    #[test]
    fn a_shrunk_window_comes_back_to_at_least_the_minimum_size() {
        let placed = place(&saved(245, 45, 2160, 9), &[VM], FRAME, 2.0, &LIMITS).unwrap();
        assert_eq!(
            (placed.width, placed.height),
            (2160, 1120),
            "560 logical px at 200 %"
        );
        let tiny = place(&saved(245, 45, 1, 1), &[VM], FRAME, 2.0, &LIMITS).unwrap();
        assert_eq!((tiny.width, tiny.height), (720, 1120));
        // And stays there.
        assert!(
            relaunch(saved(245, 45, 2160, 9), &[VM], 5)
                .iter()
                .all(|s| s.height == 1120)
        );
    }

    #[test]
    fn earlier_versions_shrunk_windows_heal_on_windows() {
        let old = Old {
            x: 245,
            y: 45,
            width: 2160,
            height: 9,
            maximized: false,
        };
        let healed = migrate(old, &[VM], &LIMITS, true).unwrap();
        assert_eq!(
            (healed.width, healed.height, healed.scale),
            (2160, 1920, 2.0)
        );
        // The default height does not fit the VM's work area with the frame: the work area wins.
        let placed = place(&healed, &[VM], FRAME, 2.0, &LIMITS).unwrap();
        assert_eq!(
            (placed.x, placed.y, placed.width, placed.height),
            (245, 0, 2160, 1830)
        );
        assert!(
            relaunch(healed, &[VM], 5)
                .iter()
                .all(|s| s.height == 1830 && s.y == 0)
        );
        // Where the old height was right (macOS, Linux), it is kept.
        let kept = migrate(Old { height: 700, ..old }, &[VM], &LIMITS, false).unwrap();
        assert_eq!(kept.height, 700);
        // A tall enough old window keeps its height on Windows too.
        assert_eq!(
            migrate(
                Old {
                    height: 2000,
                    ..old
                },
                &[VM],
                &LIMITS,
                true
            )
            .unwrap()
            .height,
            2000
        );
    }

    #[test]
    fn a_window_larger_than_the_display_is_made_to_fit() {
        let placed = place(&saved(-500, -300, 9000, 9000), &[VM], FRAME, 2.0, &LIMITS).unwrap();
        assert_eq!(
            (placed.x, placed.y, placed.width, placed.height),
            (0, 0, 3574, 1830)
        );
    }

    #[test]
    fn a_window_off_the_edge_is_moved_back_on() {
        let placed = place(&saved(3400, 1800, 1000, 1200), &[VM], FRAME, 2.0, &LIMITS).unwrap();
        assert_eq!((placed.x, placed.y), (3600 - 1026, 1940 - 1310));
    }

    #[test]
    fn a_window_on_a_disconnected_display_opens_centred_on_the_primary_one() {
        let laptop = Area {
            x: 0,
            y: 0,
            width: 1512,
            height: 944,
            scale: 1.0,
        };
        let gone = saved(4000, 200, 2400, 1600);
        let placed = place(&gone, &[laptop], (16, 70), 2.0, &LIMITS).unwrap();
        // Measured at 200 %, placed at 100 %: half the pixels, within the laptop's work area.
        assert_eq!((placed.width, placed.height), (1200, 800));
        assert_eq!(placed.x, (1512 - (1200 + 8)) / 2);
        assert_eq!(placed.y, (944 - (800 + 35)) / 2);
    }

    #[test]
    fn a_window_on_a_second_display_stays_there() {
        let right = Area {
            x: 3600,
            y: 0,
            width: 1920,
            height: 1040,
            scale: 1.0,
        };
        let there = Saved {
            x: 3800,
            y: 100,
            width: 1200,
            height: 800,
            scale: 1.0,
            maximized: false,
        };
        let placed = place(&there, &[VM, right], FRAME, 2.0, &LIMITS).unwrap();
        assert_eq!(
            (
                placed.x,
                placed.y,
                placed.width,
                placed.height,
                placed.scale
            ),
            (3800, 100, 1200, 800, 1.0)
        );
    }

    #[test]
    fn minimized_is_never_saved_and_maximized_is_kept_apart() {
        let normal = saved(245, 45, 2160, 1300);
        let minimized = Observed {
            x: -32000,
            y: -32000,
            width: 0,
            height: 0,
            scale: 2.0,
            minimized: true,
            maximized: false,
        };
        assert_eq!(observe(Some(normal), minimized), Some(normal));
        let maximized = Observed {
            x: -8,
            y: -8,
            width: 3600,
            height: 1830,
            scale: 2.0,
            minimized: false,
            maximized: true,
        };
        let both = observe(Some(normal), maximized).unwrap();
        assert_eq!(
            both,
            Saved {
                maximized: true,
                ..normal
            }
        );
        let placed = place(&both, &[VM], FRAME, 2.0, &LIMITS).unwrap();
        assert!(placed.maximized);
        assert_eq!(
            (placed.x, placed.y, placed.width, placed.height),
            (245, 45, 2160, 1300)
        );
        // Un-maximized and closed: a normal window at its normal bounds again.
        assert_eq!(observe(Some(both), normal_of(&normal)), Some(normal));
    }

    fn normal_of(s: &Saved) -> Observed {
        Observed {
            x: s.x,
            y: s.y,
            width: s.width,
            height: s.height,
            scale: s.scale,
            minimized: false,
            maximized: false,
        }
    }

    #[test]
    fn no_display_known_leaves_the_window_as_created() {
        assert_eq!(
            place(&saved(0, 0, 800, 600), &[], FRAME, 2.0, &LIMITS),
            None
        );
    }
}

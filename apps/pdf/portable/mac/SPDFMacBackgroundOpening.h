#pragma once
// Opening without taking the focus.
//
// Someone typing in another app must not have their keystrokes land in ShenzhenPDF because a tool opened a document:
// `szpdf open` (background unless --front) and `open -g` leave ShenzhenPDF where it is.
//
// - A document opened from outside (Finder, `open`, a link) asks to come forward the way macOS 14 wants it asked:
//   -[NSApplication activate], which the system grants when whoever opened the document gave its turn away (Finder,
//   the Dock, `open` without -g) and refuses otherwise (`open -g`). The window comes to the front when the app does,
//   and stays where it was when it doesn't. -activateIgnoringOtherApps: is used only before macOS 14.
// - A launch by `szpdf open` without --front (SPDF_BACKGROUND_LAUNCH=1 in its environment) puts its window behind the
//   other apps' windows and does not ask to come forward at all.
#import <AppKit/AppKit.h>

// The launch's window as soon as it exists (window-first launch): ordered in front, or behind for a background launch.
void spdf_mac_order_launch_window(NSWindow* window);
// The launch's first window on screen: in front and asking for the focus, or behind for a background launch.
// `activate` is NO for a window restored in a process of its own (the focused window's process asks).
void spdf_mac_show_launch_window(NSWindow* window, BOOL activate);
// A document opened from outside lands in `window`: see above.
void spdf_mac_show_window_for_external_open(NSWindow* window);
// The same, for a window asked to the front explicitly (`szpdf open --front`): the window and the app come forward.
void spdf_mac_bring_window_to_front(NSWindow* window);
// A window opened in the background: left where it is when already showing, else put behind every other window.
void spdf_mac_show_window_in_background(NSWindow* window);

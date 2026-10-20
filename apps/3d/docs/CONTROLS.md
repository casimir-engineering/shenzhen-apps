# Controls

The viewport uses one automatic control scheme:

| Input                                                                 | Action                                             |
| --------------------------------------------------------------------- | -------------------------------------------------- |
| Left-button drag                                                      | Pan                                                |
| Middle-button drag                                                    | Pan                                                |
| Right-button drag, or two-finger click-drag                           | Orbit around the current view center               |
| Command (Mac) or Ctrl + right-button drag, or + two-finger click-drag | Pan                                                |
| Two-finger trackpad swipe up or down                                  | Zoom                                               |
| Command (Mac) or Ctrl + two-finger swipe                              | Pan in any direction                               |
| Trackpad pinch                                                        | Zoom                                               |
| Mouse wheel                                                           | Zoom                                               |
| Single click                                                          | Pick for the current measurement or selection tool |

Command or Ctrl is read when the drag starts. Pressing or releasing it partway through a drag does not change what that drag does, so you can let go of the key and keep panning. On a Mac, Ctrl + left-click arrives as a right click, so Ctrl + left-drag pans as well; the context menu does not open during these drags. Mouse picking and selection (a click without dragging), measurement picks and touchscreen gestures are unaffected.

Zoom stays centered in the view, whether it comes from a swipe, a pinch or the wheel. A swipe zooms in proportion to how far and fast you swipe, in the same direction as the mouse wheel; sideways movement is ignored. If you let go of Command or Ctrl before a pan swipe finishes, it keeps panning to the end instead of switching to zoom. Panning moves the view center, and subsequent orbiting uses that center. Double-click does not reposition it.

Touchscreens use one finger to orbit and two fingers to pan and pinch. In 2D drawings, orbit gestures pan. Previous input-device, navigation-preset, and reverse-wheel preferences are ignored; no device selection is required.

The Chromium macOS app also supports two-finger trackpad twist: it rolls the view around the current sight line. The model, measurement coordinates, view center and zoom stay unchanged. Twist applies only over the canvas; view presets reset the orientation. This uses native AppKit rotation events and is not available through the browser fallback or lightweight Tauri shell. Android and iOS retain one-finger orbit and two-finger pan/pinch.

The macOS desktop app distinguishes trackpad gestures from mouse wheels using native scroll-event phases when its AppKit input bridge is available. The browser version cannot access those phases. It uses wheel tick, precision, horizontal-scroll, and momentum information as a fallback; some smooth mouse wheels and vertical trackpad swipes produce indistinguishable browser events and can be misclassified. Pinch still zooms, Command or Ctrl + swipe pans, and left/middle drag always pans. In the browser, a smooth mouse wheel that looks like a swipe pans instead of zooming when Command or Ctrl is held.

The fixed mapping and browser fallback are checked by `npm run test:viewer` and `scripts/perf/check-measurement-navigation.mjs` (swipe zoom, Command/Ctrl pan, pinch, wheel, drag/modifier combinations, centered navigation, touch gestures and measurement overlays). These browser runs do not validate native AppKit event delivery; that bridge is tested separately.

## View shortcuts

| Shortcut    | Action                                           |
| ----------- | ------------------------------------------------ |
| Shift+1–7   | Front, back, left, right, top, bottom, isometric |
| F / Shift+F | Fit model / zoom to selection                    |
| N           | Normal to a selected planar face; repeat to flip |
| Shift+X     | Toggle section                                   |
| Y / Shift+Y | Hide selected or hovered part / show all         |
| C           | Add anchored comment                             |
| P / E       | Point / feature measurement                      |
| Escape      | Clear selection and current measurement          |

View shortcuts are inactive while typing or while a dialog is open. Measurements retain their two/three-point picking workflow; this viewer does not implement CAD editing or window/crossing box selection.

## App shortcuts

These use ⌘ on a Mac and Ctrl on Windows and Linux. ⌘K and ⌘J also work while typing in a field (⌘J closes Friends
from its own search field), but not while a dialog is open.

| Shortcut    | Action                                                                                 |
| ----------- | -------------------------------------------------------------------------------------- |
| ⌘O / Ctrl+O | Open a file                                                                            |
| ⌘S / Ctrl+S | Share the commented project                                                            |
| ⌘F / Ctrl+F | Search the assembly                                                                    |
| ⌘K / Ctrl+K | Find a command: type part of its name, then Return                                     |
| ⌘J / Ctrl+J | Open or close Friends, with the search field ready (only where Friends runs and is on) |

The command palette (⌘K / Ctrl+K) lists Open file…, Share commented project, Search assembly, Fit model, Settings…
and Help & shortcuts, and, while Friends is on, Open Friends, Add by ID…, Make myself visible and Friends Settings….
Open Friends is also found by "friend", "nearby", "add by id" and "chat". The Mac app's View menu has Friends (Beta), ⌘J,
and the Friends button's tooltip shows the shortcut.

⌘J and ⌘K were not used before (2026-10-20). Browsers use Ctrl+J for Downloads and Ctrl+K for the search bar; the web
build has no Friends and leaves Ctrl+J to the browser, and Ctrl+K opens the palette there too. In the Windows and Linux
apps Ctrl+J is Friends' while Friends is on.

## Selecting parts

Click a part in the assembly list to select it. The view moves so the part is in the center, and the zoom stays the same. Press Shift+F to zoom to it.

In Part mode, click a part in the view to select it. Its row is selected in the assembly list, which opens the groups above it and scrolls to it. The view does not move.

Selected parts are tinted and outlined. Where other parts cover them, the outline is dashed. When a selected part is too small to see at the current zoom, a ring shows where it is.

To clear the selection, press Escape, click an empty area of the view in Part mode, or ⌘-click (Ctrl-click on Windows and Linux) the selected row.

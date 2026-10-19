# Portable Frontend Notes

Shenzhen PDF keeps document handling behind a small portable core and lets each
desktop platform provide a native frontend. The goal is feature parity without
forcing macOS or Linux through a Windows UI abstraction.

## Shared Core Boundary

The `portable/core` API owns the platform-neutral PDF work:

- open/close documents from UTF-8 paths;
- page count, title, page sizes, and rotation;
- RGBA page rendering through MuPDF;
- text extraction, text search, and hit rectangles;
- outlines, markup comments, and annotation metadata;
- save-back operations needed by OCR, rotation, comments, and translation.

Anything that depends on a platform event loop, menu system, window handle,
file picker, shell integration, printing panel, or text input widget stays in
the frontend.

## Native Frontends

macOS uses AppKit:

- `NSApplication`, `NSWindow`, `NSView`, native menus, sheets, and panels;
- AppKit event handling for trackpad, mouse, keyboard, tab dragging, and
  presentation mode;
- Apple-style app bundle, Info.plist, Developer ID signing, notarization, and DMG packaging.

Linux uses GTK:

- `GtkApplication`, GTK widgets/signals, and GLib worker dispatch;
- XDG-ish config paths and desktop file metadata;
- GTK file dialogs, shell/browser handoff, and Linux package metadata.

Windows remains the C++/Win32 target until a dedicated portable Windows frontend
is split out. Keep required attribution intact while that code is retained.

## Portability Rules

- Keep Windows, AppKit, and GTK types out of `portable/core`.
- Store user data in readable JSON files with matching schemas across platforms.
- Render the current page first, then fill visible-neighbor pages in background
  workers.
- Preserve the same keyboard model and document state fields on every platform.
- Add native integrations only behind platform-specific code paths.

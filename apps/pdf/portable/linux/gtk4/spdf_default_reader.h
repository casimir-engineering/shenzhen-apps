// spdf_default_reader.c — default-PDF-reader registration (Wave D).
//
// Ported semantics (Mac, SPDFMacDefaultReader.mm + ShenzhenPDFMac.mm
// promptToMakeDefaultPDFReader*): a one-time prompt offers one-click
// registration; "Not Now" (or any dismissal) persists forever via the
// settings key `defaultReaderPromptDismissed` (same key name as the Mac
// writer, spdf_state.c); already-default at prompt time also persists the
// dismissal quietly. A hamburger menu item (win.make-default, registered in
// the spdf_shortcuts.c table) always works regardless of the dismissal.
//
// Linux mechanics: the default is the xdg-mime handler for application/pdf —
// queried with `xdg-mime query default application/pdf` and set with
// `xdg-mime default shenzhenpdf.desktop application/pdf` (GSubprocess, async,
// result verified by re-query). When shenzhenpdf.desktop is not installed in
// any XDG applications dir (source builds), the prompt is skipped silently;
// the menu action explains instead.
//
// The pure half (top of spdf_default_reader.c) compiles glib-only under
// SPDF_DEFAULT_READER_TESTING, same pattern as spdf_watcher.c.
#pragma once

#ifndef SPDF_DEFAULT_READER_TESTING
#include "spdf_window.h"

G_BEGIN_DECLS

// Registers win.make-default on the window (menu item "Set as Default PDF
// Reader"; name listed in the spdf_shortcuts.c table).
void spdf_default_reader_install(SpdfWindow* win);

// First-document-open hook (spdf_window_open_path): schedules the one-time
// prompt check in a low-priority idle — never on the open/launch path
// itself. Cheap no-op after the first call and when the settings key
// defaultReaderPromptDismissed is set.
void spdf_default_reader_note_document_opened(SpdfWindow* win);

G_END_DECLS
#else
#include <glib.h>
#endif

G_BEGIN_DECLS

// ---------------------------------------------------------------------------
// Pure logic (glib only), exercised by tests/default_reader_test.c.

#define SPDF_DEFAULT_READER_DESKTOP_ID "shenzhenpdf.desktop"

// Prompt decision table (Mac promptToMakeDefaultPDFReaderIfNeededOnLaunch
// gates, plus the Linux source-build gate): prompt iff the desktop entry is
// installed, we are not already the default, the user never dismissed it and
// this process has not prompted yet.
gboolean spdf_default_reader_should_prompt(gboolean desktop_installed, gboolean is_default,
                                           gboolean prompt_dismissed, gboolean already_prompted);

// TRUE when `xdg-mime query default application/pdf` output names us
// (whitespace-trimmed exact match against SPDF_DEFAULT_READER_DESKTOP_ID).
gboolean spdf_default_reader_output_is_us(const char* xdg_mime_output);

G_END_DECLS

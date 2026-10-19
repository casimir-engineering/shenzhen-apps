// spdf_resident.c — resident instant-launch support (Wave D).
//
// The owner's two-track launch strategy (portable/docs/gtk4-parity-spec.md
// "Launch speed") makes GApplication uniqueness the instant path: while a
// primary instance is alive, `shenzhenpdf file.pdf` is a ~30 ms D-Bus forward
// instead of a ~285 ms cold GTK4 init. This module owns the login autostart
// entry that keeps such a primary alive from login on:
//
//   ~/.config/autostart/shenzhenpdf-resident.desktop  ->  Exec=<bin> --resident
//
// installed/removed in lock-step with the `instantLaunchResident` setting
// (spdf_state.c; default on). The hold/release of the GApplication itself
// lives in spdf_app.c — this module is only the autostart file plus the pure
// content/staleness rules behind it (tests/resident_test.c).
//
// The pure half (top of spdf_resident.c) compiles glib-only under
// SPDF_RESIDENT_TESTING, same pattern as spdf_watcher.c.
#pragma once

#ifndef SPDF_RESIDENT_TESTING
#include "spdf_internal.h"

G_BEGIN_DECLS

// Reconcile the autostart file with the setting: when enabled, write the
// entry iff it is missing or its Exec line no longer launches this binary
// (moved user-local install, changed packaging); when disabled, delete it.
// One stat + at most one small read/write — callers still keep it off the
// hot launch path (idle) out of principle.
void spdf_resident_sync_autostart(gboolean enabled);

G_END_DECLS
#else
#include <glib.h>
#endif

G_BEGIN_DECLS

// ---------------------------------------------------------------------------
// Pure logic (glib only), exercised by tests/resident_test.c.

// Installed binary name (deb package) and the autostart entry filename.
#define SPDF_RESIDENT_BINARY_NAME "shenzhenpdf"
#define SPDF_RESIDENT_AUTOSTART_FILE "shenzhenpdf-resident.desktop"

// Exec program value for the autostart entry: the bare installed name when
// the PATH-resolved SPDF_RESIDENT_BINARY_NAME is this very binary (deb
// installs keep working across package upgrades that replace the file), else
// the argv0/proc-resolved absolute path, shell-quoted (user-local installs
// that are not in PATH). Either argument may be NULL; NULL self_path falls
// back to the bare name (best effort — /proc may be unreadable).
char* spdf_resident_autostart_exec(const char* self_path, const char* path_resolved);

// Full .desktop payload for exec_value. Hidden=false and
// X-GNOME-Autostart-enabled=true are written explicitly (some session
// managers persist toggles by rewriting exactly these keys); OnlyShowIn is
// deliberately absent so every desktop runs the entry.
char* spdf_resident_autostart_content(const char* exec_value);

// TRUE when existing_content (NULL/empty = missing file) has no Exec= line
// exactly matching what spdf_resident_autostart_content(exec_value) would
// write — i.e. the file must be (re)written. Only Exec decides staleness:
// users may edit cosmetic keys without the app fighting them.
gboolean spdf_resident_autostart_stale(const char* existing_content, const char* exec_value);

G_END_DECLS

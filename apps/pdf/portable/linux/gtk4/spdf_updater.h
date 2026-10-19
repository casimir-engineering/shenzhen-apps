// spdf_updater.h — auto-updater for the GTK4 frontend (Linux port of
// portable/mac/SPDFUpdater.mm). GitHub Releases check on a daily cadence off
// the launch path, minisign (Ed25519, OpenSSL) release verification against
// the pinned pubkey from portable/linux/pkg/minisign.pub, install via
// pkexec dpkg -i (system deb installs) or an atomic binary swap (user-local
// installs under $HOME), health check + rollback bookkeeping on next launch.
//
// Everything above the transport/UI layer is pure and testable offline:
// version compare, daily-gate delay, minisign parse/verify, GitHub release
// JSON parse, availability decision, release-notes formatting, update-store
// (update.json) parse/serialize. tests/updater_test.c compiles this module
// standalone with SPDF_UPDATER_TESTING (glib + openssl only, no GTK).
#pragma once

#include "spdf_update_version.h"

#ifdef SPDF_UPDATER_TESTING
#include <glib.h>
#else
#include "spdf_app.h"
#endif

G_BEGIN_DECLS

// ---------------------------------------------------------------------------
// Minisign (https://jedisct1.github.io/minisign/) — pure parse + verify.
// Both signature modes are supported:
//   "Ed" — legacy: Ed25519 over the raw file content.
//   "ED" — prehashed (minisign >= 0.6 default): Ed25519 over BLAKE2b-512(file).
// The keyid in the signature must match the pinned pubkey's keyid, and the
// global signature (over sig || trusted comment), when present, must verify.

typedef struct {
    guint8 key_id[8];
    guint8 key[32]; // raw Ed25519 public key
} SpdfMinisignKey;

typedef struct {
    gboolean prehashed; // "ED" (BLAKE2b-512 prehash) vs "Ed" (raw)
    guint8 key_id[8];
    guint8 sig[64];
    char* trusted_comment; // owned; NULL when absent
    guint8 global_sig[64];
    gboolean has_global_sig;
} SpdfMinisignSig;

// Parse the base64 key line of a minisign public key. `text` may be the full
// two-line .pub file (untrusted comment + key line) or just the key line.
gboolean spdf_minisign_parse_pubkey(const char* text, SpdfMinisignKey* out, char** error);
// Parse a .minisig file (untrusted comment, sig, trusted comment, global sig).
gboolean spdf_minisign_parse_sig(const char* text, SpdfMinisignSig* out, char** error);
void spdf_minisign_sig_clear(SpdfMinisignSig* sig);
// Verify `data` against `sig` with `key` (keyid match + Ed25519 verify +
// global-signature verify when present). The ONLY trust boundary of the
// updater: nothing downloaded is installed unless this returns TRUE.
gboolean spdf_minisign_verify_buffer(const SpdfMinisignKey* key, const SpdfMinisignSig* sig, const guint8* data,
                                     gsize len, char** error);
// Convenience: read `path` fully and verify it against the .minisig text.
gboolean spdf_minisign_verify_file(const SpdfMinisignKey* key, const char* sig_text, const char* path, char** error);

// Daily-gate delay decision (pure; mirrors spdf_daily_check_delay).
// Returns -1 = never (disabled), 0 = due now, else seconds until due.
// Rolling 24h window; a backwards clock keeps the gate closed.
gint64 spdf_updater_daily_check_delay(gboolean auto_update_enabled, gboolean have_last_check, gint64 last_check_epoch,
                                      gint64 now_epoch);

// ---------------------------------------------------------------------------
// GitHub /releases/latest response parse (pure, structural — not fooled by
// braces/quotes inside the release body). Picks the asset named `asset_name`
// and its detached signature `<asset_name>.minisig`.
typedef struct {
    char* tag; // "tag_name"
    gboolean draft;
    gboolean prerelease;
    char* notes;       // "body", may be NULL
    char* asset_url;   // browser_download_url of `asset_name`, NULL if absent
    gint64 asset_size; // its "size", 0 if absent
    char* sig_url;     // browser_download_url of `<asset_name>.minisig`
} SpdfReleaseInfo;

gboolean spdf_updater_parse_release(const char* json, gssize len, const char* asset_name, SpdfReleaseInfo* out);
void spdf_release_info_clear(SpdfReleaseInfo* info);

// Update-available decision (pure; mirrors the Mac availability predicate):
// newer than running AND not below the highest-seen high-water mark AND has
// both payload and signature assets AND not draft/prerelease.
gboolean spdf_updater_release_available(const SpdfReleaseInfo* info, const char* running, const char* highest_seen);

// Release-notes plain-text formatter for the update prompt (pure; port of
// spdf_format_release_notes_for_alert): highlights above the first horizontal
// rule, markdown stripped, bullets to "• ", control/bidi characters removed,
// capped at 500 characters on a line boundary. Returns owned string ("" for
// NULL/empty input).
char* spdf_updater_format_notes(const char* body);

// ---------------------------------------------------------------------------
// update.json store (flat schema owned by this module, guarded by a flock on
// update.lock in the same config dir; settings.json keeps autoUpdateEnabled /
// skippedUpdateVersion, which belong to spdf_state.c).
typedef struct {
    gint64 last_check;   // "lastUpdateCheck" epoch seconds, 0 = never
    char* etag;          // "etag" of the last 200 response
    char* highest_seen;  // "highestVersionSeen" downgrade/replay high-water
    char* deferred_tag;  // "deferredTag" ("Later" snooze target)
    gint64 remind_after; // "remindAfter" epoch seconds
    char* pending_tag;   // "pendingTag" install awaiting the launch health check
    char* update_ok;     // "updateOk" last confirmed-healthy tag
    gint64 lease_pid;    // "leasePid"/"leaseTimestamp": single-driver liveness lease
    gint64 lease_ts;
} SpdfUpdateStore;

void spdf_update_store_parse(const char* json, gssize len, SpdfUpdateStore* out); // zeroes + fills
char* spdf_update_store_serialize(const SpdfUpdateStore* store);                  // owned JSON text
void spdf_update_store_clear(SpdfUpdateStore* store);

#ifndef SPDF_UPDATER_TESTING
// ---------------------------------------------------------------------------
// App wiring.

// Called from application startup. Never blocks launch: schedules the
// pending-update health check + first daily check a few seconds after the
// main loop settles, then re-arms an hourly cadence timer that consumes the
// flock'd 24h gate (autoUpdateEnabled is read live on every fire).
void spdf_updater_start(SpdfApp* app);

// "Check for Updates…" (hamburger menu). Bypasses the 24h gate, ignores
// skippedUpdateVersion and the "Later" snooze, and reports every outcome
// (update available / up to date / failure) in a dialog on `parent`.
void spdf_updater_check_interactive(SpdfApp* app, GtkWindow* parent);

// CLI flags, handled before g_application_run (no display needed):
//   --check-updates-now   force a check, print the result, exit
//   --install-update      check + download + verify + install, exit
//   --updater-health-probe exit 0 (used as the post-swap launch health probe)
// Returns the process exit status, or -1 when argv carries none of them.
int spdf_updater_handle_cli(int argc, char** argv);
#endif

G_END_DECLS

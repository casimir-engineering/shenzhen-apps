/* Shared helpers for friends-gtk-check: expectations, fixtures, temporary directories, a bounded main-loop pump and a
 * log watch that fails the suite on any GLib, GTK or libadwaita warning nobody expected.
 *
 * Every wait is bounded (at most a few seconds, never past 10 s), so a broken build fails instead of hanging. */

#ifndef SZFRIENDS_GTK_SUPPORT_H
#define SZFRIENDS_GTK_SUPPORT_H

#include "gtk/szfriends_gtk_link.h"
#include "gtk/szfriends_gtk_schema.h"

#include "client/fake/szfriends_fake_helper.h"

#include <stdio.h>

extern int szfg_failures;
extern const char *szfg_fixtures; /* portable/friends/fixtures */

#define EXPECT(condition, ...)                                   \
    do {                                                         \
        if (!(condition)) {                                      \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                        \
            fprintf(stderr, "\n");                               \
            ++szfg_failures;                                     \
        }                                                        \
    } while (0)

/* Counts warnings and criticals from every log domain; tests that provoke one on purpose say so first. */
void szfg_watch_logs(void);
void szfg_expect_warnings(gboolean expected);
int szfg_unexpected_warnings(void);

/* A fresh 0700 directory under the per-user temp dir, short enough for a socket path; removed with its contents. */
char *szfg_temp_dir(const char *label);
void szfg_remove_tree(const char *path);

/* A fixture file, relative to the fixtures directory, parsed; NULL (and a failure) when missing. */
JsonObject *szfg_fixture(const char *relative);
char *szfg_fixture_path(const char *relative);
/* Fixture names in a directory of the fixtures, sorted. */
GPtrArray *szfg_fixture_names(const char *directory);

/* Iterates the default main context until `done(data)` or `timeout_ms` passes; returns done's last answer. */
gboolean szfg_pump_until(gboolean (*done)(gpointer data), gpointer data, int timeout_ms);
void szfg_pump_for(int milliseconds);

/* Serializes a parsed struct back to JSON through its table, writing only the fields its presence mask holds, so the
 * result equals the JSON it came from when every field was understood. */
JsonNode *szfg_serialize(const SZFriendsGtkType *type, gconstpointer value);
gboolean szfg_json_equal(JsonNode *a, JsonNode *b, GString *where);

/* A link against the in-process fake helper on a fresh state directory (SZFRIENDS_STATE_DIR points at it). */
typedef struct {
    char *state;
    szfriends_fake_helper *fake;
    SZFriendsGtkLink *link;
    SZFriendsGtkHost host;
    SZFriendsGtkLinkState states[64]; /* every state the link reported, in order */
    guint n_states;
} SZFGHarness;

SZFGHarness *szfg_harness_new(const char *label, gboolean start_fake);
gboolean szfg_harness_start_fake(SZFGHarness *harness);
/* Starts the link and waits for READY. */
gboolean szfg_harness_ready(SZFGHarness *harness, int timeout_ms);
gboolean szfg_harness_wait_state(SZFGHarness *harness, SZFriendsGtkLinkState state, guint from, int timeout_ms);
void szfg_harness_free(SZFGHarness *harness);
/* Client frames the fake received of `type` whose top-level `key` equals `value` (any when key is NULL). */
guint szfg_fake_frames(SZFGHarness *harness, const char *type, const char *key, const char *value);
/* The newest such frame, parsed; NULL when none. */
JsonObject *szfg_fake_last_frame(SZFGHarness *harness, const char *type);

/* Test groups. */
void szfg_run_snapshot_tests(void);
void szfg_run_protocol_coverage_tests(const char *protocol_path);
void szfg_run_action_tests(void);
void szfg_run_drop_tests(void);
void szfg_run_link_tests(void);
void szfg_run_reconnect_tests(const char *fake_exe);
void szfg_run_avatar_data_tests(const char *manifest_path);

#endif /* SZFRIENDS_GTK_SUPPORT_H */

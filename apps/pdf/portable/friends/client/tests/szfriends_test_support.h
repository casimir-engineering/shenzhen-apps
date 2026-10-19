/* Shared helpers for the Friends client library tests: expectations, temporary state directories, fixtures,
 * JSON comparison and a client harness that pumps the real library against the fake helper.
 *
 * Every wait is bounded (at most a few seconds, never past 10 s) so a broken build fails instead of hanging. */

#ifndef SZFRIENDS_TEST_SUPPORT_H
#define SZFRIENDS_TEST_SUPPORT_H

#include "client/fake/szfriends_fake_helper.h"
#include "client/szfriends_client.h"

#include "cJSON.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>

extern int szft_failures;
extern const char *szft_fixtures;     /* absolute path of portable/friends/fixtures */
extern const char *szft_fake_exe;     /* absolute path of szfriends-fake-helper */

#define EXPECT(condition, ...)                                   \
    do {                                                         \
        if (!(condition)) {                                      \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                        \
            fprintf(stderr, "\n");                               \
            ++szft_failures;                                     \
        }                                                        \
    } while (0)

/* A fresh 0700 directory under the per-user temp dir; szft_remove_tree() deletes it. */
char *szft_temp_dir(const char *label);
void szft_remove_tree(const char *path);
void szft_sleep_ms(int milliseconds);

cJSON *szft_read_json(const char *relative_to_fixtures);
/* Equal as JSON values, where a key holding null in one object may be absent from the other: PROTOCOL.md marks
 * those keys optional (`params?: object|null`), and both spellings are valid on the wire. */
bool szft_json_equivalent(const cJSON *a, const cJSON *b);

/* Starts a fake on `state_dir` with this library's protocol; NULL (and a failure) when it cannot start. */
szfriends_fake_helper *szft_fake_start(const char *state_dir, int major, int minor, int min_major,
                                       uint64_t build, bool take_lock);

/* ---- Client harness ---------------------------------------------------------------------------------- */

typedef struct szft_client {
    szfriends_client *client;
    char **frames;      /* every on_frame payload, in order */
    size_t frame_count;
    int states[256];    /* every on_state value, in order */
    size_t state_count;
    szfriends_status last_error; /* the last non-OK return of on_readable */
    /* When set, the harness subscribes to this view from inside on_state(READY), as a host must after every
     * reconnect; the id it used is kept for matching the reply. */
    const char *resubscribe_view;
    char resubscribe_id[24];
} szft_client;

typedef struct szft_client_options {
    const char *state_dir;
    const char *helper_path;    /* NULL: never spawn */
    const char *helper_version; /* NULL: embedded_helper null */
    uint64_t helper_build;
} szft_client_options;

szft_client *szft_client_new(const szft_client_options *options);
void szft_client_free(szft_client *harness);
/* Drives the client (poll on its descriptor, ticks) until `done` returns true or the timeout passes. */
bool szft_pump(szft_client *harness, bool (*done)(szft_client *harness, void *argument), void *argument,
               int timeout_ms);
bool szft_wait_state(szft_client *harness, szfriends_connection_state state, int timeout_ms);
/* Index of the first frame at or after `from` whose type is `type` (and whose "re" is `re`, when given), or -1. */
long szft_find_frame(szft_client *harness, size_t from, const char *type, const char *re);
bool szft_wait_frame(szft_client *harness, size_t from, const char *type, const char *re, int timeout_ms, long *index);
cJSON *szft_frame_json(szft_client *harness, long index); /* parsed copy; caller deletes */
bool szft_saw_state(szft_client *harness, size_t from, szfriends_connection_state state);

/* Builds the intent a fixtures/intents.jsonl line describes, through the public builders. */
szfriends_intent *szft_intent_from_fixture(const cJSON *line);

/* Test groups, one per file. */
void szft_run_pure_tests(void);
void szft_run_intent_tests(void);
void szft_run_fake_tests(void);
void szft_run_fake_script_tests(void);
void szft_run_flow_tests(void);
void szft_run_spawn_tests(void);
void szft_run_signing_tests(void);

#endif /* SZFRIENDS_TEST_SUPPORT_H */

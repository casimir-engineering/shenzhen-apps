/* updater_store_test.c — the updater's pure store half: the once-a-day gate,
 * the download bounds (the 26.8.31-1 size clamp), the update.json round trip
 * including the macOS spelling, and the two settings.yaml keys.
 *
 * Cases 12-16 and the store cases of portable/linux/gtk4/tests/updater_test.c,
 * plus SPDFUpdaterDownloadBoundsTests' cases transcribed against the same
 * constants. No network, no clock, no disk. Exit code is the whole signal.
 */
/* spdf-test-sources: portable/win/src/spdf_win_updater_store.c portable/win/src/spdf_win_updater_version.c */
#include "spdf_win_updater.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                      \
    do {                                                                                 \
        ++g_checks;                                                                      \
        if (!(cond)) {                                                                   \
            fprintf(stderr, "FAIL %s (%s:%d)\n", #cond, __FILE__, __LINE__);             \
            ++g_failures;                                                                \
        }                                                                                \
    } while (0)

#define CHECK_STR(got, want)                                                                                \
    do {                                                                                                    \
        ++g_checks;                                                                                         \
        if (!(got) || strcmp((got), (want)) != 0) {                                                         \
            fprintf(stderr, "FAIL %s == \"%s\" (got \"%s\") (%s:%d)\n", #got, (want), (got) ? (got) : "(null)", \
                    __FILE__, __LINE__);                                                                    \
            ++g_failures;                                                                                   \
        }                                                                                                   \
    } while (0)

/* --- 12-16. the gate ----------------------------------------------------- */

static void test_daily_check_delay(void) {
    const long long now = 1800000000LL;

    CHECK(spdf_win_updater_daily_check_delay(1, 0, 0, now) == 0);                      /* fresh install: due */
    CHECK(spdf_win_updater_daily_check_delay(1, 1, now - 7200, now) == 86400 - 7200); /* 2 h ago: 22 h left */
    CHECK(spdf_win_updater_daily_check_delay(1, 1, now - 30 * 3600, now) == 0);       /* 30 h asleep: due */
    CHECK(spdf_win_updater_daily_check_delay(1, 1, now - 2400, now) == 86400 - 2400); /* day changed, 40 min */
    CHECK(spdf_win_updater_daily_check_delay(0, 1, now - 30 * 3600, now) == -1);      /* disabled: never */
    CHECK(spdf_win_updater_daily_check_delay(1, 1, now + 7200, now) > 86400);         /* backwards clock: closed */
    CHECK(spdf_win_updater_daily_check_delay(1, 1, now - 86400, now) == 0);           /* exactly a day: due */
}

/* --- the bounds (SPDFUpdaterDownloadBoundsTests) -------------------------- */

static void test_download_bounds(void) {
    const long long max = SPDF_WIN_UPDATER_MAX_ASSET_BYTES;

    /* Ceiling: declared + 1 byte of slack, hard max when unknown or absurd. */
    CHECK(spdf_win_updater_download_ceiling(1000) == 1001);
    CHECK(spdf_win_updater_download_ceiling(0) == max);
    CHECK(spdf_win_updater_download_ceiling(-5) == max);
    CHECK(spdf_win_updater_download_ceiling(max) == max);
    CHECK(spdf_win_updater_download_ceiling(max - 1) == max);
    /* THE 26.8.31-1 REGRESSION: an absurd declared size used to overflow the
     * +1 negative and cancel every download on its first callback. */
    CHECK(spdf_win_updater_download_ceiling(9223372036854775807LL) == max);
    CHECK(spdf_win_updater_download_ceiling(9223372036854775807LL) > 0);
    CHECK(!spdf_win_updater_download_must_cancel(1, -1, 9223372036854775807LL));

    /* Cancel: past the declared size, or a server that announces a monster. */
    CHECK(!spdf_win_updater_download_must_cancel(1000, 1000, 1000));  /* exactly declared: fine */
    CHECK(!spdf_win_updater_download_must_cancel(1001, -1, 1000));    /* the slack byte */
    CHECK(spdf_win_updater_download_must_cancel(1002, -1, 1000));     /* one past: cancel */
    CHECK(spdf_win_updater_download_must_cancel(10, max + 1, 0));     /* announced too big */
    CHECK(!spdf_win_updater_download_must_cancel(10, -1, 0));         /* chunked, unknown: fine */
    CHECK(spdf_win_updater_download_must_cancel(max + 1, -1, 0));     /* hard bound always */
    CHECK(!spdf_win_updater_download_must_cancel(max, -1, 0));

    /* Free space: 3x the declared size; unknowns never block. */
    CHECK(spdf_win_updater_has_free_space(3000, 1000));
    CHECK(!spdf_win_updater_has_free_space(2999, 1000));
    CHECK(spdf_win_updater_has_free_space(0, 1000));  /* unreadable volume */
    CHECK(spdf_win_updater_has_free_space(1, 0));     /* no declared size */
    CHECK(spdf_win_updater_has_free_space(3 * max, 9223372036854775807LL)); /* clamped, not overflowed */
}

/* --- update.json ---------------------------------------------------------- */

static void test_store_roundtrip(void) {
    spdf_win_update_store store;
    spdf_win_update_store parsed;
    char* json;

    memset(&store, 0, sizeof(store));
    store.last_check = 1800000123LL;
    store.etag = (char*)"W/\"abc\tdef\"";
    store.highest_seen = (char*)"26.8.2-1";
    store.deferred_tag = (char*)"26.8.2-1";
    store.remind_after = 1800604923LL;
    store.pending_tag = (char*)"26.8.2-1";
    store.update_ok = (char*)"26.7.17-1";

    json = spdf_win_update_store_serialize(&store);
    CHECK(json != NULL);
    CHECK(json && strstr(json, "\"lastUpdateCheck\": 1800000123") != NULL);
    CHECK(json && strstr(json, "\\t") != NULL); /* the tab in the etag is escaped, not raw */
    spdf_win_update_store_parse(json, -1, &parsed);
    CHECK(parsed.last_check == store.last_check);
    CHECK_STR(parsed.etag, store.etag);
    CHECK_STR(parsed.highest_seen, store.highest_seen);
    CHECK_STR(parsed.deferred_tag, store.deferred_tag);
    CHECK(parsed.remind_after == store.remind_after);
    CHECK_STR(parsed.pending_tag, store.pending_tag);
    CHECK_STR(parsed.update_ok, store.update_ok);
    spdf_win_update_store_clear(&parsed);
    CHECK(parsed.etag == NULL && parsed.last_check == 0);
    free(json);

    /* An empty store serialises to an empty object and parses back to zero. */
    memset(&store, 0, sizeof(store));
    json = spdf_win_update_store_serialize(&store);
    CHECK_STR(json, "{}\n");
    spdf_win_update_store_parse(json, -1, &parsed);
    CHECK(parsed.last_check == 0 && parsed.pending_tag == NULL);
    free(json);

    /* Empty / absent / corrupt files parse to a zeroed store. */
    spdf_win_update_store_parse(NULL, -1, &parsed);
    CHECK(parsed.last_check == 0);
    CHECK(parsed.pending_tag == NULL);
    spdf_win_update_store_parse("garbage{{{", -1, &parsed);
    CHECK(parsed.last_check == 0);
    spdf_win_update_store_clear(&parsed);
    /* A store damaged AFTER a good field keeps the good field. */
    spdf_win_update_store_parse("{\"lastUpdateCheck\": 5, \"etag\": [", -1, &parsed);
    CHECK(parsed.last_check == 5);
    spdf_win_update_store_clear(&parsed);
}

/* macOS's spelling: snake_case update_ok, fractional timestamps, and the lease
 * as a nested object this port has no use for and must skip structurally. */
static void test_store_parses_mac_format(void) {
    spdf_win_update_store parsed;
    static const char k_mac[] =
        "{\n"
        "  \"etag\" : \"W/\\\"zz\\\"\",\n"
        "  \"highestVersionSeen\" : \"26.8.2-1\",\n"
        "  \"lastUpdateCheck\" : 1800000123.25,\n"
        "  \"update_ok\" : \"26.7.17-1\",\n"
        "  \"updateInProgress\" : {\n"
        "    \"pid\" : 4242,\n"
        "    \"timestamp\" : 1800000200.75\n"
        "  },\n"
        "  \"pendingTag\" : \"26.8.2-1\"\n"
        "}";

    spdf_win_update_store_parse(k_mac, -1, &parsed);
    CHECK_STR(parsed.etag, "W/\"zz\"");
    CHECK_STR(parsed.highest_seen, "26.8.2-1");
    CHECK(parsed.last_check == 1800000123LL); /* fraction truncated */
    CHECK_STR(parsed.update_ok, "26.7.17-1");
    CHECK_STR(parsed.pending_tag, "26.8.2-1"); /* read PAST the skipped nested object */
    spdf_win_update_store_clear(&parsed);
}

/* --- settings.yaml --------------------------------------------------------- */

static void test_settings(void) {
    char skipped[64];

    /* Absent, empty and NULL all mean enabled: the default on every platform. */
    CHECK(spdf_win_updater_setting_enabled(NULL));
    CHECK(spdf_win_updater_setting_enabled(""));
    CHECK(spdf_win_updater_setting_enabled("showSidebar: true\n"));
    CHECK(spdf_win_updater_setting_enabled("autoUpdateEnabled: true\n"));
    CHECK(!spdf_win_updater_setting_enabled("autoUpdateEnabled: false\n"));
    CHECK(!spdf_win_updater_setting_enabled("showSidebar: true\nautoUpdateEnabled: false\n"));
    CHECK(!spdf_win_updater_setting_enabled("  autoUpdateEnabled:   false   # user choice\n"));
    /* The JSON spelling the state layer is migrating from. */
    CHECK(!spdf_win_updater_setting_enabled("{\n  \"autoUpdateEnabled\": false,\n}\n"));
    CHECK(spdf_win_updater_setting_enabled("{\n  \"autoUpdateEnabled\": true\n}\n"));
    /* A key that merely CONTAINS the name is not the key. */
    CHECK(spdf_win_updater_setting_enabled("xautoUpdateEnabled: false\n"));
    CHECK(spdf_win_updater_setting_enabled("autoUpdateEnabledX: false\n"));

    CHECK(!spdf_win_updater_setting_skipped(NULL, skipped, sizeof(skipped)));
    CHECK_STR(skipped, "");
    CHECK(!spdf_win_updater_setting_skipped("autoUpdateEnabled: true\n", skipped, sizeof(skipped)));
    CHECK(spdf_win_updater_setting_skipped("skippedUpdateVersion: 26.8.2-1\n", skipped, sizeof(skipped)));
    CHECK_STR(skipped, "26.8.2-1");
    CHECK(spdf_win_updater_setting_skipped("\"skippedUpdateVersion\": \"26.8.2-1\",\n", skipped, sizeof(skipped)));
    CHECK_STR(skipped, "26.8.2-1");
    CHECK(!spdf_win_updater_setting_skipped("skippedUpdateVersion: \"\"\n", skipped, sizeof(skipped)));
    CHECK(!spdf_win_updater_setting_skipped("skippedUpdateVersion: null\n", skipped, sizeof(skipped)));
    CHECK(!spdf_win_updater_setting_skipped("skippedUpdateVersion:\n", skipped, sizeof(skipped)));
}

int main(void) {
    test_daily_check_delay();
    test_download_bounds();
    test_store_roundtrip();
    test_store_parses_mac_format();
    test_settings();
    printf("updater_store_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}

/* spdf_win_updater_store.c — the once-a-day gate, the download bounds, the
 * update.json store, and the two settings.yaml keys the updater reads.
 *
 * Pure C: no <windows.h>, no allocation beyond the store's own strings, so
 * portable/win/tests/updater_store_test.c can pin every decision without a
 * network, a clock or a registry. The three sources it transcribes:
 *
 *   gate     spdf_updater_daily_check_delay      (spdf_updater.c:88)
 *   bounds   SPDFUpdaterDownloadBounds.mm        (the 26.8.31-1 clamp)
 *   store    spdf_update_store_parse/serialize   (spdf_updater.c:828-915)
 *
 * The store is JSON and stays JSON on purpose: the other two frontends write
 * update.json, and a support request that says "send me your update.json"
 * should get the same shape from every platform.
 */
#include "spdf_win_updater.h"
#include "spdf_win_updater_json.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* --- the gate ----------------------------------------------------------- */

long long spdf_win_updater_daily_check_delay(int auto_update_enabled, int have_last_check, long long last_check_epoch,
                                             long long now_epoch) {
    long long elapsed;

    if (!auto_update_enabled) return -1;
    if (!have_last_check) return 0; /* fresh install: due now */
    elapsed = now_epoch - last_check_epoch;
    if (elapsed >= SPDF_WIN_UPDATER_DAILY_INTERVAL) return 0;
    /* Rolling 24 h, deliberately not calendar-day based. A clock set backwards
     * makes `elapsed` negative and the delay MORE than a day: the gate stays
     * closed rather than opening on a clock change. */
    return SPDF_WIN_UPDATER_DAILY_INTERVAL - elapsed;
}

/* --- settings.yaml ------------------------------------------------------ */

/* Finds "<key>:" or "\"<key>\":" at the start of a line (leading blanks
 * allowed) and returns a pointer to the first non-blank after the colon, or
 * NULL. Tolerates both spellings because the state layer is mid-migration
 * from JSON to YAML and the key name is the same in both. */
static const char* setting_value(const char* text, const char* key) {
    size_t klen = strlen(key);
    const char* line = text;

    if (!text) return NULL;
    while (*line) {
        const char* p = line;
        const char* eol = strchr(line, '\n');
        int quoted;
        while (*p == ' ' || *p == '\t') p++;
        quoted = *p == '"';
        if (quoted) p++;
        if (strncmp(p, key, klen) == 0) {
            p += klen;
            if (quoted && *p == '"') p++;
            if (*p == ':') {
                p++;
                while (*p == ' ' || *p == '\t') p++;
                return p;
            }
        }
        if (!eol) break;
        line = eol + 1;
    }
    return NULL;
}

int spdf_win_updater_setting_enabled(const char* settings_text) {
    const char* v = setting_value(settings_text, "autoUpdateEnabled");
    if (!v) return 1;
    if (strncmp(v, "false", 5) == 0 || strncmp(v, "no", 2) == 0 || strncmp(v, "off", 3) == 0 || *v == '0')
        return 0;
    return 1;
}

int spdf_win_updater_setting_skipped(const char* settings_text, char* out, size_t out_len) {
    const char* v = setting_value(settings_text, "skippedUpdateVersion");
    size_t n = 0;

    if (!out || out_len == 0) return 0;
    out[0] = '\0';
    if (!v) return 0;
    if (*v == '"' || *v == '\'') {
        char q = *v++;
        while (v[n] && v[n] != q && n + 1 < out_len) n++;
    } else {
        while (v[n] && v[n] != '\r' && v[n] != '\n' && v[n] != ' ' && v[n] != '#' && n + 1 < out_len) n++;
    }
    memcpy(out, v, n);
    out[n] = '\0';
    if (n == 0 || strcmp(out, "null") == 0) {
        out[0] = '\0';
        return 0;
    }
    return 1;
}

/* --- download bounds (SPDFUpdaterDownloadBounds.mm, line for line) -------- */

/* asset.size is untrusted, so clamp it into [0, MAX] before any arithmetic. A
 * size above the hard max could never be downloaded anyway, so clamping never
 * rejects a viable update. This is the 26.8.31-1 fix: before it, declared + 1
 * overflowed on an absurd size, came out negative, and cancelled every
 * download on its first progress callback. */
static long long clamp_asset_size(long long declared) {
    if (declared <= 0) return 0;
    return declared < SPDF_WIN_UPDATER_MAX_ASSET_BYTES ? declared : SPDF_WIN_UPDATER_MAX_ASSET_BYTES;
}

long long spdf_win_updater_download_ceiling(long long declared_asset_size) {
    long long declared = clamp_asset_size(declared_asset_size);
    if (declared <= 0) return SPDF_WIN_UPDATER_MAX_ASSET_BYTES; /* no declared size: hard max */
    /* One byte of slack so a download of exactly the declared size passes and
     * the first byte beyond it trips. The clamp keeps the +1 in range. */
    return declared + 1 < SPDF_WIN_UPDATER_MAX_ASSET_BYTES ? declared + 1 : SPDF_WIN_UPDATER_MAX_ASSET_BYTES;
}

int spdf_win_updater_download_must_cancel(long long total_written, long long total_expected,
                                          long long declared_asset_size) {
    /* The written-bytes ceiling is the HARD bound and is always evaluated, even
     * for chunked responses where the server declared no length (-1). */
    if (total_written > spdf_win_updater_download_ceiling(declared_asset_size)) return 1;
    return total_expected > 0 && total_expected > SPDF_WIN_UPDATER_MAX_ASSET_BYTES;
}

int spdf_win_updater_has_free_space(long long free_bytes, long long declared_asset_size) {
    long long declared = clamp_asset_size(declared_asset_size);
    /* An absent size or an unreadable volume must never block an update. */
    if (declared <= 0 || free_bytes <= 0) return 1;
    return free_bytes >= declared * 3; /* download + staged copy + the .old */
}

/* --- update.json -------------------------------------------------------- */

/* macOS writes the in-progress lease as a nested object,
 *   "updateInProgress": { "pid": 123, "timestamp": 1710000000.5 }
 * and the GTK port maps it onto flat lease fields. This port takes no lease
 * (one process owns the timers; a second window is the same process), so the
 * object is skipped structurally like any other unknown member. */
void spdf_win_update_store_parse(const char* json, long len, spdf_win_update_store* out) {
    spdf_win_js_cursor c;
    char* key;
    int r;

    if (!out) return;
    memset(out, 0, sizeof(*out));
    if (!json) return;
    c.p = json;
    c.end = json + (len < 0 ? (long)strlen(json) : len);
    if (!spdf_win_js_enter_object(&c)) return;
    while ((r = spdf_win_js_next_member(&c, &key)) > 0) {
        int ok;
        if (strcmp(key, "lastUpdateCheck") == 0) {
            ok = spdf_win_js_read_int(&c, &out->last_check);
        } else if (strcmp(key, "remindAfter") == 0) {
            ok = spdf_win_js_read_int(&c, &out->remind_after);
        } else if (strcmp(key, "etag") == 0) {
            free(out->etag);
            out->etag = spdf_win_js_read_string(&c);
            ok = out->etag != NULL;
        } else if (strcmp(key, "highestVersionSeen") == 0) {
            free(out->highest_seen);
            out->highest_seen = spdf_win_js_read_string(&c);
            ok = out->highest_seen != NULL;
        } else if (strcmp(key, "deferredTag") == 0) {
            free(out->deferred_tag);
            out->deferred_tag = spdf_win_js_read_string(&c);
            ok = out->deferred_tag != NULL;
        } else if (strcmp(key, "pendingTag") == 0) {
            free(out->pending_tag);
            out->pending_tag = spdf_win_js_read_string(&c);
            ok = out->pending_tag != NULL;
        } else if (strcmp(key, "updateOk") == 0 || strcmp(key, "update_ok") == 0) {
            /* macOS spells the healthy-relaunch marker update_ok (snake_case). */
            free(out->update_ok);
            out->update_ok = spdf_win_js_read_string(&c);
            ok = out->update_ok != NULL;
        } else {
            ok = spdf_win_js_skip_value(&c);
        }
        free(key);
        if (!ok) break; /* keep what parsed so far: a damaged store loses a field, not the day's slot */
    }
}

static void append_string_member(spdf_win_sb* sb, const char* key, const char* value, int* first) {
    if (!value || !*value) return;
    spdf_win_sb_append(sb, *first ? "\n  \"" : ",\n  \"");
    spdf_win_sb_append(sb, key);
    spdf_win_sb_append(sb, "\": ");
    spdf_win_js_append_quoted(sb, value);
    *first = 0;
}

static void append_int_member(spdf_win_sb* sb, const char* key, long long value, int* first) {
    char num[32];
    if (value == 0) return;
    spdf_win_sb_append(sb, *first ? "\n  \"" : ",\n  \"");
    spdf_win_sb_append(sb, key);
    spdf_win_sb_append(sb, "\": ");
    snprintf(num, sizeof(num), "%lld", value);
    spdf_win_sb_append(sb, num);
    *first = 0;
}

char* spdf_win_update_store_serialize(const spdf_win_update_store* store) {
    spdf_win_sb sb;
    int first = 1;

    spdf_win_sb_init(&sb);
    spdf_win_sb_append(&sb, "{");
    if (store) {
        append_int_member(&sb, "lastUpdateCheck", store->last_check, &first);
        append_string_member(&sb, "etag", store->etag, &first);
        append_string_member(&sb, "highestVersionSeen", store->highest_seen, &first);
        append_string_member(&sb, "deferredTag", store->deferred_tag, &first);
        append_int_member(&sb, "remindAfter", store->remind_after, &first);
        append_string_member(&sb, "pendingTag", store->pending_tag, &first);
        append_string_member(&sb, "updateOk", store->update_ok, &first);
    }
    spdf_win_sb_append(&sb, first ? "}\n" : "\n}\n");
    return spdf_win_sb_finish(&sb);
}

void spdf_win_update_store_clear(spdf_win_update_store* store) {
    if (!store) return;
    free(store->etag);
    free(store->highest_seen);
    free(store->deferred_tag);
    free(store->pending_tag);
    free(store->update_ok);
    memset(store, 0, sizeof(*store));
}

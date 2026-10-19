/* spdf_win_updater_work.cpp — the updater's worker half: the check, the
 * install, and the store mutators they and the UI share.
 *
 * Runs on threads the UI thread creates (spdf_win_updater_ui.cpp) and touches
 * no window: every result is PostMessageW()d back as an outcome. The order of
 * checks in the install is the order that matters -- integrity first (size,
 * SHA-256), then TRUST (Authenticode + the pin), then the staged exe's own
 * ProductVersion against the tag, then the swap -- and any failure before the
 * swap deletes the download so an unverified artifact is never left around.
 */
#include "spdf_win_updater.h"
#include "spdf_win_updater_internal.h"

#include "spdf_win_about_version.h"

#include <windows.h>
#include <shlobj.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")

const char* spdf_win_updater_running_version(void) {
    return SPDF_WIN_RELEASE_TAG;
}

/* settings.yaml, read-only: %APPDATA%\ShenzhenPDF\settings.yaml. NULL when
 * absent, which every reader treats as the default. */
static char* read_settings_text(void) {
    wchar_t* roaming = NULL;
    wchar_t path[MAX_PATH];
    char* text = NULL;
    size_t len = 0;
    if (SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, NULL, &roaming) != S_OK || !roaming) return NULL;
    _snwprintf_s(path, _countof(path), _TRUNCATE, L"%s\\ShenzhenPDF\\settings.yaml", roaming);
    CoTaskMemFree(roaming);
    spdf_win_updater_read_file(path, &text, &len, 2 * 1024 * 1024);
    return text;
}

/* --- store mutators ----------------------------------------------------------- */

static int mutator_claim_daily_slot(spdf_win_update_store* store, void* user) {
    int* claimed = (int*)user;
    long long now = spdf_win_updater_now_epoch();
    long long delay = spdf_win_updater_daily_check_delay(1, store->last_check != 0, store->last_check, now);
    if (delay != 0) return 0;
    /* Stamp BEFORE the network call: a crash or a 403 still consumes the
     * day's slot, so a broken server is asked once a day, not once a second. */
    store->last_check = now;
    *claimed = 1;
    return 1;
}

int spdf_win_updater_claim_daily_slot(void) {
    char* settings = read_settings_text();
    int enabled = spdf_win_updater_setting_enabled(settings);
    int claimed = 0;
    free(settings);
    if (!enabled) return 0;
    spdf_win_updater_with_locked_store(mutator_claim_daily_slot, &claimed);
    return claimed;
}

typedef struct store_snapshot {
    char etag[256];
    char highest_seen[64];
    char deferred_tag[64];
    long long remind_after;
} store_snapshot;

static int mutator_read_snapshot(spdf_win_update_store* store, void* user) {
    store_snapshot* s = (store_snapshot*)user;
    strncpy_s(s->etag, sizeof(s->etag), store->etag ? store->etag : "", _TRUNCATE);
    strncpy_s(s->highest_seen, sizeof(s->highest_seen), store->highest_seen ? store->highest_seen : "", _TRUNCATE);
    strncpy_s(s->deferred_tag, sizeof(s->deferred_tag), store->deferred_tag ? store->deferred_tag : "", _TRUNCATE);
    s->remind_after = store->remind_after;
    return 0;
}

typedef struct persist_args {
    const char* etag;
    const char* tag;
} persist_args;

static int mutator_persist_check(spdf_win_update_store* store, void* user) {
    persist_args* a = (persist_args*)user;
    int changed = 0;
    if (a->etag && *a->etag && (!store->etag || strcmp(store->etag, a->etag) != 0)) {
        free(store->etag);
        store->etag = _strdup(a->etag);
        changed = 1;
    }
    /* Advance the high-water mark on every 200, whatever the user chooses. */
    if (a->tag && *a->tag &&
        (!store->highest_seen || !*store->highest_seen ||
         spdf_win_updater_compare_versions(a->tag, store->highest_seen) > 0)) {
        free(store->highest_seen);
        store->highest_seen = _strdup(a->tag);
        changed = 1;
    }
    return changed;
}

static int mutator_snooze(spdf_win_update_store* store, void* user) {
    free(store->deferred_tag);
    store->deferred_tag = _strdup((const char*)user);
    store->remind_after = spdf_win_updater_now_epoch() + SPDF_WIN_UPDATER_LATER_SNOOZE_SECONDS;
    return 1;
}

void spdf_win_updater_snooze(const char* tag) {
    if (tag && *tag) spdf_win_updater_with_locked_store(mutator_snooze, (void*)tag);
}

static int mutator_set_pending(spdf_win_update_store* store, void* user) {
    free(store->pending_tag);
    store->pending_tag = _strdup((const char*)user);
    return 1;
}

/* --- the check ------------------------------------------------------------------- */

unsigned long __stdcall spdf_win_updater_check_thread(void* param) {
    spdf_win_check_outcome* out = (spdf_win_check_outcome*)param;
    store_snapshot snap;
    wchar_t dir[MAX_PATH];
    wchar_t body_path[MAX_PATH + 32];
    spdf_win_fetch_result fetch;
    char* body = NULL;
    size_t body_len = 0;
    const char* running = spdf_win_updater_running_version();

    memset(&snap, 0, sizeof(snap));
    body_path[0] = L'\0';
    spdf_win_updater_with_locked_store(mutator_read_snapshot, &snap);
    if (!spdf_win_updater_dir(dir, _countof(dir))) {
        strncpy_s(out->err, sizeof(out->err), "the updates folder could not be created", _TRUNCATE);
        goto done;
    }
    _snwprintf_s(body_path, _countof(body_path), _TRUNCATE, L"%s\\release.json", dir);
    /* The manual path omits the ETag so the server answers 200 and the whole
     * decision runs; the silent path sends it so a 304 costs nothing. */
    if (!spdf_win_updater_fetch(SPDF_WIN_UPDATER_RELEASES_LATEST_URL, body_path, out->user_initiated ? NULL : snap.etag,
                                1, SPDF_WIN_UPDATER_MAX_FEED_BYTES, SPDF_WIN_UPDATER_NET_TIMEOUT_MS, out->cancel,
                                &fetch)) {
        strncpy_s(out->err, sizeof(out->err), fetch.err, _TRUNCATE);
        goto done;
    }
    if (fetch.status == 304) {
        out->ok = 1;
        out->not_modified = 1;
        goto done;
    }
    if (fetch.status != 200) {
        snprintf(out->err, sizeof(out->err), "the update server returned HTTP %d", fetch.status);
        goto done;
    }
    if (!spdf_win_updater_read_file(body_path, &body, &body_len, (size_t)SPDF_WIN_UPDATER_MAX_FEED_BYTES) ||
        !spdf_win_updater_parse_release(body, (long)body_len, SPDF_WIN_UPDATER_ASSET, SPDF_WIN_UPDATER_SIDECAR_SUFFIX,
                                        &out->release)) {
        strncpy_s(out->err, sizeof(out->err), "the update server response was malformed", _TRUNCATE);
        goto done;
    }
    {
        persist_args pa = {fetch.etag, out->release.tag};
        spdf_win_updater_with_locked_store(mutator_persist_check, &pa);
    }
    out->ok = 1;
    out->available = spdf_win_updater_release_available(&out->release, running, snap.highest_seen);
    out->newer_but_missing_asset = !out->available && !out->release.draft && !out->release.prerelease &&
                                   spdf_win_updater_compare_versions(out->release.tag, running) > 0 &&
                                   (!out->release.asset_url || !out->release.sidecar_url);
    /* The silent path honours skippedUpdateVersion and "Later" (7 days). */
    if (out->available && !out->user_initiated) {
        char skipped[64];
        char* settings = read_settings_text();
        if (spdf_win_updater_setting_skipped(settings, skipped, sizeof(skipped)) &&
            strcmp(skipped, out->release.tag) == 0)
            out->available = 0;
        free(settings);
        if (out->available && snap.deferred_tag[0] && strcmp(snap.deferred_tag, out->release.tag) == 0 &&
            spdf_win_updater_now_epoch() < snap.remind_after)
            out->available = 0;
    }
done:
    if (body_path[0]) DeleteFileW(body_path);
    free(body);
    PostMessageW((HWND)out->sink, SPDF_WIN_UPDATER_MSG_CHECK_DONE, 0, (LPARAM)out);
    return 0;
}

/* --- the install ------------------------------------------------------------------ */

unsigned long __stdcall spdf_win_updater_install_thread(void* param) {
    spdf_win_install_outcome* out = (spdf_win_install_outcome*)param;
    const spdf_win_release_info* rel = &out->release;
    wchar_t dir[MAX_PATH], tag_dir[MAX_PATH + 72], asset_path[MAX_PATH + 160], sidecar_path[MAX_PATH + 168];
    wchar_t staged[MAX_PATH + 8];
    wchar_t wtag[64];
    spdf_win_fetch_result fetch;
    char* sidecar_text = NULL;
    size_t sidecar_len = 0;
    char want_hex[65], got_hex[65];
    char product[128];
    char err[512];

    tag_dir[0] = asset_path[0] = sidecar_path[0] = L'\0';
    if (!rel->tag || MultiByteToWideChar(CP_UTF8, 0, rel->tag, -1, wtag, _countof(wtag)) <= 0) wtag[0] = L'\0';
    if (!wtag[0] || !spdf_win_updater_dir(dir, _countof(dir))) {
        strncpy_s(out->err, sizeof(out->err), "the updates folder could not be created", _TRUNCATE);
        goto done;
    }
    _snwprintf_s(tag_dir, _countof(tag_dir), _TRUNCATE, L"%s\\%s", dir, wtag);
    CreateDirectoryW(tag_dir, NULL);
    _snwprintf_s(asset_path, _countof(asset_path), _TRUNCATE, L"%s\\%hs", tag_dir, SPDF_WIN_UPDATER_ASSET);
    _snwprintf_s(sidecar_path, _countof(sidecar_path), _TRUNCATE, L"%s%hs", asset_path, SPDF_WIN_UPDATER_SIDECAR_SUFFIX);

    /* Free space, from the untrusted declared size clamped by the bounds. */
    {
        ULARGE_INTEGER free_bytes;
        if (GetDiskFreeSpaceExW(dir, &free_bytes, NULL, NULL) &&
            !spdf_win_updater_has_free_space((long long)free_bytes.QuadPart, rel->asset_size)) {
            strncpy_s(out->err, sizeof(out->err), "there is not enough free disk space to download the update",
                      _TRUNCATE);
            goto done;
        }
    }
    if (!spdf_win_updater_fetch(rel->sidecar_url, sidecar_path, NULL, 0, SPDF_WIN_UPDATER_MAX_SIDECAR_BYTES,
                                SPDF_WIN_UPDATER_NET_TIMEOUT_MS, out->cancel, &fetch) ||
        fetch.status != 200) {
        snprintf(out->err, sizeof(out->err), "the update's checksum could not be downloaded (%s)",
                 fetch.err[0] ? fetch.err : "HTTP error");
        goto done;
    }
    if (!spdf_win_updater_read_file(sidecar_path, &sidecar_text, &sidecar_len, 64 * 1024) ||
        !spdf_win_updater_parse_sha256_sidecar(sidecar_text, want_hex, sizeof(want_hex))) {
        strncpy_s(out->err, sizeof(out->err), "the update's checksum file was malformed", _TRUNCATE);
        goto done;
    }
    if (!spdf_win_updater_fetch(rel->asset_url, asset_path, NULL, 0, spdf_win_updater_download_ceiling(rel->asset_size),
                                SPDF_WIN_UPDATER_ASSET_TIMEOUT_MS, out->cancel, &fetch) ||
        fetch.status != 200) {
        snprintf(out->err, sizeof(out->err), "the update could not be downloaded (%s)",
                 fetch.err[0] ? fetch.err : "HTTP error");
        goto done;
    }
    /* Integrity: declared size (when given), then the sidecar digest. Both are
     * heuristics against truncation and a stale CDN, never trust. */
    if (rel->asset_size > 0 && fetch.bytes != rel->asset_size) {
        strncpy_s(out->err, sizeof(out->err), "the downloaded update was incomplete", _TRUNCATE);
        goto done;
    }
    if (!spdf_win_updater_sha256_file(asset_path, got_hex, sizeof(got_hex)) || strcmp(got_hex, want_hex) != 0) {
        strncpy_s(out->err, sizeof(out->err), "the downloaded update does not match its published checksum",
                  _TRUNCATE);
        goto done;
    }
    /* TRUST: Authenticode + the pin. This is the only gate that matters. */
    if (!spdf_win_updater_verify_pinned(asset_path, spdf_win_updater_pinned_thumbprint(), err, sizeof(err))) {
        snprintf(out->err, sizeof(out->err), "The update could not be verified and was not installed (%s).", err);
        goto done;
    }
    /* The right publisher's RIGHT build: the staged exe must say it is the tag. */
    if (!spdf_win_updater_file_product_version(asset_path, product, sizeof(product)) ||
        !spdf_win_updater_versions_match_release_target(rel->tag, product)) {
        snprintf(out->err, sizeof(out->err), "the downloaded file says it is version %s, not %s; it was not installed",
                 product[0] ? product : "(unknown)", rel->tag);
        goto done;
    }
    if (!spdf_win_updater_stage_beside(out->self_exe, asset_path, staged, _countof(staged), err, sizeof(err)) ||
        !spdf_win_updater_swap_exe(out->self_exe, staged, err, sizeof(err))) {
        strncpy_s(out->err, sizeof(out->err), err, _TRUNCATE);
        DeleteFileW(staged);
        goto done;
    }
    spdf_win_updater_with_locked_store(mutator_set_pending, (void*)rel->tag);
    out->ok = 1;
done:
    /* Installed or not, the copy under updates\ has done its job -- and a
     * partial or unverified artifact must never be left around. */
    if (asset_path[0]) DeleteFileW(asset_path);
    if (sidecar_path[0]) DeleteFileW(sidecar_path);
    if (tag_dir[0]) RemoveDirectoryW(tag_dir);
    free(sidecar_text);
    PostMessageW((HWND)out->sink, SPDF_WIN_UPDATER_MSG_INSTALL_DONE, 0, (LPARAM)out);
    return 0;
}

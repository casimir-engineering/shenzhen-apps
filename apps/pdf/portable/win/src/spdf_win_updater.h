/* spdf_win_updater.h — the auto-updater for the Windows frontend.
 *
 * A PORT of portable/linux/gtk4/spdf_updater.c (itself a port of
 * portable/mac/SPDFUpdater.mm), with the two platform halves replaced:
 *
 *   TRUST     minisign/ed25519 (Linux) and Developer ID + notarization (macOS)
 *             become AUTHENTICODE: WinVerifyTrust on the downloaded exe PLUS a
 *             pinned SHA-256 thumbprint of the leaf signing certificate,
 *             compiled into the app. An empty pin means "verification is
 *             impossible", and an impossible verification NEVER INSTALLS -- it
 *             is not a skip. The same rule GTK applies to a release with no
 *             .minisig ("unsigned release: never offer").
 *   INSTALL   pkexec dpkg / the .app swap become a SELF-REPLACING EXE: the
 *             download is staged next to the running binary, the running
 *             binary is renamed to <exe>.old (Windows allows renaming a mapped
 *             image, not overwriting it), the new one is moved in with
 *             MoveFileExW, and .old is kept until the relaunched process
 *             confirms it is the version it was promised. A mismatched relaunch
 *             keeps .old and says where it is.
 *
 * EVERYTHING ABOVE THE TRANSPORT IS PURE C AND UNIT-TESTED OFFLINE, exactly as
 * in the GTK module: version compare, the once-a-day gate, the structural JSON
 * scan of GitHub's /releases/latest, the availability decision, the
 * release-notes formatter (the 26.7.17-1 bulleted-list fix), the update.json
 * store, and the download bounds (the 26.8.31-1 size clamp, transcribed from
 * SPDFUpdaterDownloadBounds.mm). None of those files include <windows.h>;
 * portable/win/tests/updater_*_test.c drive them with no network.
 *
 * THE RELEASE-ASSET LAYOUT this parser expects, so the release pipeline can
 * provide it (it does not exist yet -- no Windows binary has been published):
 *
 *   ShenzhenPDF-win-x64.exe          Authenticode-signed; VERSIONINFO
 *                                    ProductVersion == the release tag
 *   ShenzhenPDF-win-x64.exe.sha256   "<64 hex>  ShenzhenPDF-win-x64.exe\n"
 *
 * The sidecar is an INTEGRITY heuristic (truncation, a CDN serving the wrong
 * bytes), never a trust decision -- the same role asset.size plays on the
 * other two platforms. Trust is Authenticode + the pin, full stop. Its
 * presence is still required before an update is offered, so the layout keeps
 * the GTK convention of "<asset>" plus "<asset>.<suffix>".
 *
 * OFF THE LAUNCH PATH. spdf_win_updater_start_background() arms a timer and
 * returns; the first disk read happens SPDF_WIN_UPDATER_IDLE_DELAY_MS after
 * the window is up, the network check on a worker thread after that, and an
 * hourly timer re-runs the 24-hour gate so a window kept open for days keeps
 * checking (26.7.17-1). Nothing here runs before first paint.
 */
#ifndef SPDF_WIN_UPDATER_H
#define SPDF_WIN_UPDATER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --- constants ---------------------------------------------------------- */

#define SPDF_WIN_UPDATER_RELEASES_LATEST_URL \
    "https://api.github.com/repos/casimir-engineering/shenzhen-pdf/releases/latest"
#define SPDF_WIN_UPDATER_ASSET "ShenzhenPDF-win-x64.exe"
#define SPDF_WIN_UPDATER_SIDECAR_SUFFIX ".sha256"

#define SPDF_WIN_UPDATER_DAILY_INTERVAL ((long long)86400)  /* rolling 24 h, not a calendar day */
#define SPDF_WIN_UPDATER_IDLE_DELAY_MS 5000                 /* post-first-paint settle */
#define SPDF_WIN_UPDATER_CADENCE_MS (60 * 60 * 1000)        /* hourly re-run of the gate */
#define SPDF_WIN_UPDATER_LATER_SNOOZE_SECONDS ((long long)(7 * 86400))
#define SPDF_WIN_UPDATER_STALE_OLD_SECONDS ((long long)3600) /* an orphaned .old older than this is swept */
#define SPDF_WIN_UPDATER_NET_TIMEOUT_MS 15000
#define SPDF_WIN_UPDATER_ASSET_TIMEOUT_MS 600000
#define SPDF_WIN_UPDATER_MAX_FEED_BYTES ((long long)8 * 1024 * 1024)
#define SPDF_WIN_UPDATER_MAX_SIDECAR_BYTES ((long long)64 * 1024)
/* macOS's kSPDFMaxDownloadBytes. The Windows exe is a few tens of MB with
 * MuPDF linked in; 64 MB leaves room without letting a hostile listing ask for
 * a gigabyte. */
#define SPDF_WIN_UPDATER_MAX_ASSET_BYTES ((long long)64 * 1024 * 1024)
#define SPDF_WIN_UPDATER_NOTES_CHAR_CAP 500

/* --- 1. version compare (spdf_win_updater_version.c) --------------------- */

/* Split on [.-], compare numeric fields, zero-pad the shorter side. Malformed
 * input returns 0 so it can never authorise an update. */
int spdf_win_updater_compare_versions(const char* a, const char* b);
/* The relaunch health check: all four YY.M.D-BUILD fields must be present on
 * both sides and equal. */
int spdf_win_updater_versions_match_release_target(const char* target, const char* running);

/* --- 2. the once-a-day gate (spdf_win_updater_store.c) ------------------- */

/* -1 = never (disabled), 0 = due now, else seconds until due. A backwards
 * clock keeps the gate closed rather than opening it. */
long long spdf_win_updater_daily_check_delay(int auto_update_enabled, int have_last_check,
                                             long long last_check_epoch, long long now_epoch);

/* settings.yaml's autoUpdateEnabled, read from the file's text. Absent or
 * unparseable means ENABLED, which is every other frontend's default too. */
int spdf_win_updater_setting_enabled(const char* settings_text);
/* settings.yaml's skippedUpdateVersion, or 0 when absent/empty. */
int spdf_win_updater_setting_skipped(const char* settings_text, char* out, size_t out_len);

/* --- 3. the GitHub feed (spdf_win_updater_feed.c) ------------------------ */

typedef struct spdf_win_release_info {
    char* tag; /* "tag_name" */
    int draft;
    int prerelease;
    char* notes;         /* "body", NULL when absent */
    char* asset_url;     /* browser_download_url of the asset, NULL if absent */
    long long asset_size; /* its "size", 0 if absent -- UNTRUSTED, see the bounds */
    char* sidecar_url;   /* browser_download_url of "<asset><suffix>" */
} spdf_win_release_info;

/* Structural scan: braces and quotes inside the release body cannot confuse
 * the asset search. `len` < 0 means NUL-terminated. Returns 1 and fills `out`
 * (owned strings; clear with spdf_win_release_info_clear), or 0 and leaves it
 * zeroed. */
int spdf_win_updater_parse_release(const char* json, long len, const char* asset_name, const char* sidecar_suffix,
                                   spdf_win_release_info* out);
void spdf_win_release_info_clear(spdf_win_release_info* info);

/* The availability predicate every frontend shares: newer than running, not
 * below the highest-seen high-water mark, has both the asset and its sidecar,
 * not a draft or prerelease. */
int spdf_win_updater_release_available(const spdf_win_release_info* info, const char* running,
                                       const char* highest_seen);

/* The update prompt's text: highlights above the first horizontal rule,
 * markdown stripped, bullets to "\xE2\x80\xA2 " (U+2022) each on its own line,
 * control and bidi characters removed, capped at 500 characters on a line
 * boundary. malloc'd; "" for empty input. */
char* spdf_win_updater_format_notes(const char* body);

/* "<64 hex>  <name>" or just "<64 hex>": the sha256sum format. Lower-cases
 * into out_hex (65 bytes, NUL-terminated). 0 for anything else. */
int spdf_win_updater_parse_sha256_sidecar(const char* text, char* out_hex, size_t out_len);

/* --- 4. download bounds (spdf_win_updater_store.c) ----------------------- */

/* Transcribed from portable/mac/SPDFUpdaterDownloadBounds.mm, including the
 * 26.8.31-1 fix: the declared size is clamped into [0, MAX] before any
 * arithmetic, so an absurd size can no longer overflow the ceiling negative
 * and cancel every download on its first progress callback. */
long long spdf_win_updater_download_ceiling(long long declared_asset_size);
int spdf_win_updater_download_must_cancel(long long total_written, long long total_expected,
                                          long long declared_asset_size);
int spdf_win_updater_has_free_space(long long free_bytes, long long declared_asset_size);

/* --- 5. the update.json store (spdf_win_updater_store.c) ----------------- */

/* Flat schema shared with the other two frontends' update.json, so the keys
 * read the same in a bug report whichever app wrote them. */
typedef struct spdf_win_update_store {
    long long last_check;  /* "lastUpdateCheck", epoch seconds; 0 = never */
    char* etag;            /* "etag" of the last 200 */
    char* highest_seen;    /* "highestVersionSeen": downgrade/replay high-water mark */
    char* deferred_tag;    /* "deferredTag": the "Later" snooze target */
    long long remind_after; /* "remindAfter", epoch seconds */
    char* pending_tag;     /* "pendingTag": an install awaiting the relaunch health check */
    char* update_ok;       /* "updateOk": the last confirmed-healthy tag */
} spdf_win_update_store;

void spdf_win_update_store_parse(const char* json, long len, spdf_win_update_store* out); /* zeroes, then fills */
char* spdf_win_update_store_serialize(const spdf_win_update_store* store);                 /* malloc'd JSON */
void spdf_win_update_store_clear(spdf_win_update_store* store);

/* --- 6. verification (spdf_win_updater_verify.cpp) ----------------------- */

/* The pinned publisher: the SHA-256 thumbprint of the leaf certificate that
 * signs ShenzhenPDF-win-x64.exe, 64 lower-case hex digits. "" until a
 * certificate exists -- and "" means every verification FAILS. */
const char* spdf_win_updater_pinned_thumbprint(void);

/* WinVerifyTrust, WINTRUST_ACTION_GENERIC_VERIFY_V2, embedded signature only
 * (a catalog-signed file is "unsigned" here, which is what we want for a
 * download). 1 when the chain verifies. `err` gets a sentence on failure. */
int spdf_win_updater_verify_authenticode(const wchar_t* path, char* err, size_t err_len);
/* The leaf signer's SHA-256 thumbprint as 64 lower-case hex digits. 0 when the
 * file carries no embedded signature. */
int spdf_win_updater_signer_thumbprint(const wchar_t* path, char* out_hex, size_t out_len);
/* THE trust boundary: authenticode AND thumbprint == pin. An empty pin fails
 * with a message that says the build cannot verify updates. */
int spdf_win_updater_verify_pinned(const wchar_t* path, const char* pinned_hex, char* err, size_t err_len);
/* The VERSIONINFO ProductVersion string of an exe ON DISK, not running. This
 * is how a staged download is checked against the tag before it is swapped
 * in, so a mismatched relaunch is caught before there is a relaunch. */
int spdf_win_updater_file_product_version(const wchar_t* path, char* out, size_t out_len);
/* SHA-256 of a file as 64 lower-case hex digits (CryptoAPI). */
int spdf_win_updater_sha256_file(const wchar_t* path, char* out_hex, size_t out_len);

/* --- 7. install (spdf_win_updater_install.cpp) --------------------------- */

/* %LOCALAPPDATA%\ShenzhenPDF\updates, created on demand; the store, the lock
 * and every download live there. The override exists for tests. */
int spdf_win_updater_dir(wchar_t* out, size_t out_len);
void spdf_win_updater_set_dir_override(const wchar_t* dir);

/* Read-modify-write of update.json under an exclusive LockFileEx on
 * update.lock in the same directory (the flock idiom of the other two ports).
 * The mutator returns non-zero to have the store written back. */
typedef int (*spdf_win_store_mutator)(spdf_win_update_store* store, void* user);
int spdf_win_updater_with_locked_store(spdf_win_store_mutator mutator, void* user);

/* The swap. `exe` is the installed (possibly running) binary, `staged` a
 * verified copy ON THE SAME VOLUME. rename(exe -> exe.old), rename(staged ->
 * exe); on failure the .old is renamed back and the working install is intact.
 * .old is deliberately left for the relaunch health check. */
int spdf_win_updater_swap_exe(const wchar_t* exe, const wchar_t* staged, char* err, size_t err_len);
/* Copies `src` to "<exe>.new" (same volume as `exe`) so the swap is atomic. */
int spdf_win_updater_stage_beside(const wchar_t* exe, const wchar_t* src, wchar_t* out_staged, size_t out_len,
                                  char* err, size_t err_len);

/* The relaunch health check, run once a few seconds after launch: consumes
 * pendingTag. Match => updateOk, <exe>.old deleted, returns 1 and copies the
 * tag into `out_tag` for a one-time banner. Mismatch => .old is KEPT, returns
 * -1 and copies the tag; the caller says where the previous app is. No update
 * in flight => 0, and an aged orphaned .old is swept. */
int spdf_win_updater_consume_pending(const wchar_t* exe, const char* running, char* out_tag, size_t out_len);

/* --- 8. the app wiring (spdf_win_updater_ui.cpp) ------------------------- */

/* Arm the timers on the UI thread that owns `hwnd` (an HWND, void* so this
 * header carries no <windows.h>). Returns at once; nothing touches disk or
 * network until SPDF_WIN_UPDATER_IDLE_DELAY_MS later. Idempotent. */
void spdf_win_updater_start_background(void* hwnd);
/* "Check for Updates...": bypasses the gate and the snooze, reports every
 * outcome in a dialog on `hwnd` -- up to date, available (with the highlights
 * as a bulleted list), or the failure. */
void spdf_win_updater_check_interactive(void* hwnd);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_UPDATER_H */

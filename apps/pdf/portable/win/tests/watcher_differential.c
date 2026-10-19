/* THE WATCHER DIFFERENTIAL: portable/win/src/spdf_win_watcher_logic.h versus the
 * GTK4 original it was transcribed from, portable/linux/gtk4/spdf_watcher_logic.c
 * (compiled here with SPDF_WATCHER_TESTING, exactly as its own tests/
 * watcher_test.c compiles it), both in ONE MSVC binary, driven with identical
 * inputs, compared for EXACT equality.
 *
 * The shadow-copy NAME is compared byte for byte over paths that are already
 * canonical on both sides (the port expects a canonical path; GTK canonicalises
 * itself, and a canonical POSIX path is a fixed point of that). Since the two
 * SHA-256 implementations are independent (glib_shim_watcher/glib.h), agreement
 * on the digest is real evidence. The containment rule is compared over the
 * same POSIX paths; the port takes canonical forms, so the differential
 * canonicalises with the shim's g_canonicalize_filename first, on the domain
 * where the port's own form differs only in separator.
 *
 * Not named *_test.c on purpose. Build and run with
 *   portable\win\tests\watcher-differential-native.cmd
 * and judge it by its exit code.
 */
#define SPDF_WATCHER_TESTING 1

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "spdf_watcher_logic.c"

#include "spdf_win_palette_filter.h" /* the port's canonical form, for the containment inputs */
#include "spdf_win_watcher_logic.h"

static int mismatches;
static long comparisons;

static void same_i(const char* what, long long win, long long gtk) {
    comparisons++;
    if (win != gtk) {
        printf("DIFFER %s: win=%lld gtk=%lld\n", what, win, gtk);
        mismatches++;
    }
}

static void same_s(const char* what, const char* win, const char* gtk) {
    comparisons++;
    if ((win == NULL) != (gtk == NULL) || (win && gtk && strcmp(win, gtk) != 0)) {
        printf("DIFFER %s: win=\"%s\" gtk=\"%s\"\n", what, win ? win : "(null)", gtk ? gtk : "(null)");
        mismatches++;
    }
}

/* The port's canonical form differs from glib's in the separator only, on this
 * domain; map it back so the containment inputs are comparable. */
static void to_posix(char* s) {
    for (; *s; ++s)
        if (*s == '\\') *s = '/';
}

static void differential_debounce(void) {
    static const long long delays[] = {1, 1000, 500 * 1000, 999999, 5000000};
    static const long long nows[] = {0, 1, 999, 1000, 100000, 449999, 450000, 949999, 950000, 950001, 2000000, 9999999};
    int d, a, b, c;
    char label[128];
    for (d = 0; d < 5; ++d)
        for (a = 0; a < 12; ++a)
            for (b = 0; b < 12; ++b)
                for (c = 0; c < 12; ++c) {
                    SpdfWinWatcherDebounce wd = {0};
                    SpdfWatcherDebounce gd = {0};
                    snprintf(label, sizeof(label), "debounce(d=%d,a=%d,b=%d,c=%d)", d, a, b, c);
                    same_i(label, spdf_win_watcher_debounce_fire(&wd, nows[a]), spdf_watcher_debounce_fire(&gd, nows[a]));
                    same_i(label, spdf_win_watcher_debounce_event(&wd, nows[a], delays[d]),
                           spdf_watcher_debounce_event(&gd, nows[a], delays[d]));
                    same_i(label, spdf_win_watcher_debounce_fire(&wd, nows[b]), spdf_watcher_debounce_fire(&gd, nows[b]));
                    same_i(label, spdf_win_watcher_debounce_event(&wd, nows[b], delays[d]),
                           spdf_watcher_debounce_event(&gd, nows[b], delays[d]));
                    same_i(label, spdf_win_watcher_debounce_fire(&wd, nows[c]), spdf_watcher_debounce_fire(&gd, nows[c]));
                    same_i(label, spdf_win_watcher_debounce_fire(&wd, nows[c] + 1), spdf_watcher_debounce_fire(&gd, nows[c] + 1));
                    same_i(label, wd.fire_at_us, gd.fire_at_us);
                }
}

static const char* const kPaths[] = {
    "/docs/Manual.pdf",   "/docs/Other.pdf",  "/docs/Manual",       "/docs/SHEET.PDF", "/a/b/c/d/e/f/g.epub",
    "/x/.hidden",         "/x/trailing.",     "/x/a.tar.gz",        "/",               "/single",
    "/very/long/path/with/many/components/and/a/long/file/name/that/exceeds/sixty/four/bytes/of/digest/input.pdf",
    "/caf\xC3\xA9/r\xC3\xA9sum\xC3\xA9.pdf", "/docs/a b c.pdf",
};
#define N_PATHS ((int)(sizeof(kPaths) / sizeof(kPaths[0])))

static void differential_shadow_name(void) {
    int i;
    char label[256], win[128];
    for (i = 0; i < N_PATHS; ++i) {
        char* gtk = spdf_watcher_shadow_copy_name(kPaths[i]);
        int ok = spdf_win_watcher_shadow_copy_name(kPaths[i], win, sizeof(win));
        snprintf(label, sizeof(label), "shadow_copy_name(\"%s\")", kPaths[i]);
        same_s(label, ok ? win : NULL, gtk);
        g_free(gtk);
    }
    same_s("shadow_copy_name(NULL)", spdf_win_watcher_shadow_copy_name(NULL, win, sizeof(win)) ? win : NULL,
           spdf_watcher_shadow_copy_name(NULL));
    same_s("shadow_copy_name(\"\")", spdf_win_watcher_shadow_copy_name("", win, sizeof(win)) ? win : NULL,
           spdf_watcher_shadow_copy_name(""));
}

static void differential_path_is_shadow_in(void) {
    static const char* const dirs[] = {"/home/u/.local/share/shenzhenpdf/ReadOnlyCopies",
                                       "/home/u/.local/share/shenzhenpdf/./ReadOnlyCopies", "/tmp", "/"};
    static const char* const names[] = {"ro-0123456789abcdef0123456789abcdef.pdf", "ro-0123456789ABCDEF0123456789abcdef.PDF",
                                        "ro-0123456789abcdef0123456789abcdef", "ro-0123456789abcdef0123456789abcde.pdf",
                                        "ro-zz.pdf", "x.pdf", "ro-0123456789abcdef0123456789abcdef.a.b",
                                        "ro-0123456789abcdef0123456789abcdefg.pdf", ""};
    static const char* const bases[] = {"/home/u/.local/share/shenzhenpdf/ReadOnlyCopies", "/tmp",
                                        "/home/u/.local/share/shenzhenpdf/ReadOnlyCopies/sub",
                                        "/home/u/.local/share/shenzhenpdf/ReadOnlyCopiesX", "/"};
    int d, n, b;
    char label[256];
    for (d = 0; d < 4; ++d)
        for (b = 0; b < 5; ++b)
            for (n = 0; n < 9; ++n) {
                char path[512], cpath[512], cdir[512];
                /* No "//" prefix: on Windows that is a UNC root, legitimately a
                 * different path from "/", so it lies outside the shared domain. */
                snprintf(path, sizeof(path), "%s%s%s", bases[b], strcmp(bases[b], "/") == 0 ? "" : "/", names[n]);
                /* The port's arguments are canonical forms; produce them with
                 * its own canonicaliser and map the separator back. */
                spdf_win_palette_canonical_path(path, cpath, sizeof(cpath));
                spdf_win_palette_canonical_path(dirs[d], cdir, sizeof(cdir));
                to_posix(cpath);
                to_posix(cdir);
                snprintf(label, sizeof(label), "path_is_shadow_in(\"%s\", dir=%d)", path, d);
                same_i(label, spdf_win_watcher_path_is_shadow_in(cpath, cdir), spdf_watcher_path_is_shadow_in(path, dirs[d]));
            }
    same_i("path_is_shadow_in(NULL)", spdf_win_watcher_path_is_shadow_in(NULL, "/tmp"),
           spdf_watcher_path_is_shadow_in(NULL, "/tmp"));
    same_i("path_is_shadow_in(dir NULL)", spdf_win_watcher_path_is_shadow_in("/tmp/x", NULL),
           spdf_watcher_path_is_shadow_in("/tmp/x", NULL));
    same_i("path_is_shadow_in(\"\")", spdf_win_watcher_path_is_shadow_in("", "/tmp"),
           spdf_watcher_path_is_shadow_in("", "/tmp"));
}

static void differential_decisions(void) {
    static const unsigned long long sizes[] = {0, 1, 100, 101, 250, 18446744073709551615ULL};
    static const double times[] = {0.0, 5.0, 5.0005, 5.001, 5.0011, 5.002, 9.0, -1.0, 1e12};
    int a, b, c, d, e, r;
    char label[128];
    for (e = 0; e < 2; ++e)
        for (r = 0; r < 2; ++r)
            for (a = 0; a < 2; ++a) {
                snprintf(label, sizeof(label), "read_only_verdict(%d,%d,%d)", e, r, a);
                same_i(label, spdf_win_watcher_read_only_verdict(e, r, a), spdf_watcher_read_only_verdict(e, r, a));
            }
    for (a = 0; a < 6; ++a)
        for (b = 0; b < 9; ++b)
            for (c = 0; c < 6; ++c)
                for (d = 0; d < 9; ++d) {
                    snprintf(label, sizeof(label), "stat_differs(%d,%d,%d,%d)", a, b, c, d);
                    same_i(label, spdf_win_watcher_stat_differs(sizes[a], times[b], sizes[c], times[d]),
                           spdf_watcher_stat_differs(sizes[a], times[b], sizes[c], times[d]));
                    for (e = 0; e < 2; ++e) {
                        snprintf(label, sizeof(label), "copy_reusable(%d,%d,%d,%d,%d)", e, a, b, c, d);
                        same_i(label, spdf_win_watcher_copy_reusable(e, sizes[a], times[b], sizes[c], times[d]),
                               spdf_watcher_copy_reusable(e, sizes[a], times[b], sizes[c], times[d]));
                    }
                }
    for (r = 0; r < 2; ++r)
        for (b = 0; b < 9; ++b)
            for (d = 0; d < 9; ++d) {
                double now = 10000.0 + times[d], copy = 10000.0 + times[d] - times[b] * 10.0;
                snprintf(label, sizeof(label), "sweep_should_delete(%d,%d,%d)", r, b, d);
                same_i(label, spdf_win_watcher_sweep_should_delete(r, copy, now), spdf_watcher_sweep_should_delete(r, copy, now));
                same_i(label, spdf_win_watcher_sweep_should_delete(r, now - 59.9, now), spdf_watcher_sweep_should_delete(r, now - 59.9, now));
                same_i(label, spdf_win_watcher_sweep_should_delete(r, now - 60.1, now), spdf_watcher_sweep_should_delete(r, now - 60.1, now));
            }
    same_i("DEBOUNCE_MS", SPDF_WIN_WATCHER_DEBOUNCE_MS, SPDF_WATCHER_DEBOUNCE_MS);
    same_i("MISSING_RETRY_MS", SPDF_WIN_WATCHER_MISSING_RETRY_MS, SPDF_WATCHER_MISSING_RETRY_MS);
    same_i("MISSING_RETRIES", SPDF_WIN_WATCHER_MISSING_RETRIES, SPDF_WATCHER_MISSING_RETRIES);
    same_i("SWEEP_RECENCY_S", (long long)SPDF_WIN_WATCHER_SWEEP_RECENCY_S, (long long)SPDF_WATCHER_SWEEP_RECENCY_S);
    same_i("MTIME_TOLERANCE x 1e6", (long long)(SPDF_WIN_WATCHER_MTIME_TOLERANCE * 1e6),
           (long long)(SPDF_WATCHER_MTIME_TOLERANCE * 1e6));
}

int main(void) {
    differential_debounce();
    differential_shadow_name();
    differential_path_is_shadow_in();
    differential_decisions();
    printf("watcher differential: %ld comparisons, %d mismatches\n", comparisons, mismatches);
    if (comparisons == 0) return 2;
    return mismatches ? 1 : 0;
}

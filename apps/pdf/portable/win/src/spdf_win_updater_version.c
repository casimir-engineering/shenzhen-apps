/* spdf_win_updater_version.c — version compare for the updater.
 *
 * A transcription of portable/linux/gtk4/spdf_update_version.c (75 lines,
 * toolkit-free) with GArray replaced by a fixed array: a release identity is
 * YY.M.D-BUILD, four fields, and anything with more than sixteen is not one of
 * ours and compares as "no ordering decision", which can never authorise an
 * update. Same behaviour as the original for every input that has an answer.
 */
#include "spdf_win_updater.h"

#include <stdlib.h>
#include <string.h>

#define SPDF_WIN_VERSION_MAX_FIELDS 16

/* Split on '.', '-' and ' ', numeric fields only. Returns the field count, or
 * 0 for NULL/empty/malformed input (a letter anywhere is malformed: "v26.9.2"
 * is not a version this frontend ever emits, and treating it as 26.9.2 would
 * be a guess in the one place a guess must not authorise anything). */
static int version_components(const char* version, long long* out, int cap) {
    const char* p = version;
    int n = 0;

    if (!p || !*p) return 0;
    while (*p) {
        char* end = NULL;
        long long value;

        while (*p == '.' || *p == '-' || *p == ' ') p++;
        if (!*p) break;
        if (*p < '0' || *p > '9') return 0; /* strtoll would accept a sign or whitespace here */
        value = strtoll(p, &end, 10);
        if (end == p) return 0;
        if (*end && *end != '.' && *end != '-' && *end != ' ') return 0;
        if (n == cap) return 0;
        out[n++] = value;
        p = end;
    }
    return n;
}

int spdf_win_updater_compare_versions(const char* a, const char* b) {
    long long ca[SPDF_WIN_VERSION_MAX_FIELDS];
    long long cb[SPDF_WIN_VERSION_MAX_FIELDS];
    int na = version_components(a, ca, SPDF_WIN_VERSION_MAX_FIELDS);
    int nb = version_components(b, cb, SPDF_WIN_VERSION_MAX_FIELDS);
    int n, i;

    if (na == 0 || nb == 0) return 0;
    n = na > nb ? na : nb;
    for (i = 0; i < n; ++i) {
        long long va = i < na ? ca[i] : 0; /* zero-pad the shorter side: 26.9.2 == 26.9.2-0 */
        long long vb = i < nb ? cb[i] : 0;
        if (va < vb) return -1;
        if (va > vb) return 1;
    }
    return 0;
}

int spdf_win_updater_versions_match_release_target(const char* target, const char* running) {
    long long ct[SPDF_WIN_VERSION_MAX_FIELDS];
    long long cr[SPDF_WIN_VERSION_MAX_FIELDS];
    int nt = version_components(target, ct, SPDF_WIN_VERSION_MAX_FIELDS);
    int nr = version_components(running, cr, SPDF_WIN_VERSION_MAX_FIELDS);
    int i;

    /* The relaunch health check wants the COMPLETE identity on both sides. A
     * running "26.9.2" against a pending "26.9.2-1" is not a match: it means the
     * build that came up is not the build that was installed. */
    if (nt != 4 || nr != 4) return 0;
    for (i = 0; i < 4; ++i)
        if (ct[i] != cr[i]) return 0;
    return 1;
}

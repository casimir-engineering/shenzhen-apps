/* spdf_win_watcher_logic.h — the file watcher's DECISIONS, transcribed from
 * portable/linux/gtk4/spdf_watcher_logic.c (the glib-only half that
 * tests/watcher_test.c pins), themselves the mac's SPDFMacFileWatcher and
 * read-only shadow-copy rules.
 *
 * Ported, not re-derived (windows-port-plan.md 2.3), and compared against the
 * original in portable/win/tests/watcher_differential.c: the same GTK source is
 * compiled by MSVC beside this header over a glib shim that carries a real
 * SHA-256, so even the shadow-copy NAME is compared byte for byte.
 *
 *   debounce      trailing-edge: every event pushes the deadline back; fires
 *                 once when it passes with no newer event (the mac timer re-arm)
 *   shadow name   "ro-<first 16 bytes of SHA-256 of the canonical path, hex>.<ext>"
 *                 so an unchanged source reclaims the same copy across launches
 *   is-shadow-in  lives DIRECTLY in the copies directory, with that shape
 *   read-only     an existing regular file the process cannot write; missing or
 *                 non-regular is NOT read-only (the missing-file UI owns those)
 *   stat differs  size, or mtime beyond the 1 ms tolerance roCopyModifiedAt
 *                 round-trips at
 *   copy reusable copy exists, a binding was recorded, and the source stat
 *                 still matches the stat the copy reflects -- no content read
 *   sweep         delete an unreferenced copy not touched in the last 60 s
 *
 * The one Windows-shaped difference: the canonical path used for the digest is
 * spdf_win_palette_canonical_path's (case folded, '\'-separated) rather than
 * g_canonicalize_filename's, because NTFS paths are case-insensitive. The
 * differential feeds both sides a path that is already canonical on both, so
 * the digest of identical bytes is compared. SHA-256 is here in portable C
 * (FIPS 180-4, ~70 lines) rather than through BCrypt so the name is computable
 * in a test with no Windows crypto provider and identical to the mac's
 * CC_SHA256 by construction.
 */
#ifndef SPDF_WIN_WATCHER_LOGIC_H
#define SPDF_WIN_WATCHER_LOGIC_H

#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_WL_INLINE static __inline
#else
#define SPDF_WIN_WL_INLINE static inline
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Effective mac coalescing: 0.4 s debounce + 0.1 s FSEvents latency. */
#define SPDF_WIN_WATCHER_DEBOUNCE_MS 500
/* Mac missing-file grace: 5 x 0.25 s before the stale UI. */
#define SPDF_WIN_WATCHER_MISSING_RETRY_MS 250
#define SPDF_WIN_WATCHER_MISSING_RETRIES 5
#define SPDF_WIN_WATCHER_SWEEP_RECENCY_S 60.0
#define SPDF_WIN_WATCHER_MTIME_TOLERANCE 0.001

typedef struct SpdfWinWatcherDebounce {
    long long fire_at_us; /* 0 = idle */
} SpdfWinWatcherDebounce;

/* spdf_watcher_debounce_event */
SPDF_WIN_WL_INLINE long long spdf_win_watcher_debounce_event(SpdfWinWatcherDebounce* d, long long now_us,
                                                             long long delay_us) {
    d->fire_at_us = now_us + delay_us;
    return d->fire_at_us;
}

/* spdf_watcher_debounce_fire */
SPDF_WIN_WL_INLINE int spdf_win_watcher_debounce_fire(SpdfWinWatcherDebounce* d, long long now_us) {
    if (d->fire_at_us == 0 || now_us < d->fire_at_us) return 0;
    d->fire_at_us = 0;
    return 1;
}

/* spdf_watcher_read_only_verdict */
SPDF_WIN_WL_INLINE int spdf_win_watcher_read_only_verdict(int exists, int is_regular, int writable) {
    return exists && is_regular && !writable;
}

/* spdf_watcher_stat_differs */
SPDF_WIN_WL_INLINE int spdf_win_watcher_stat_differs(unsigned long long a_size, double a_mtime,
                                                     unsigned long long b_size, double b_mtime) {
    if (a_size != b_size) return 1;
    return fabs(a_mtime - b_mtime) > SPDF_WIN_WATCHER_MTIME_TOLERANCE;
}

/* spdf_watcher_copy_reusable */
SPDF_WIN_WL_INLINE int spdf_win_watcher_copy_reusable(int copy_exists, unsigned long long bound_size,
                                                      double bound_mtime, unsigned long long source_size,
                                                      double source_mtime) {
    if (!copy_exists || bound_mtime <= 0.0) return 0;
    return !spdf_win_watcher_stat_differs(bound_size, bound_mtime, source_size, source_mtime);
}

/* spdf_watcher_sweep_should_delete */
SPDF_WIN_WL_INLINE int spdf_win_watcher_sweep_should_delete(int referenced, double copy_mtime, double now) {
    return !referenced && (now - copy_mtime) > SPDF_WIN_WATCHER_SWEEP_RECENCY_S;
}

/* --- SHA-256 (FIPS 180-4), for the shadow-copy name ------------------------- */

SPDF_WIN_WL_INLINE unsigned int spdf_win_wl_rotr(unsigned int x, int n) { return (x >> n) | (x << (32 - n)); }

SPDF_WIN_WL_INLINE void spdf_win_wl_sha256_block(unsigned int h[8], const unsigned char* p) {
    static const unsigned int k[64] = {
        0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
        0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
        0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu, 0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
        0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
        0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
        0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
        0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
        0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u, 0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u};
    unsigned int w[64], a, b, c, d, e, f, g, hh, i;
    for (i = 0; i < 16; ++i)
        w[i] = ((unsigned int)p[i * 4] << 24) | ((unsigned int)p[i * 4 + 1] << 16) | ((unsigned int)p[i * 4 + 2] << 8) |
               (unsigned int)p[i * 4 + 3];
    for (i = 16; i < 64; ++i) {
        unsigned int s0 = spdf_win_wl_rotr(w[i - 15], 7) ^ spdf_win_wl_rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        unsigned int s1 = spdf_win_wl_rotr(w[i - 2], 17) ^ spdf_win_wl_rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (i = 0; i < 64; ++i) {
        unsigned int s1 = spdf_win_wl_rotr(e, 6) ^ spdf_win_wl_rotr(e, 11) ^ spdf_win_wl_rotr(e, 25);
        unsigned int ch = (e & f) ^ (~e & g);
        unsigned int t1 = hh + s1 + ch + k[i] + w[i];
        unsigned int s0 = spdf_win_wl_rotr(a, 2) ^ spdf_win_wl_rotr(a, 13) ^ spdf_win_wl_rotr(a, 22);
        unsigned int maj = (a & b) ^ (a & c) ^ (b & c);
        unsigned int t2 = s0 + maj;
        hh = g, g = f, f = e, e = d + t1, d = c, c = b, b = a, a = t1 + t2;
    }
    h[0] += a, h[1] += b, h[2] += c, h[3] += d, h[4] += e, h[5] += f, h[6] += g, h[7] += hh;
}

/* SHA-256 of `len` bytes into 32 bytes. */
SPDF_WIN_WL_INLINE void spdf_win_watcher_sha256(const unsigned char* data, size_t len, unsigned char out[32]) {
    unsigned int h[8] = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
                         0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u};
    unsigned char block[64];
    size_t i, rem;
    unsigned long long bits = (unsigned long long)len * 8u;
    for (i = 0; i + 64 <= len; i += 64) spdf_win_wl_sha256_block(h, data + i);
    rem = len - i;
    memset(block, 0, sizeof(block));
    if (rem) memcpy(block, data + i, rem);
    block[rem] = 0x80;
    if (rem >= 56) {
        spdf_win_wl_sha256_block(h, block);
        memset(block, 0, sizeof(block));
    }
    for (i = 0; i < 8; ++i) block[63 - i] = (unsigned char)(bits >> (8 * i));
    spdf_win_wl_sha256_block(h, block);
    for (i = 0; i < 8; ++i) {
        out[i * 4] = (unsigned char)(h[i] >> 24);
        out[i * 4 + 1] = (unsigned char)(h[i] >> 16);
        out[i * 4 + 2] = (unsigned char)(h[i] >> 8);
        out[i * 4 + 3] = (unsigned char)h[i];
    }
}

/* --- the shadow copy's name and place --------------------------------------- */

/* watcher_path_extension: the suffix after the last '.' of the last component,
 * "" when there is none, the dot leads, or nothing follows it. */
SPDF_WIN_WL_INLINE const char* spdf_win_watcher_extension(const char* path) {
    const char* base = path;
    const char* dot;
    const char* p;
    for (p = path; *p; ++p)
        if (*p == '/' || *p == '\\') base = p + 1;
    dot = strrchr(base, '.');
    if (!dot || dot == base || !dot[1]) return "";
    return dot + 1;
}

/* spdf_watcher_shadow_copy_name, over an ALREADY CANONICAL path (the caller
 * canonicalises; see the header comment). Writes "ro-<32 hex>.<ext>", ext
 * defaulting to "pdf". Returns 0 for an empty path or a buffer that does not
 * fit. */
SPDF_WIN_WL_INLINE int spdf_win_watcher_shadow_copy_name(const char* canonical_path, char* out, size_t out_cap) {
    static const char hex[] = "0123456789abcdef";
    unsigned char digest[32];
    const char* ext;
    size_t i, n;
    if (!out || !out_cap) return 0;
    out[0] = '\0';
    if (!canonical_path || !*canonical_path) return 0;
    ext = spdf_win_watcher_extension(canonical_path);
    if (!*ext) ext = "pdf";
    n = 3 + 32 + 1 + strlen(ext);
    if (n >= out_cap) return 0;
    spdf_win_watcher_sha256((const unsigned char*)canonical_path, strlen(canonical_path), digest);
    memcpy(out, "ro-", 3);
    for (i = 0; i < 16; ++i) {
        out[3 + i * 2] = hex[digest[i] >> 4];
        out[4 + i * 2] = hex[digest[i] & 0xF];
    }
    out[35] = '.';
    strcpy(out + 36, ext);
    return 1;
}

/* spdf_watcher_path_is_shadow_in, over canonical forms of both arguments:
 * `path` is "<copies_dir>\ro-<32 hex>.<something>" and nothing deeper. */
SPDF_WIN_WL_INLINE int spdf_win_watcher_path_is_shadow_in(const char* canonical_path, const char* canonical_dir) {
    size_t dir_len;
    const char* base;
    int n = 0;
    if (!canonical_path || !*canonical_path || !canonical_dir || !*canonical_dir) return 0;
    dir_len = strlen(canonical_dir);
    while (dir_len > 0 && (canonical_dir[dir_len - 1] == '\\' || canonical_dir[dir_len - 1] == '/')) dir_len--;
    if (strncmp(canonical_path, canonical_dir, dir_len) != 0) return 0;
    if (canonical_path[dir_len] != '\\' && canonical_path[dir_len] != '/') return 0;
    base = canonical_path + dir_len + 1;
    if (strchr(base, '\\') || strchr(base, '/')) return 0;
    if (strncmp(base, "ro-", 3) != 0) return 0;
    base += 3;
    while ((base[n] >= '0' && base[n] <= '9') || (base[n] >= 'a' && base[n] <= 'f') || (base[n] >= 'A' && base[n] <= 'F'))
        n++;
    return n == 32 && base[n] == '.' && base[n + 1] != '\0';
}

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_WATCHER_LOGIC_H */

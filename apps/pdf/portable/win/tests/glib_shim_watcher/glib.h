/* A glib shim for the WATCHER differential, layered on the shared one.
 *
 * Same arrangement as glib_shim_search and glib_shim_palette: the pure half of
 * portable/linux/gtk4/spdf_watcher_logic.c compiled by MSVC beside the port. What
 * that file needs beyond the shared shim is small and listed here:
 * g_canonicalize_filename, g_path_get_dirname/basename, g_str_has_prefix,
 * g_ascii_isxdigit, g_strdup_printf, and g_compute_checksum_for_string with
 * G_CHECKSUM_SHA256.
 *
 * THE SHA-256 HERE IS INDEPENDENT of the port's. spdf_win_watcher_logic.h
 * carries its own FIPS 180-4 implementation; this shim carries a second one,
 * written separately (a byte-at-a-time streaming form rather than the port's
 * block form), so that comparing the two shadow-copy names compares two
 * implementations of the digest and not one implementation with itself.
 * glib_shim_watcher/unistd.h and glib_shim_watcher/glib/gstdio.h beside this file
 * are stubs for the two POSIX headers the GTK source includes; the probing
 * functions they serve compile but are not compared (MSVC's _stat has 1 s mtime
 * resolution, a difference of platform and not of transcription).
 *
 * This is not a glib port and must not grow into one.
 */
#ifndef SPDF_GLIB_SHIM_WATCHER_H
#define SPDF_GLIB_SHIM_WATCHER_H

#include "../glib_shim/glib.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

typedef unsigned char guchar;
typedef long long gssize;

static int g_ascii_isxdigit(gchar c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

static gchar* g_strdup(const gchar* s) {
    size_t n;
    gchar* out;
    if (!s) return NULL;
    n = strlen(s);
    out = (gchar*)malloc(n + 1);
    if (!out) abort();
    memcpy(out, s, n + 1);
    return out;
}

static gchar* g_strdup_printf(const gchar* fmt, ...) {
    va_list ap;
    int n;
    gchar* out;
    va_start(ap, fmt);
    n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n < 0) abort();
    out = (gchar*)malloc((size_t)n + 1);
    if (!out) abort();
    va_start(ap, fmt);
    vsnprintf(out, (size_t)n + 1, fmt, ap);
    va_end(ap);
    return out;
}

static gboolean g_str_has_prefix(const gchar* s, const gchar* prefix) {
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

/* Lexical canonicalisation of an ABSOLUTE POSIX path (glib's own behaviour for
 * one: "//" collapsed, "." dropped, ".." resolved, no symlink resolution). */
static gchar* g_canonicalize_filename(const gchar* filename, const gchar* relative_to) {
    size_t n = 0;
    const char* p = filename;
    gchar* out = (gchar*)malloc(strlen(filename) + 2);
    (void)relative_to;
    if (!out) abort();
    if (*p != '/') abort(); /* the differential passes absolute paths only */
    out[n++] = '/';
    while (*p == '/') p++;
    while (*p) {
        const char* seg = p;
        size_t len;
        while (*p && *p != '/') p++;
        len = (size_t)(p - seg);
        while (*p == '/') p++;
        if (len == 0 || (len == 1 && seg[0] == '.')) continue;
        if (len == 2 && seg[0] == '.' && seg[1] == '.') {
            if (n > 1) {
                n--;
                while (n > 1 && out[n - 1] != '/') n--;
            }
            continue;
        }
        memcpy(out + n, seg, len);
        n += len;
        out[n++] = '/';
    }
    if (n > 1 && out[n - 1] == '/') n--;
    out[n] = '\0';
    return out;
}

static gchar* g_path_get_basename(const gchar* path) {
    const char* slash = strrchr(path, '/');
    return g_strdup(slash ? slash + 1 : path);
}

static gchar* g_path_get_dirname(const gchar* path) {
    const char* slash = strrchr(path, '/');
    gchar* out;
    if (!slash) return g_strdup(".");
    if (slash == path) return g_strdup("/");
    out = (gchar*)malloc((size_t)(slash - path) + 1);
    if (!out) abort();
    memcpy(out, path, (size_t)(slash - path));
    out[slash - path] = '\0';
    return out;
}

/* --- SHA-256, streaming form ------------------------------------------------- */

typedef enum { G_CHECKSUM_MD5, G_CHECKSUM_SHA1, G_CHECKSUM_SHA256 } GChecksumType;

typedef struct {
    unsigned int state[8];
    unsigned char buf[64];
    size_t buffered;
    unsigned long long total;
} GShimSha256;

static const unsigned int g_shim_sha_k[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98,
    0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8,
    0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819,
    0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
    0xc67178f2};

#define G_SHIM_ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void g_shim_sha_compress(GShimSha256* s) {
    unsigned int w[64], v[8];
    int i;
    for (i = 0; i < 16; ++i)
        w[i] = ((unsigned int)s->buf[4 * i] << 24) | ((unsigned int)s->buf[4 * i + 1] << 16) |
               ((unsigned int)s->buf[4 * i + 2] << 8) | s->buf[4 * i + 3];
    for (; i < 64; ++i)
        w[i] = w[i - 16] + (G_SHIM_ROTR(w[i - 15], 7) ^ G_SHIM_ROTR(w[i - 15], 18) ^ (w[i - 15] >> 3)) + w[i - 7] +
               (G_SHIM_ROTR(w[i - 2], 17) ^ G_SHIM_ROTR(w[i - 2], 19) ^ (w[i - 2] >> 10));
    memcpy(v, s->state, sizeof(v));
    for (i = 0; i < 64; ++i) {
        unsigned int t1 = v[7] + (G_SHIM_ROTR(v[4], 6) ^ G_SHIM_ROTR(v[4], 11) ^ G_SHIM_ROTR(v[4], 25)) +
                          ((v[4] & v[5]) ^ (~v[4] & v[6])) + g_shim_sha_k[i] + w[i];
        unsigned int t2 = (G_SHIM_ROTR(v[0], 2) ^ G_SHIM_ROTR(v[0], 13) ^ G_SHIM_ROTR(v[0], 22)) +
                          ((v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]));
        memmove(v + 1, v, 7 * sizeof(unsigned int));
        v[4] += t1;
        v[0] = t1 + t2;
    }
    for (i = 0; i < 8; ++i) s->state[i] += v[i];
}

static void g_shim_sha_byte(GShimSha256* s, unsigned char b) {
    s->buf[s->buffered++] = b;
    s->total++;
    if (s->buffered == 64) {
        g_shim_sha_compress(s);
        s->buffered = 0;
    }
}

static gchar* g_compute_checksum_for_string(GChecksumType type, const gchar* str, gssize length) {
    static const char hex[] = "0123456789abcdef";
    GShimSha256 s;
    unsigned long long bits;
    size_t n, i;
    gchar* out;
    if (type != G_CHECKSUM_SHA256) abort();
    n = length < 0 ? strlen(str) : (size_t)length;
    s.state[0] = 0x6a09e667u, s.state[1] = 0xbb67ae85u, s.state[2] = 0x3c6ef372u, s.state[3] = 0xa54ff53au;
    s.state[4] = 0x510e527fu, s.state[5] = 0x9b05688cu, s.state[6] = 0x1f83d9abu, s.state[7] = 0x5be0cd19u;
    s.buffered = 0;
    s.total = 0;
    for (i = 0; i < n; ++i) g_shim_sha_byte(&s, (unsigned char)str[i]);
    bits = s.total * 8u;
    g_shim_sha_byte(&s, 0x80);
    while (s.buffered != 56) g_shim_sha_byte(&s, 0);
    for (i = 0; i < 8; ++i) g_shim_sha_byte(&s, (unsigned char)(bits >> (56 - 8 * i)));
    out = (gchar*)malloc(65);
    if (!out) abort();
    for (i = 0; i < 8; ++i) {
        unsigned int v = s.state[i];
        out[i * 8] = hex[(v >> 28) & 15], out[i * 8 + 1] = hex[(v >> 24) & 15];
        out[i * 8 + 2] = hex[(v >> 20) & 15], out[i * 8 + 3] = hex[(v >> 16) & 15];
        out[i * 8 + 4] = hex[(v >> 12) & 15], out[i * 8 + 5] = hex[(v >> 8) & 15];
        out[i * 8 + 6] = hex[(v >> 4) & 15], out[i * 8 + 7] = hex[v & 15];
    }
    out[64] = '\0';
    return out;
}

#endif /* SPDF_GLIB_SHIM_WATCHER_H */

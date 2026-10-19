/* spdf_win_sidebar_utf8.h — the glib replacements spdf_win_sidebar_results.h
 * needs: UTF-8 walked the way glib walks it, glib's whitespace set, and the one
 * casefold.
 *
 * Split out of the transcription header so that file is the transcription and
 * this one is the platform: everything here replaces a g_utf8_* / g_unichar_* /
 * g_utf8_casefold call, and the differential
 * (portable/win/tests/sidebar_differential.c) drives each walker against
 * glib's own algorithm in the shim. The casefold is the one thing the shim
 * cannot reproduce; spdf_win_sidebar_results.h's header says what that means.
 *
 * PURE, HEADER-ONLY, C and C++ under MSVC. <windows.h> for the casefold only.
 */
#ifndef SPDF_WIN_SIDEBAR_UTF8_H
#define SPDF_WIN_SIDEBAR_UTF8_H

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <limits.h>
#include <stdlib.h>
#include <string.h>

#include "spdf_win_search.h" /* spdf_win_search_dup_bytes */

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_SR_INLINE __inline
#else
#define SPDF_WIN_SR_INLINE inline
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* --------------------------------------------------------------------------
 * UTF-8, the way glib walks it (glib/gutf8.c). g_utf8_skip is a 256-entry
 * table; this is that table as a function of the lead byte. */
static SPDF_WIN_SR_INLINE int spdf_win_sidebar_utf8_skip(unsigned char c) {
    if (c < 0xC0) return 1; /* ASCII and stray continuation bytes */
    if (c < 0xE0) return 2;
    if (c < 0xF0) return 3;
    if (c < 0xF8) return 4;
    if (c < 0xFC) return 5;
    if (c < 0xFE) return 6;
    return 1;
}

static SPDF_WIN_SR_INLINE const char* spdf_win_sidebar_utf8_next(const char* p) {
    return p + spdf_win_sidebar_utf8_skip((unsigned char)*p);
}

/* g_utf8_get_char: no validation; a malformed sequence decodes to something
 * rather than failing, exactly as the original does. */
static SPDF_WIN_SR_INLINE unsigned spdf_win_sidebar_utf8_get(const char* p) {
    unsigned char c = (unsigned char)*p;
    unsigned ch;
    int len, i;
    if (c < 0x80) return c;
    if (c < 0xC0) return (unsigned)-1;
    if (c < 0xE0) {
        len = 2;
        ch = c & 0x1F;
    } else if (c < 0xF0) {
        len = 3;
        ch = c & 0x0F;
    } else if (c < 0xF8) {
        len = 4;
        ch = c & 0x07;
    } else if (c < 0xFC) {
        len = 5;
        ch = c & 0x03;
    } else if (c < 0xFE) {
        len = 6;
        ch = c & 0x01;
    } else {
        return (unsigned)-1;
    }
    for (i = 1; i < len; ++i) {
        unsigned char cc = (unsigned char)p[i];
        if ((cc & 0xC0) != 0x80) return (unsigned)-1;
        ch = (ch << 6) | (cc & 0x3F);
    }
    return ch;
}

/* g_utf8_strlen(p, max): max < 0 means NUL-terminated; max > 0 examines at
 * most max bytes and does not count a trailing partial character. */
static SPDF_WIN_SR_INLINE long spdf_win_sidebar_utf8_strlen(const char* p, long max) {
    long len = 0;
    const char* start = p;
    if (!p) return 0;
    if (max < 0) {
        while (*p) {
            p = spdf_win_sidebar_utf8_next(p);
            ++len;
        }
        return len;
    }
    if (max == 0 || !*p) return 0;
    p = spdf_win_sidebar_utf8_next(p);
    while (p - start < max && *p) {
        ++len;
        p = spdf_win_sidebar_utf8_next(p);
    }
    if (p - start <= max) ++len;
    return len;
}

static SPDF_WIN_SR_INLINE const char* spdf_win_sidebar_utf8_offset_to_pointer(const char* str, long offset) {
    const char* s = str;
    while (offset-- > 0) s = spdf_win_sidebar_utf8_next(s);
    return s;
}

/* g_unichar_isspace: Zs, Zl, Zp, plus \t \n \v \f \r. Spelled out. */
static SPDF_WIN_SR_INLINE int spdf_win_sidebar_unichar_isspace(unsigned c) {
    if (c >= 0x09 && c <= 0x0D) return 1;
    if (c == 0x20 || c == 0xA0 || c == 0x1680) return 1;
    if (c >= 0x2000 && c <= 0x200A) return 1;
    if (c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000) return 1;
    return 0;
}

/* The casefold (see difference 2 in the header). `len` < 0 means
 * NUL-terminated. Never returns NULL unless malloc fails; malformed UTF-8 falls
 * back to an ASCII-only lowercase copy so the snippet is still shown. */
static SPDF_WIN_SR_INLINE char* spdf_win_sidebar_casefold(const char* s, long len) {
    size_t n;
    int wide_n, low_n, out_n;
    wchar_t* wide;
    wchar_t* low;
    char* out;
    size_t i;

    if (!s) s = "";
    n = len < 0 ? strlen(s) : (size_t)len;
    if (n == 0) return spdf_win_search_dup_bytes("", 0);
    wide_n = n > (size_t)INT_MAX ? 0 : MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, (int)n, NULL, 0);
    if (wide_n > 0) {
        wide = (wchar_t*)malloc(sizeof(wchar_t) * (size_t)wide_n);
        low = (wchar_t*)malloc(sizeof(wchar_t) * (size_t)wide_n);
        if (wide && low && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, (int)n, wide, wide_n) == wide_n) {
            low_n = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, wide, wide_n, low, wide_n, NULL, NULL, 0);
            if (low_n > 0) {
                out_n = WideCharToMultiByte(CP_UTF8, 0, low, low_n, NULL, 0, NULL, NULL);
                out = out_n > 0 ? (char*)malloc((size_t)out_n + 1) : NULL;
                if (out && WideCharToMultiByte(CP_UTF8, 0, low, low_n, out, out_n, NULL, NULL) == out_n) {
                    out[out_n] = '\0';
                    free(wide);
                    free(low);
                    return out;
                }
                free(out);
            }
        }
        free(wide);
        free(low);
    }
    out = spdf_win_search_dup_bytes(s, n);
    if (!out) return NULL;
    for (i = 0; i < n; ++i)
        if (out[i] >= 'A' && out[i] <= 'Z') out[i] = (char)(out[i] - 'A' + 'a');
    return out;
}

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_SIDEBAR_UTF8_H */

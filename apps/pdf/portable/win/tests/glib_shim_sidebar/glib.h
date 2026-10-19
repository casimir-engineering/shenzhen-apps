/* A glib shim for the SIDEBAR differential, layered on the search one.
 *
 * Same arrangement as portable/win/tests/glib_shim_search/glib.h, and for the
 * same reason that file gives: the shared shim must not grow, and each
 * differential adds exactly what its GTK header touches, in a directory that
 * only its own .cmd puts first on the include path. This one reaches the search
 * shim by relative path for GArray, g_strdup, g_strndup and g_strstrip, and the
 * search shim reaches the shared one for the typedefs and MAX/MIN/CLAMP -- so
 * every glib macro body is still defined in exactly one place.
 *
 * WHAT IS AND IS NOT REAL HERE, because a differential is only as honest as its
 * shim.
 *
 *   - g_utf8_next_char, g_utf8_get_char, g_utf8_strlen and
 *     g_utf8_offset_to_pointer are glib's OWN algorithms (glib/gutf8.c), written
 *     here independently of the port: the skip table is the literal 256-entry
 *     table, get_char is the UTF8_GET macro, strlen is the two-branch loop with
 *     the partial-character rule. The port re-spells all four and this is what
 *     checks the re-spelling.
 *   - g_unichar_isspace is the Zs/Zl/Zp set plus \t \n \v \f \r, again spelled
 *     independently.
 *   - g_markup_escape_text is glib's append_escaped_text: the five entities and
 *     the control ranges as numeric character references.
 *   - g_utf8_casefold IS NOT REAL. glib's does full Unicode case folding from
 *     its own tables; there is no way to reproduce that in a shim without
 *     shipping the tables, so this aliases the PORT's casefold
 *     (LCMapStringEx lowercase). The consequence is stated in
 *     spdf_win_sidebar_results.h's header: the differential checks every piece
 *     of structure around the fold and takes the fold itself as given. A
 *     difference in what the fold returns for "ß" is therefore invisible here,
 *     by construction, and is said so rather than hidden.
 *   - g_strconcat is real (variadic, NULL-terminated).
 *
 * Everything is `static`, so this header emits nothing a second translation unit
 * could collide with. Not a glib port; must not grow into one.
 */
#ifndef SPDF_GLIB_SHIM_SIDEBAR_H
#define SPDF_GLIB_SHIM_SIDEBAR_H

#include "../glib_shim_search/glib.h"

#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

/* The port, for the one function this shim cannot honestly supply. */
#include "spdf_win_sidebar_results.h"

#ifndef G_MININT
#define G_MININT INT_MIN
#endif

typedef long glong;
typedef unsigned int gunichar;

/* --- UTF-8, glib/gutf8.c ------------------------------------------------- */

/* The literal g_utf8_skip table. */
static const char g_shim_utf8_skip_data[256] = {
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 1, 1};

#define g_utf8_next_char(p) ((p) + g_shim_utf8_skip_data[*(const unsigned char*)(p)])

/* UTF8_COMPUTE + UTF8_GET, as in gutf8.c. Invalid sequences decode to
 * (gunichar)-1 the way glib's do. */
static gunichar g_utf8_get_char(const gchar* p) {
    unsigned char c = (unsigned char)*p;
    int i, mask = 0, len = 0;
    gunichar result;
    if (c < 128) {
        len = 1;
        mask = 0x7f;
    } else if ((c & 0xe0) == 0xc0) {
        len = 2;
        mask = 0x1f;
    } else if ((c & 0xf0) == 0xe0) {
        len = 3;
        mask = 0x0f;
    } else if ((c & 0xf8) == 0xf0) {
        len = 4;
        mask = 0x07;
    } else if ((c & 0xfc) == 0xf8) {
        len = 5;
        mask = 0x03;
    } else if ((c & 0xfe) == 0xfc) {
        len = 6;
        mask = 0x01;
    } else {
        return (gunichar)-1;
    }
    result = c & mask;
    for (i = 1; i < len; ++i) {
        if (((unsigned char)p[i] & 0xc0) != 0x80) return (gunichar)-1;
        result <<= 6;
        result |= (unsigned char)p[i] & 0x3f;
    }
    return result;
}

/* glib takes gssize; long is the shim's spelling of it. */
typedef long long gssize;
static glong g_shim_utf8_strlen(const gchar* p, gssize max) {
    glong len = 0;
    const gchar* start = p;
    if (!p) return 0;
    if (max < 0) {
        while (*p) {
            p = g_utf8_next_char(p);
            ++len;
        }
    } else {
        if (max == 0 || !*p) return 0;
        p = g_utf8_next_char(p);
        while (p - start < max && *p) {
            ++len;
            p = g_utf8_next_char(p);
        }
        /* only do the last len increment if we got a complete char (don't
         * count partial chars) */
        if (p - start <= max) ++len;
    }
    return len;
}
#define g_utf8_strlen g_shim_utf8_strlen

static gchar* g_utf8_offset_to_pointer(const gchar* str, glong offset) {
    const gchar* s = str;
    if (offset > 0)
        while (offset--) s = g_utf8_next_char(s);
    return (gchar*)s;
}

/* Zs, Zl, Zp and the five ASCII controls. */
static gboolean g_unichar_isspace(gunichar c) {
    switch (c) {
        case 0x09: case 0x0A: case 0x0B: case 0x0C: case 0x0D:
        case 0x20: case 0xA0: case 0x1680:
        case 0x2000: case 0x2001: case 0x2002: case 0x2003: case 0x2004: case 0x2005:
        case 0x2006: case 0x2007: case 0x2008: case 0x2009: case 0x200A:
        case 0x2028: case 0x2029: case 0x202F: case 0x205F: case 0x3000:
            return TRUE;
        default:
            return FALSE;
    }
}

/* NOT glib's fold -- see the header comment. */
static gchar* g_utf8_casefold(const gchar* str, gssize len) { return spdf_win_sidebar_casefold(str, (long)len); }

/* --- markup, glib/gmarkup.c append_escaped_text ---------------------------- */

static gchar* g_markup_escape_text(const gchar* text, gssize length) {
    const gchar* p;
    const gchar* end;
    size_t cap, n = 0;
    gchar* out;

    if (length < 0) length = (gssize)strlen(text);
    end = text + length;
    cap = (size_t)length * 6 + 16;
    out = (gchar*)malloc(cap);
    if (!out) return NULL;
    p = text;
    while (p < end) {
        const gchar* next = g_utf8_next_char(p);
        char buf[16];
        const char* rep = NULL;
        if (next > end) next = end;
        switch (*p) {
            case '&': rep = "&amp;"; break;
            case '<': rep = "&lt;"; break;
            case '>': rep = "&gt;"; break;
            case '\'': rep = "&apos;"; break;
            case '"': rep = "&quot;"; break;
            default: {
                gunichar c = g_utf8_get_char(p);
                if ((0x1 <= c && c <= 0x8) || (0xb <= c && c <= 0xc) || (0xe <= c && c <= 0x1f) ||
                    (0x7f <= c && c <= 0x84) || (0x86 <= c && c <= 0x9f)) {
                    snprintf(buf, sizeof(buf), "&#x%x;", c);
                    rep = buf;
                }
                break;
            }
        }
        if (rep) {
            size_t rl = strlen(rep);
            if (n + rl + 1 > cap) break;
            memcpy(out + n, rep, rl);
            n += rl;
        } else {
            size_t cl = (size_t)(next - p);
            if (n + cl + 1 > cap) break;
            memcpy(out + n, p, cl);
            n += cl;
        }
        p = next;
    }
    out[n] = 0;
    return out;
}

static gchar* g_strconcat(const gchar* first, ...) {
    va_list ap;
    size_t total = 0;
    const gchar* s;
    gchar* out;
    gchar* w;

    if (!first) return g_strdup("");
    va_start(ap, first);
    for (s = first; s; s = va_arg(ap, const gchar*)) total += strlen(s);
    va_end(ap);
    out = (gchar*)malloc(total + 1);
    if (!out) return NULL;
    w = out;
    va_start(ap, first);
    for (s = first; s; s = va_arg(ap, const gchar*)) {
        size_t l = strlen(s);
        memcpy(w, s, l);
        w += l;
    }
    va_end(ap);
    *w = 0;
    return out;
}

#endif /* SPDF_GLIB_SHIM_SIDEBAR_H */

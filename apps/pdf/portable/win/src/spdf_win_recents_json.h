/* spdf_win_recents_json.h — the JSON reader and emitter behind the recents,
 * per-document and favorites stores (spdf_win_recents.c, spdf_win_favorites.c).
 *
 * NOT A SECOND ON-DISK FORMAT. The file on disk is YAML with exactly one codec,
 * portable/core/spdf_yaml.c, reached through spdf_win_state.h; what lives here
 * is the in-memory JSON marshalling every frontend does on its own side of that
 * codec (NSJSONSerialization on the mac, spdf_state.c's hand-rolled scanner on
 * GTK). spdf_win_session_json.h is the session module's copy of the same idea;
 * this one is deliberately separate so the two modules do not share a private
 * header across an ownership line, and because the stores here need one thing
 * the session does not: member iteration over an object whose KEYS are data
 * (documents.yaml is keyed by document path).
 *
 * Header-only, static, included by two translation units. Numbers are read and
 * written by hand rather than through strtod/printf because those are
 * locale-dependent on the decimal separator (spdf_state.c shipped that bug once,
 * see append_json_fixed there).
 */
#ifndef SPDF_WIN_RECENTS_JSON_H
#define SPDF_WIN_RECENTS_JSON_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* --- output ---------------------------------------------------------------- */

typedef struct rj_buf {
    char* data;
    size_t len;
    size_t cap;
    int failed;
} rj_buf;

static void rj_put(rj_buf* b, const char* text, size_t n) {
    if (b->failed || n == 0) return;
    if (b->len + n + 1 > b->cap) {
        size_t want = b->cap ? b->cap * 2 : 1024;
        char* grown;
        while (want < b->len + n + 1) want *= 2;
        grown = (char*)realloc(b->data, want);
        if (!grown) {
            b->failed = 1;
            return;
        }
        b->data = grown;
        b->cap = want;
    }
    memcpy(b->data + b->len, text, n);
    b->len += n;
    b->data[b->len] = '\0';
}

static void rj_puts(rj_buf* b, const char* text) { rj_put(b, text, strlen(text)); }

/* Same escapes as spdf_yaml.c's own JSON emitter, so a value round-trips
 * byte-stable through the codec. UTF-8 goes out raw. */
static void rj_emit_string(rj_buf* b, const char* text) {
    const unsigned char* p = (const unsigned char*)(text ? text : "");
    rj_puts(b, "\"");
    for (; *p; ++p) {
        char escape[8];
        const char* replacement = NULL;
        if (*p == '"') replacement = "\\\"";
        else if (*p == '\\') replacement = "\\\\";
        else if (*p == '\b') replacement = "\\b";
        else if (*p == '\f') replacement = "\\f";
        else if (*p == '\n') replacement = "\\n";
        else if (*p == '\r') replacement = "\\r";
        else if (*p == '\t') replacement = "\\t";
        else if (*p < 0x20) {
            snprintf(escape, sizeof(escape), "\\u%04x", (unsigned)*p);
            replacement = escape;
        }
        if (replacement) rj_puts(b, replacement);
        else rj_put(b, (const char*)p, 1);
    }
    rj_puts(b, "\"");
}

static void rj_emit_int(rj_buf* b, long long value) {
    char text[32];
    snprintf(text, sizeof(text), "%lld", value);
    rj_puts(b, text);
}

/* --- input ----------------------------------------------------------------- */

static const char* rj_skip_ws(const char* p) {
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    return p;
}

/* p at a value's first character; returns just past it, or NULL if malformed. */
static const char* rj_value_end(const char* p) {
    p = rj_skip_ws(p);
    if (*p == '"') {
        p++;
        while (*p && *p != '"') {
            if (*p == '\\' && p[1]) p++;
            p++;
        }
        return *p ? p + 1 : NULL;
    }
    if (*p == '{' || *p == '[') {
        int depth = 0;
        for (; *p; ++p) {
            if (*p == '"') {
                const char* e = rj_value_end(p);
                if (!e) return NULL;
                p = e - 1;
                continue;
            }
            if (*p == '{' || *p == '[') depth++;
            else if (*p == '}' || *p == ']') {
                if (--depth == 0) return p + 1;
            }
        }
        return NULL;
    }
    while (*p && *p != ',' && *p != '}' && *p != ']' && *p != ' ' && *p != '\n' && *p != '\r' && *p != '\t') p++;
    return p;
}

static void rj_put_utf8(char* out, size_t cap, size_t* n, unsigned cp) {
    char tmp[4];
    size_t len;
    if (cp < 0x80) {
        tmp[0] = (char)cp;
        len = 1;
    } else if (cp < 0x800) {
        tmp[0] = (char)(0xC0 | (cp >> 6));
        tmp[1] = (char)(0x80 | (cp & 0x3F));
        len = 2;
    } else if (cp < 0x10000) {
        tmp[0] = (char)(0xE0 | (cp >> 12));
        tmp[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        tmp[2] = (char)(0x80 | (cp & 0x3F));
        len = 3;
    } else {
        tmp[0] = (char)(0xF0 | (cp >> 18));
        tmp[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        tmp[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
        tmp[3] = (char)(0x80 | (cp & 0x3F));
        len = 4;
    }
    if (*n + len < cap) memcpy(out + *n, tmp, len);
    *n += len;
}

static unsigned rj_hex4(const char* p) {
    unsigned v = 0;
    int i;
    for (i = 0; i < 4; ++i) {
        char c = p[i];
        v <<= 4;
        if (c >= '0' && c <= '9') v |= (unsigned)(c - '0');
        else if (c >= 'a' && c <= 'f') v |= (unsigned)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v |= (unsigned)(c - 'A' + 10);
        else return 0xFFFFFFFFu;
    }
    return v;
}

/* Decode a JSON string at p into out (NUL-terminated, truncated to cap-1 bytes).
 * Returns just past the closing quote, or NULL when p is not a string. */
static const char* rj_string(const char* p, char* out, size_t cap) {
    size_t n = 0;
    p = rj_skip_ws(p);
    if (*p != '"') return NULL;
    p++;
    while (*p && *p != '"') {
        if (*p == '\\' && p[1]) {
            p++;
            switch (*p) {
                case 'n': rj_put_utf8(out, cap, &n, '\n'); break;
                case 'r': rj_put_utf8(out, cap, &n, '\r'); break;
                case 't': rj_put_utf8(out, cap, &n, '\t'); break;
                case 'b': rj_put_utf8(out, cap, &n, '\b'); break;
                case 'f': rj_put_utf8(out, cap, &n, '\f'); break;
                case 'u': {
                    unsigned cp = rj_hex4(p + 1);
                    if (cp == 0xFFFFFFFFu) return NULL;
                    p += 4;
                    if (cp >= 0xD800 && cp < 0xDC00 && p[1] == '\\' && p[2] == 'u') {
                        unsigned lo = rj_hex4(p + 3);
                        if (lo >= 0xDC00 && lo < 0xE000) {
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            p += 6;
                        }
                    }
                    rj_put_utf8(out, cap, &n, cp);
                    break;
                }
                default: rj_put_utf8(out, cap, &n, (unsigned char)*p); break;
            }
            p++;
            continue;
        }
        rj_put_utf8(out, cap, &n, (unsigned char)*p);
        p++;
    }
    if (cap) out[n < cap ? n : cap - 1] = '\0';
    return *p == '"' ? p + 1 : NULL;
}

/* Iterate an object's members. `cursor` starts at the '{' (or just past the
 * previous member); on success fills key (decoded), *value (start of the raw
 * value) and *value_end, and returns the cursor for the next call. NULL at the
 * end or on malformed input. */
static const char* rj_member(const char* cursor, char* key, size_t key_cap, const char** value,
                             const char** value_end) {
    const char* p = rj_skip_ws(cursor);
    if (*p == '{') p = rj_skip_ws(p + 1);
    if (*p == ',') p = rj_skip_ws(p + 1);
    if (*p != '"') return NULL;
    p = rj_string(p, key, key_cap);
    if (!p) return NULL;
    p = rj_skip_ws(p);
    if (*p != ':') return NULL;
    p = rj_skip_ws(p + 1);
    *value = p;
    *value_end = rj_value_end(p);
    return *value_end ? *value_end : NULL;
}

/* Iterate an array's elements. `cursor` starts at the '[' or just past the
 * previous element. NULL at the end. */
static const char* rj_element(const char* cursor, const char** value, const char** value_end) {
    const char* p = rj_skip_ws(cursor);
    if (*p == '[') p = rj_skip_ws(p + 1);
    if (*p == ',') p = rj_skip_ws(p + 1);
    if (*p == ']' || !*p) return NULL;
    *value = p;
    *value_end = rj_value_end(p);
    return *value_end ? *value_end : NULL;
}

/* The raw value of `name` inside the object at obj, or NULL. */
static const char* rj_find(const char* obj, const char* name, const char** value_end) {
    char key[512];
    const char *value, *end;
    const char* cursor = obj;
    while ((cursor = rj_member(cursor, key, sizeof(key), &value, &end)) != NULL) {
        if (strcmp(key, name) == 0) {
            *value_end = end;
            return value;
        }
    }
    return NULL;
}

static long long rj_int(const char* p, long long fallback) {
    long long v = 0;
    int neg = 0, any = 0;
    if (!p) return fallback;
    p = rj_skip_ws(p);
    if (*p == '-') {
        neg = 1;
        p++;
    }
    while (*p >= '0' && *p <= '9') {
        v = v * 10 + (*p - '0');
        any = 1;
        p++;
    }
    return any ? (neg ? -v : v) : fallback;
}

/* Locale-independent double: [-]digits[.digits]. Enough for a stat mtime. */
static double rj_double(const char* p, double fallback) {
    double v = 0.0, scale = 0.1;
    int neg = 0, any = 0;
    if (!p) return fallback;
    p = rj_skip_ws(p);
    if (*p == '-') {
        neg = 1;
        p++;
    }
    while (*p >= '0' && *p <= '9') {
        v = v * 10.0 + (*p - '0');
        any = 1;
        p++;
    }
    if (*p == '.') {
        p++;
        while (*p >= '0' && *p <= '9') {
            v += (*p - '0') * scale;
            scale *= 0.1;
            any = 1;
            p++;
        }
    }
    return any ? (neg ? -v : v) : fallback;
}

static int rj_bool(const char* p, int fallback) {
    if (!p) return fallback;
    p = rj_skip_ws(p);
    if (strncmp(p, "true", 4) == 0) return 1;
    if (strncmp(p, "false", 5) == 0) return 0;
    return fallback;
}

#endif /* SPDF_WIN_RECENTS_JSON_H */

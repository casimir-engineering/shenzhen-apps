/* spdf_win_session_json.h — the JSON half of the session module.
 *
 * Split out of spdf_win_session.cpp only to keep both files inside the 500-line
 * cap (tools/file-size-limits.md); it is module-internal, included by exactly
 * one translation unit, and is not part of the port's public surface. The
 * neighbouring spdf_win_canvas_internal.h is the same arrangement.
 *
 * WHAT THIS IS NOT: a second on-disk format. The file on disk is YAML and it
 * has exactly one codec, portable/core/spdf_yaml.c, reached through
 * spdf_win_state.h. What lives here is the in-memory JSON marshalling every
 * frontend already does on its own side of that codec — NSJSONSerialization in
 * the mac app, a hand-rolled scanner in portable/linux/gtk4/spdf_state.c. This
 * is the Windows equivalent of the latter, and it is deliberately a READER
 * over the compact JSON spdf_json_from_yaml() returns plus a small emitter for
 * the JSON spdf_yaml_from_json() consumes.
 *
 * Numbers are parsed and formatted by hand rather than through strtod/printf
 * because those are LOCALE-DEPENDENT on the decimal separator. The GTK frontend
 * shipped that bug once (see spdf_state.c, append_json_fixed): under a
 * comma-decimal locale it wrote "zoom": 1,2500 — a session file no frontend,
 * including the one that wrote it, can read back.
 */
#ifndef SPDF_WIN_SESSION_JSON_H
#define SPDF_WIN_SESSION_JSON_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* --- growable output buffer ---------------------------------------------- */

typedef struct out_buf {
    char* data;
    size_t len;
    size_t cap;
    int failed;
} out_buf;

static void buf_put(out_buf* b, const char* text, size_t n) {
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

static void buf_puts(out_buf* b, const char* text) { buf_put(b, text, strlen(text)); }

/* Matches spdf_yaml.c's own JSON string emitter byte for byte, so a value that
 * round-trips through the codec comes back identical. */
static void emit_string(out_buf* b, const char* text) {
    const unsigned char* p = (const unsigned char*)(text ? text : "");
    buf_puts(b, "\"");
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
        /* Everything else, UTF-8 included, goes out raw -- exactly what the
         * codec's own emitter does, so a round trip is byte-stable. */
        if (replacement) buf_puts(b, replacement);
        else buf_put(b, (const char*)p, 1);
    }
    buf_puts(b, "\"");
}

/* ,"key": -- every member after the first. */
static void emit_key(out_buf* b, const char* key) {
    buf_puts(b, ",\"");
    buf_puts(b, key);
    buf_puts(b, "\":");
}

static void emit_int(out_buf* b, long long value) {
    char text[32];
    snprintf(text, sizeof(text), "%lld", value);
    buf_puts(b, text);
}

/* Locale-independent fixed-point, four decimals like the GTK writer. */
static void emit_fixed(out_buf* b, double value, int decimals) {
    char text[64];
    long long scale = 1, units, frac;
    int i, negative;
    if (!(value == value)) value = 0.0; /* NaN */
    if (value > 1e15) value = 1e15;
    if (value < -1e15) value = -1e15;
    negative = value < 0.0;
    if (negative) value = -value;
    for (i = 0; i < decimals; ++i) scale *= 10;
    units = (long long)value;
    frac = (long long)((value - (double)units) * (double)scale + 0.5);
    if (frac >= scale) {
        units++;
        frac -= scale;
    }
    snprintf(text, sizeof(text), "%s%lld.%0*lld", negative ? "-" : "", units, decimals, frac);
    buf_puts(b, text);
}

/* --- JSON reading --------------------------------------------------------- */

static const char* skip_ws(const char* p) {
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    return p;
}

/* p at a value's first character; returns just past it, or NULL if malformed. */
static const char* value_end(const char* p) {
    p = skip_ws(p);
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
                const char* e = value_end(p);
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
    while (*p && *p != ',' && *p != '}' && *p != ']' && *p != ' ') p++;
    return p;
}

typedef struct member {
    const char* key; /* raw, still escaped, inside the quotes */
    size_t key_len;
    const char* val;
    const char* val_end;
} member;

static int member_at(const char* p, member* m) {
    const char* key_end;
    p = skip_ws(p);
    if (*p == ',') p = skip_ws(p + 1);
    if (*p != '"') return 0;
    key_end = value_end(p);
    if (!key_end) return 0;
    m->key = p + 1;
    m->key_len = (size_t)(key_end - p) - 2;
    p = skip_ws(key_end);
    if (*p != ':') return 0;
    m->val = skip_ws(p + 1);
    m->val_end = value_end(m->val);
    return m->val_end != NULL;
}

static int object_first(const char* obj, member* m) { return obj && *obj == '{' ? member_at(obj + 1, m) : 0; }
static int object_next(member* m) { return member_at(m->val_end, m); }

static int key_is(const member* m, const char* name) {
    return strlen(name) == m->key_len && memcmp(m->key, name, m->key_len) == 0;
}

static const char* obj_value(const char* obj, const char* key, const char** end) {
    member m;
    int ok;
    for (ok = object_first(obj, &m); ok; ok = object_next(&m)) {
        if (!key_is(&m, key)) continue;
        if (end) *end = m.val_end;
        return m.val;
    }
    return NULL;
}

/* Array walking. `end` carries the cursor: array_first(arr, &end) then
 * array_next(end, &end) until NULL. */
static const char* elem_at(const char* p, const char** end) {
    p = skip_ws(p);
    if (*p == ',') p = skip_ws(p + 1);
    if (*p == ']' || !*p) return NULL;
    *end = value_end(p);
    return *end ? p : NULL;
}

static const char* array_first(const char* arr, const char** end) {
    return arr && *arr == '[' ? elem_at(arr + 1, end) : NULL;
}
static const char* array_next(const char* prev_end, const char** end) { return elem_at(prev_end, end); }

static double parse_number(const char* p) {
    double value = 0.0;
    int negative = 0;
    if (*p == '-') negative = 1, p++;
    else if (*p == '+') p++;
    while (*p >= '0' && *p <= '9') value = value * 10.0 + (*p++ - '0');
    if (*p == '.') {
        double step = 0.1;
        p++;
        while (*p >= '0' && *p <= '9') {
            value += (double)(*p++ - '0') * step;
            step *= 0.1;
        }
    }
    if (*p == 'e' || *p == 'E') {
        int exponent = 0, sign = 1;
        p++;
        if (*p == '-') sign = -1, p++;
        else if (*p == '+') p++;
        while (*p >= '0' && *p <= '9') exponent = exponent * 10 + (*p++ - '0');
        while (exponent-- > 0) value = sign > 0 ? value * 10.0 : value / 10.0;
    }
    return negative ? -value : value;
}

static double json_num(const char* obj, const char* key, double fallback) {
    const char* v = obj_value(obj, key, NULL);
    if (!v || (*v != '-' && *v != '+' && *v != '.' && (*v < '0' || *v > '9'))) return fallback;
    return parse_number(v);
}

static int json_int(const char* obj, const char* key, int fallback) {
    return (int)json_num(obj, key, (double)fallback);
}

static int json_bool(const char* obj, const char* key, int fallback) {
    const char* v = obj_value(obj, key, NULL);
    if (!v) return fallback;
    if (*v == 't') return 1;
    if (*v == 'f') return 0;
    return fallback;
}

static unsigned hex4(const char* p) {
    unsigned value = 0;
    int i;
    for (i = 0; i < 4; ++i) {
        char c = p[i];
        value <<= 4;
        if (c >= '0' && c <= '9') value |= (unsigned)(c - '0');
        else if (c >= 'a' && c <= 'f') value |= (unsigned)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') value |= (unsigned)(c - 'A' + 10);
        else return 0xFFFFFFFFu;
    }
    return value;
}

/* Malloc'd UTF-8 copy of a JSON string value, or NULL. */
static char* json_str(const char* obj, const char* key) {
    const char* end = NULL;
    const char* v = obj_value(obj, key, &end);
    const char* p;
    char* out;
    size_t len = 0;
    if (!v || *v != '"' || !end) return NULL;
    out = (char*)malloc((size_t)(end - v) + 4);
    if (!out) return NULL;
    for (p = v + 1; p < end - 1; ++p) {
        if (*p != '\\') {
            out[len++] = *p;
            continue;
        }
        switch (*++p) {
            case 'b': out[len++] = '\b'; break;
            case 'f': out[len++] = '\f'; break;
            case 'n': out[len++] = '\n'; break;
            case 'r': out[len++] = '\r'; break;
            case 't': out[len++] = '\t'; break;
            /* The codec emits \u ONLY for control characters (spdf_yaml.c
             * passes every byte >= 0x20 through raw, UTF-8 included, and
             * decodes a human's \uXXXX to UTF-8 before this ever sees it), so
             * an escape here is always \u00XX. Anything else is a malformed
             * file and becomes U+FFFD rather than a decoder nobody exercises. */
            case 'u': {
                unsigned cp = (p + 4 < end) ? hex4(p + 1) : 0xFFFFFFFFu;
                p += 4;
                if (cp < 0x80) {
                    out[len++] = (char)cp;
                } else {
                    out[len++] = (char)0xEF;
                    out[len++] = (char)0xBF;
                    out[len++] = (char)0xBD;
                }
                break;
            }
            default: out[len++] = *p; break;
        }
    }
    out[len] = '\0';
    return out;
}

#endif /* SPDF_WIN_SESSION_JSON_H */

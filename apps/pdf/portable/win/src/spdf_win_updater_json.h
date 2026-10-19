/* spdf_win_updater_json.h — a structural JSON scanner and a growable string,
 * shared by the updater's feed parser and its update.json store.
 *
 * A transcription of the scanner at portable/linux/gtk4/spdf_updater.c:304-527
 * with GString replaced by spdf_win_sb. STRUCTURAL means it walks the document
 * by its grammar -- strings with their escapes, nested arrays and objects --
 * rather than by strstr, so a release body containing `"name": "x"` or an
 * unbalanced brace can never be mistaken for an asset. spdf_win_state.c's
 * strstr helpers face only files this app wrote; this one faces GitHub.
 *
 * Header-only, `static` functions: two translation units include it and the
 * few hundred bytes of duplication cost nothing next to another .c in every
 * test's link line. Pure C89-compatible, no <windows.h>.
 */
#ifndef SPDF_WIN_UPDATER_JSON_H
#define SPDF_WIN_UPDATER_JSON_H

#include <stdlib.h>
#include <string.h>

/* --- growable string ---------------------------------------------------- */

typedef struct spdf_win_sb {
    char* data;
    size_t len;
    size_t cap;
    int failed; /* an allocation failed; finish() returns NULL */
} spdf_win_sb;

static void spdf_win_sb_init(spdf_win_sb* sb) {
    sb->data = NULL;
    sb->len = 0;
    sb->cap = 0;
    sb->failed = 0;
}

static void spdf_win_sb_append_n(spdf_win_sb* sb, const char* s, size_t n) {
    if (sb->failed) return;
    if (sb->len + n + 1 > sb->cap) {
        size_t want = sb->cap ? sb->cap * 2 : 64;
        char* grown;
        while (want < sb->len + n + 1) want *= 2;
        grown = (char*)realloc(sb->data, want);
        if (!grown) {
            sb->failed = 1;
            return;
        }
        sb->data = grown;
        sb->cap = want;
    }
    memcpy(sb->data + sb->len, s, n);
    sb->len += n;
    sb->data[sb->len] = '\0';
}

static void spdf_win_sb_append(spdf_win_sb* sb, const char* s) {
    spdf_win_sb_append_n(sb, s, strlen(s));
}

static void spdf_win_sb_append_c(spdf_win_sb* sb, char c) {
    spdf_win_sb_append_n(sb, &c, 1);
}

/* Returns the buffer (malloc'd, NUL-terminated; "" for nothing appended) and
 * resets the builder. NULL only after an allocation failure. */
static char* spdf_win_sb_finish(spdf_win_sb* sb) {
    char* out;
    if (sb->failed) {
        free(sb->data);
        spdf_win_sb_init(sb);
        return NULL;
    }
    if (!sb->data) {
        out = (char*)malloc(1);
        if (out) out[0] = '\0';
    } else {
        out = sb->data;
    }
    spdf_win_sb_init(sb);
    return out;
}

/* --- the scanner -------------------------------------------------------- */

typedef struct spdf_win_js_cursor {
    const char* p;
    const char* end;
} spdf_win_js_cursor;

static void spdf_win_js_skip_ws(spdf_win_js_cursor* c) {
    while (c->p < c->end && (*c->p == ' ' || *c->p == '\t' || *c->p == '\n' || *c->p == '\r')) c->p++;
}

static void spdf_win_js_put_utf8(spdf_win_sb* out, unsigned cp) {
    char b[4];
    if (cp < 0x80) {
        b[0] = (char)cp;
        spdf_win_sb_append_n(out, b, 1);
    } else if (cp < 0x800) {
        b[0] = (char)(0xC0 | (cp >> 6));
        b[1] = (char)(0x80 | (cp & 0x3F));
        spdf_win_sb_append_n(out, b, 2);
    } else if (cp < 0x10000) {
        b[0] = (char)(0xE0 | (cp >> 12));
        b[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        b[2] = (char)(0x80 | (cp & 0x3F));
        spdf_win_sb_append_n(out, b, 3);
    } else {
        b[0] = (char)(0xF0 | (cp >> 18));
        b[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        b[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
        b[3] = (char)(0x80 | (cp & 0x3F));
        spdf_win_sb_append_n(out, b, 4);
    }
}

static int spdf_win_js_hex4(const char* p, const char* end, unsigned* out) {
    unsigned v = 0;
    int i;
    if (end - p < 4) return 0;
    for (i = 0; i < 4; ++i) {
        char ch = p[i];
        v <<= 4;
        if (ch >= '0' && ch <= '9') v |= (unsigned)(ch - '0');
        else if (ch >= 'a' && ch <= 'f') v |= (unsigned)(ch - 'a' + 10);
        else if (ch >= 'A' && ch <= 'F') v |= (unsigned)(ch - 'A' + 10);
        else return 0;
    }
    *out = v;
    return 1;
}

/* Cursor at '"'. Consumes through the closing quote; the decoded content is
 * appended to `out` when non-NULL. Surrogate pairs become one code point; a
 * lone surrogate becomes U+FFFD rather than an invalid byte sequence. */
static int spdf_win_js_parse_string(spdf_win_js_cursor* c, spdf_win_sb* out) {
    if (c->p >= c->end || *c->p != '"') return 0;
    c->p++;
    while (c->p < c->end) {
        unsigned char ch = (unsigned char)*c->p;
        if (ch == '"') {
            c->p++;
            return 1;
        }
        if (ch == '\\') {
            c->p++;
            if (c->p >= c->end) return 0;
            switch (*c->p) {
                case '"': if (out) spdf_win_sb_append_c(out, '"'); break;
                case '\\': if (out) spdf_win_sb_append_c(out, '\\'); break;
                case '/': if (out) spdf_win_sb_append_c(out, '/'); break;
                case 'b': if (out) spdf_win_sb_append_c(out, '\b'); break;
                case 'f': if (out) spdf_win_sb_append_c(out, '\f'); break;
                case 'n': if (out) spdf_win_sb_append_c(out, '\n'); break;
                case 'r': if (out) spdf_win_sb_append_c(out, '\r'); break;
                case 't': if (out) spdf_win_sb_append_c(out, '\t'); break;
                case 'u': {
                    unsigned cp;
                    if (!spdf_win_js_hex4(c->p + 1, c->end, &cp)) return 0;
                    c->p += 4;
                    if (cp >= 0xD800 && cp <= 0xDBFF) {
                        unsigned lo;
                        if (c->end - c->p >= 7 && c->p[1] == '\\' && c->p[2] == 'u' &&
                            spdf_win_js_hex4(c->p + 3, c->end, &lo) && lo >= 0xDC00 && lo <= 0xDFFF) {
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            c->p += 6;
                        } else {
                            cp = 0xFFFD;
                        }
                    } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                        cp = 0xFFFD;
                    }
                    if (out) spdf_win_js_put_utf8(out, cp);
                    break;
                }
                default: return 0;
            }
            c->p++;
            continue;
        }
        if (ch < 0x20) return 0; /* raw control characters are not JSON */
        if (out) spdf_win_sb_append_c(out, (char)ch);
        c->p++;
    }
    return 0;
}

static int spdf_win_js_skip_value(spdf_win_js_cursor* c);

static int spdf_win_js_skip_container(spdf_win_js_cursor* c, char open, char close) {
    if (c->p >= c->end || *c->p != open) return 0;
    c->p++;
    spdf_win_js_skip_ws(c);
    if (c->p < c->end && *c->p == close) {
        c->p++;
        return 1;
    }
    for (;;) {
        spdf_win_js_skip_ws(c);
        if (open == '{') {
            if (!spdf_win_js_parse_string(c, NULL)) return 0;
            spdf_win_js_skip_ws(c);
            if (c->p >= c->end || *c->p != ':') return 0;
            c->p++;
        }
        if (!spdf_win_js_skip_value(c)) return 0;
        spdf_win_js_skip_ws(c);
        if (c->p >= c->end) return 0;
        if (*c->p == ',') {
            c->p++;
            continue;
        }
        if (*c->p == close) {
            c->p++;
            return 1;
        }
        return 0;
    }
}

static int spdf_win_js_skip_value(spdf_win_js_cursor* c) {
    spdf_win_js_skip_ws(c);
    if (c->p >= c->end) return 0;
    switch (*c->p) {
        case '"': return spdf_win_js_parse_string(c, NULL);
        case '{': return spdf_win_js_skip_container(c, '{', '}');
        case '[': return spdf_win_js_skip_container(c, '[', ']');
        default: {
            const char* start = c->p;
            while (c->p < c->end && *c->p != ',' && *c->p != '}' && *c->p != ']' && *c->p != ' ' &&
                   *c->p != '\n' && *c->p != '\r' && *c->p != '\t')
                c->p++;
            return c->p > start; /* true/false/null/number */
        }
    }
}

static int spdf_win_js_enter_object(spdf_win_js_cursor* c) {
    spdf_win_js_skip_ws(c);
    if (c->p >= c->end || *c->p != '{') return 0;
    c->p++;
    return 1;
}

/* 1 and a malloc'd key with the cursor at the value; 0 at the closing brace;
 * -1 on malformed input. */
static int spdf_win_js_next_member(spdf_win_js_cursor* c, char** key) {
    spdf_win_sb sb;
    spdf_win_js_skip_ws(c);
    if (c->p >= c->end) return -1;
    if (*c->p == '}') {
        c->p++;
        return 0;
    }
    if (*c->p == ',') {
        c->p++;
        spdf_win_js_skip_ws(c);
    }
    spdf_win_sb_init(&sb);
    if (!spdf_win_js_parse_string(c, &sb)) {
        free(spdf_win_sb_finish(&sb));
        return -1;
    }
    spdf_win_js_skip_ws(c);
    if (c->p >= c->end || *c->p != ':') {
        free(spdf_win_sb_finish(&sb));
        return -1;
    }
    c->p++;
    *key = spdf_win_sb_finish(&sb);
    return *key ? 1 : -1;
}

/* malloc'd decoded string, or NULL when the value is not a string. */
static char* spdf_win_js_read_string(spdf_win_js_cursor* c) {
    spdf_win_sb sb;
    spdf_win_js_skip_ws(c);
    spdf_win_sb_init(&sb);
    if (!spdf_win_js_parse_string(c, &sb)) {
        free(spdf_win_sb_finish(&sb));
        return NULL;
    }
    return spdf_win_sb_finish(&sb);
}

static int spdf_win_js_read_bool(spdf_win_js_cursor* c, int* out) {
    spdf_win_js_skip_ws(c);
    if (c->end - c->p >= 4 && strncmp(c->p, "true", 4) == 0) {
        *out = 1;
        c->p += 4;
        return 1;
    }
    if (c->end - c->p >= 5 && strncmp(c->p, "false", 5) == 0) {
        *out = 0;
        c->p += 5;
        return 1;
    }
    return 0;
}

/* Integers, and floats truncated toward zero (macOS writes timestamps with a
 * fractional part). */
static int spdf_win_js_read_int(spdf_win_js_cursor* c, long long* out) {
    const char* start;
    long long v = 0;
    int neg = 0;
    spdf_win_js_skip_ws(c);
    start = c->p;
    if (c->p < c->end && *c->p == '-') {
        neg = 1;
        c->p++;
    }
    if (c->p >= c->end || *c->p < '0' || *c->p > '9') {
        c->p = start;
        return 0;
    }
    while (c->p < c->end && *c->p >= '0' && *c->p <= '9') {
        if (v > 922337203685477580LL) return 0; /* would overflow */
        v = v * 10 + (*c->p - '0');
        c->p++;
    }
    if (c->p < c->end && *c->p == '.') {
        c->p++;
        while (c->p < c->end && *c->p >= '0' && *c->p <= '9') c->p++;
    }
    *out = neg ? -v : v;
    return 1;
}

/* A JSON string literal, quotes included, with the escapes JSON requires. */
static void spdf_win_js_append_quoted(spdf_win_sb* sb, const char* s) {
    spdf_win_sb_append_c(sb, '"');
    for (; *s; ++s) {
        unsigned char ch = (unsigned char)*s;
        switch (ch) {
            case '"': spdf_win_sb_append(sb, "\\\""); break;
            case '\\': spdf_win_sb_append(sb, "\\\\"); break;
            case '\n': spdf_win_sb_append(sb, "\\n"); break;
            case '\r': spdf_win_sb_append(sb, "\\r"); break;
            case '\t': spdf_win_sb_append(sb, "\\t"); break;
            default:
                if (ch < 0x20) {
                    char esc[8];
                    const char* hex = "0123456789abcdef";
                    esc[0] = '\\'; esc[1] = 'u'; esc[2] = '0'; esc[3] = '0';
                    esc[4] = hex[ch >> 4]; esc[5] = hex[ch & 0xF]; esc[6] = '\0';
                    spdf_win_sb_append(sb, esc);
                } else {
                    spdf_win_sb_append_c(sb, (char)ch);
                }
        }
    }
    spdf_win_sb_append_c(sb, '"');
}

#endif /* SPDF_WIN_UPDATER_JSON_H */

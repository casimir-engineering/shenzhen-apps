/* spdf_win_chapter_state.h — the per-document memory of which chapters were
 * left collapsed, and where it is kept.
 *
 * WHAT THE MAC PERSISTS, which this mirrors member for member. SPDFMacSidebarChapters.mm
 * (a5820117a) stores the collapsed keys in the per-document store, documents.yaml,
 * inside the record keyed by the document's path, as
 *
 *   "<path>": { ..., "collapsedChapters": ["0", "0.2.1"], "path": "<path>" }
 *
 * -- kSPDFCollapsedChaptersKey is "collapsedChapters", the array is SORTED so the
 * file does not churn between launches on set ordering, and the member is
 * REMOVED (not written empty) when nothing is collapsed, which is also what a
 * document nobody has touched reads back as: expanded.
 *
 * WHERE IT LIVES ON WINDOWS, and why not in documents.yaml itself. That file is
 * written by spdf_win_recents.c -- another module -- which carries members it
 * does not model through verbatim but offers no way to SET one, and two
 * read-modify-write cycles of one file from two modules in one process would
 * each lose the other's keys (its own header says exactly this about
 * settings.yaml). So this module writes a sibling file, chapters.yaml, with the
 * SAME record shape and the SAME key names, keyed by the same path:
 *
 *   chapters.yaml   { "<path>": { "collapsedChapters": [...], "path": "<path>" } }
 *
 * and READS documents.yaml as the fallback, so a record the mac app wrote (a
 * synced state directory) is honoured on the first launch here. The moment the
 * recents module grows a member setter this becomes one call and chapters.yaml
 * goes away; this change's report asks for it. Same codec as every state file
 * (portable/core/spdf_yaml.h through spdf_win_state.h), same "unreadable is not
 * absent" rule: a file that cannot be read is never overwritten.
 *
 * THE PATH KEY. The mac keys by `stringByStandardizingPath`; the recents module
 * here keys by the path as opened and compares with separators normalised and
 * ASCII case folded, "which is what Windows itself considers the same path".
 * spdf_win_chapter_state_path_equal is that rule restated for this file, so a
 * record written from `C:\Docs\a.pdf` is found from `c:/docs/a.pdf`.
 *
 * The JSON half is header-only and pure so portable/win/tests/sidebar_outline_test.c
 * can drive it with literal text; the two file functions live in
 * spdf_win_chapter_state.cpp and need spdf_win_state.c, spdf_win_paths.c,
 * spdf_yaml.c and spdf_win_compat.c linked. spdf_win_chapter_store_register.cpp
 * hands them to the content provider as its store (spdf_win_chrome_content.h,
 * SpdfWinChapterStore), which is how the provider remembers folds without
 * depending on any of those.
 */
#ifndef SPDF_WIN_CHAPTER_STATE_H
#define SPDF_WIN_CHAPTER_STATE_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_CS_INLINE __inline
#else
#define SPDF_WIN_CS_INLINE inline
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define SPDF_WIN_CHAPTER_STATE_FILE "chapters.yaml"
#define SPDF_WIN_CHAPTER_STATE_MEMBER "collapsedChapters" /* kSPDFCollapsedChaptersKey */
/* A key is "0.2.1": spdf_win_sidebar_outline.h's SPDF_WIN_SIDEBAR_OUTLINE_KEY_MAX,
 * restated so this header stays free of that one. */
#define SPDF_WIN_CHAPTER_STATE_KEY_CAP 705

/* --- the path rule ------------------------------------------------------- */

static SPDF_WIN_CS_INLINE int spdf_win_chapter_state_path_equal(const char* a, const char* b) {
    if (!a || !b) return 0;
    for (;; ++a, ++b) {
        unsigned char ca = (unsigned char)*a, cb = (unsigned char)*b;
        if (ca == '/') ca = '\\';
        if (cb == '/') cb = '\\';
        if (ca >= 'A' && ca <= 'Z') ca = (unsigned char)(ca - 'A' + 'a');
        if (cb >= 'A' && cb <= 'Z') cb = (unsigned char)(cb - 'A' + 'a');
        if (ca != cb) return 0;
        if (!ca) return 1;
    }
}

/* --- a small JSON scanner ------------------------------------------------
 *
 * Just enough to find a record by key, read one array of strings out of it and
 * splice a record back in. Not a second parser for the on-disk format -- the
 * file is YAML with one codec -- but the in-memory JSON marshalling every
 * frontend does on its own side of that codec. */

static SPDF_WIN_CS_INLINE const char* spdf_win_cs_skip_ws(const char* p) {
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') ++p;
    return p;
}

/* p at an opening quote; returns just past the closing quote, or NULL. */
static SPDF_WIN_CS_INLINE const char* spdf_win_cs_string_end(const char* p) {
    if (*p != '"') return NULL;
    ++p;
    while (*p && *p != '"') {
        if (*p == '\\' && p[1]) ++p;
        ++p;
    }
    return *p ? p + 1 : NULL;
}

/* p at a value's first character; returns just past it, or NULL if malformed. */
static SPDF_WIN_CS_INLINE const char* spdf_win_cs_value_end(const char* p) {
    p = spdf_win_cs_skip_ws(p);
    if (*p == '"') return spdf_win_cs_string_end(p);
    if (*p == '{' || *p == '[') {
        int depth = 0;
        for (; *p; ++p) {
            if (*p == '"') {
                const char* e = spdf_win_cs_string_end(p);
                if (!e) return NULL;
                p = e - 1;
                continue;
            }
            if (*p == '{' || *p == '[') ++depth;
            else if (*p == '}' || *p == ']') {
                if (--depth == 0) return p + 1;
            }
        }
        return NULL;
    }
    while (*p && *p != ',' && *p != '}' && *p != ']' && *p != ' ' && *p != '\n' && *p != '\r' && *p != '\t') ++p;
    return p;
}

static SPDF_WIN_CS_INLINE void spdf_win_cs_put_utf8(char* out, size_t cap, size_t* n, unsigned cp) {
    char tmp[4];
    size_t len, i;
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
    for (i = 0; i < len; ++i)
        if (*n + i < cap) out[*n + i] = tmp[i];
    *n += len;
}

/* Decode the JSON string at p (opening quote) into UTF-8. Returns the decoded
 * length, or -1 when p is not a string; the output is always terminated when
 * cap > 0 and truncated silently when it does not fit -- a path that long is
 * not one this file was asked about. */
static SPDF_WIN_CS_INLINE long spdf_win_cs_unescape(const char* p, char* out, size_t cap) {
    size_t n = 0;
    if (!p || *p != '"' || !out || cap == 0) return -1;
    ++p;
    while (*p && *p != '"') {
        unsigned cp;
        if (*p != '\\') {
            if (n < cap) out[n] = *p;
            ++n;
            ++p;
            continue;
        }
        ++p;
        switch (*p) {
            case '"': cp = '"'; break;
            case '\\': cp = '\\'; break;
            case '/': cp = '/'; break;
            case 'b': cp = '\b'; break;
            case 'f': cp = '\f'; break;
            case 'n': cp = '\n'; break;
            case 'r': cp = '\r'; break;
            case 't': cp = '\t'; break;
            case 'u': {
                char hex[5];
                unsigned lo;
                if (!p[1] || !p[2] || !p[3] || !p[4]) return -1;
                memcpy(hex, p + 1, 4);
                hex[4] = '\0';
                cp = (unsigned)strtoul(hex, NULL, 16);
                p += 4;
                if (cp >= 0xD800 && cp < 0xDC00 && p[1] == '\\' && p[2] == 'u' && p[3] && p[4] && p[5] && p[6]) {
                    memcpy(hex, p + 3, 4);
                    lo = (unsigned)strtoul(hex, NULL, 16);
                    if (lo >= 0xDC00 && lo < 0xE000) {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        p += 6;
                    }
                }
                break;
            }
            default: return -1;
        }
        if (cp < 0x80) {
            if (n < cap) out[n] = (char)cp;
            ++n;
        } else {
            spdf_win_cs_put_utf8(out, cap, &n, cp);
        }
        ++p;
    }
    if (*p != '"') return -1;
    out[n < cap ? n : cap - 1] = '\0';
    return (long)n;
}

/* Find the member of the top-level object whose key matches `key` -- by the
 * path rule when `by_path` is set, byte for byte otherwise. On success returns
 * 1 with [*member_start, *member_end) spanning the whole `"key": value` and
 * [*value_start, *value_end) the value. `json` may be NULL or not an object,
 * which is "not found". */
static SPDF_WIN_CS_INLINE int spdf_win_chapter_state_find_member(const char* json, const char* key, int by_path,
                                                                 const char** member_start, const char** member_end,
                                                                 const char** value_start, const char** value_end) {
    const char* p;
    char decoded[2048];
    if (!json || !key) return 0;
    p = spdf_win_cs_skip_ws(json);
    if (*p != '{') return 0;
    ++p;
    for (;;) {
        const char *k, *ke, *v, *ve;
        p = spdf_win_cs_skip_ws(p);
        if (*p == '}' || !*p) return 0;
        if (*p == ',') {
            ++p;
            continue;
        }
        k = p;
        ke = spdf_win_cs_string_end(k);
        if (!ke) return 0;
        p = spdf_win_cs_skip_ws(ke);
        if (*p != ':') return 0;
        v = spdf_win_cs_skip_ws(p + 1);
        ve = spdf_win_cs_value_end(v);
        if (!ve) return 0;
        if (spdf_win_cs_unescape(k, decoded, sizeof(decoded)) >= 0 &&
            (by_path ? spdf_win_chapter_state_path_equal(decoded, key) : strcmp(decoded, key) == 0)) {
            if (member_start) *member_start = k;
            if (member_end) *member_end = ve;
            if (value_start) *value_start = v;
            if (value_end) *value_end = ve;
            return 1;
        }
        p = ve;
    }
}

/* The collapsed keys of one document's record (a JSON object). Returns 1 when
 * the record carries a "collapsedChapters" array -- possibly empty -- and fills
 * `out_keys` with malloc'd strings (free with spdf_win_chapter_state_free_keys);
 * 0 when it does not, which reads as "expanded". Non-string entries are
 * skipped, as the mac skips them. */
static SPDF_WIN_CS_INLINE int spdf_win_chapter_state_keys_from_record(const char* record, char*** out_keys,
                                                                      int* out_count) {
    const char *v, *ve, *p;
    char** keys = NULL;
    int count = 0, cap = 0;
    if (out_keys) *out_keys = NULL;
    if (out_count) *out_count = 0;
    if (!spdf_win_chapter_state_find_member(record, SPDF_WIN_CHAPTER_STATE_MEMBER, 0, NULL, NULL, &v, &ve)) return 0;
    if (*v != '[') return 0;
    p = v + 1;
    for (;;) {
        const char* e;
        p = spdf_win_cs_skip_ws(p);
        if (*p == ']' || !*p || p >= ve) break;
        if (*p == ',') {
            ++p;
            continue;
        }
        e = spdf_win_cs_value_end(p);
        if (!e) break;
        if (*p == '"') {
            char decoded[SPDF_WIN_CHAPTER_STATE_KEY_CAP];
            if (spdf_win_cs_unescape(p, decoded, sizeof(decoded)) > 0) {
                if (count == cap) {
                    int want = cap ? cap * 2 : 8;
                    char** grown = (char**)realloc(keys, sizeof(char*) * (size_t)want);
                    if (!grown) break;
                    keys = grown;
                    cap = want;
                }
                keys[count] = _strdup(decoded);
                if (keys[count]) ++count;
            }
        }
        p = e;
    }
    if (out_keys) *out_keys = keys;
    else
        free(keys);
    if (out_count) *out_count = count;
    return 1;
}

/* --- building the file's JSON -------------------------------------------- */

typedef struct SpdfWinChapterStateBuf {
    char* data;
    size_t len, cap;
    int failed;
} SpdfWinChapterStateBuf;

static SPDF_WIN_CS_INLINE void spdf_win_cs_put(SpdfWinChapterStateBuf* b, const char* text, size_t n) {
    if (b->failed || n == 0) return;
    if (b->len + n + 1 > b->cap) {
        size_t want = b->cap ? b->cap * 2 : 512;
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

static SPDF_WIN_CS_INLINE void spdf_win_cs_puts(SpdfWinChapterStateBuf* b, const char* text) {
    spdf_win_cs_put(b, text, strlen(text));
}

/* Same escapes as spdf_yaml.c's JSON emitter, so the value round-trips
 * byte-stable through the codec. UTF-8 goes out raw. */
static SPDF_WIN_CS_INLINE void spdf_win_cs_emit_string(SpdfWinChapterStateBuf* b, const char* text) {
    const unsigned char* p = (const unsigned char*)(text ? text : "");
    spdf_win_cs_puts(b, "\"");
    for (; *p; ++p) {
        char esc[8];
        const char* rep = NULL;
        if (*p == '"') rep = "\\\"";
        else if (*p == '\\') rep = "\\\\";
        else if (*p == '\b') rep = "\\b";
        else if (*p == '\f') rep = "\\f";
        else if (*p == '\n') rep = "\\n";
        else if (*p == '\r') rep = "\\r";
        else if (*p == '\t') rep = "\\t";
        else if (*p < 0x20) {
            _snprintf_s(esc, sizeof(esc), _TRUNCATE, "\\u%04x", (unsigned)*p);
            rep = esc;
        }
        if (rep) spdf_win_cs_puts(b, rep);
        else spdf_win_cs_put(b, (const char*)p, 1);
    }
    spdf_win_cs_puts(b, "\"");
}

static int spdf_win_cs_compare_keys(const void* a, const void* b) {
    return strcmp(*(const char* const*)a, *(const char* const*)b);
}

/* The file's JSON with this document's record replaced -- or inserted, or, when
 * `count` is 0, removed, because a record with nothing collapsed says nothing a
 * missing record does not. `json` is the file's current JSON or NULL. Every
 * other record is carried through byte for byte. Keys are emitted SORTED, as
 * the mac sorts them. malloc'd; NULL on allocation failure. */
static SPDF_WIN_CS_INLINE char* spdf_win_chapter_state_merge(const char* json, const char* path,
                                                             const char* const* keys, int count) {
    SpdfWinChapterStateBuf b;
    const char *ms = NULL, *me = NULL;
    const char* body_start;
    const char* body_end;
    int found, others, i;
    const char** sorted = NULL;

    memset(&b, 0, sizeof(b));
    if (!path || !path[0]) return NULL;
    if (!json || *spdf_win_cs_skip_ws(json) != '{') json = "{}";
    found = spdf_win_chapter_state_find_member(json, path, 1, &ms, &me, NULL, NULL);
    body_start = spdf_win_cs_skip_ws(json) + 1;
    body_end = json + strlen(json);
    while (body_end > body_start && body_end[-1] != '}') --body_end;
    if (body_end > body_start) --body_end; /* now at the closing brace */

    if (count > 0) {
        sorted = (const char**)malloc(sizeof(char*) * (size_t)count);
        if (!sorted) return NULL;
        for (i = 0; i < count; ++i) sorted[i] = keys[i] ? keys[i] : "";
        qsort((void*)sorted, (size_t)count, sizeof(char*), spdf_win_cs_compare_keys);
    }

    spdf_win_cs_puts(&b, "{");
    others = 0;
    /* Everything before the old record, then everything after it, with the
     * commas re-derived rather than copied so a removal cannot leave one behind. */
    {
        const char* p = body_start;
        for (;;) {
            const char *k, *ke, *v, *ve;
            p = spdf_win_cs_skip_ws(p);
            if (*p == '}' || !*p || p >= body_end) break;
            if (*p == ',') {
                ++p;
                continue;
            }
            k = p;
            ke = spdf_win_cs_string_end(k);
            if (!ke) break;
            v = spdf_win_cs_skip_ws(ke);
            if (*v != ':') break;
            v = spdf_win_cs_skip_ws(v + 1);
            ve = spdf_win_cs_value_end(v);
            if (!ve) break;
            if (!(found && k == ms)) {
                if (others++) spdf_win_cs_puts(&b, ",");
                spdf_win_cs_put(&b, k, (size_t)(ve - k));
            }
            p = ve;
        }
    }
    (void)me;
    if (count > 0) {
        if (others) spdf_win_cs_puts(&b, ",");
        spdf_win_cs_emit_string(&b, path);
        spdf_win_cs_puts(&b, ":{\"" SPDF_WIN_CHAPTER_STATE_MEMBER "\":[");
        for (i = 0; i < count; ++i) {
            if (i) spdf_win_cs_puts(&b, ",");
            spdf_win_cs_emit_string(&b, sorted[i]);
        }
        spdf_win_cs_puts(&b, "],\"path\":");
        spdf_win_cs_emit_string(&b, path);
        spdf_win_cs_puts(&b, "}");
    }
    spdf_win_cs_puts(&b, "}");
    free((void*)sorted);
    if (b.failed) {
        free(b.data);
        return NULL;
    }
    return b.data;
}

/* --- the files (spdf_win_chapter_state.c) --------------------------------- */

/* The collapsed keys remembered for `utf8_path`: chapters.yaml first, then the
 * documents.yaml record the mac writes. Returns 1 and fills the array (possibly
 * with zero keys) when a record was found, 0 when nothing is remembered --
 * both read as "expanded" for what they do not name. */
int spdf_win_chapter_state_load(const char* utf8_path, char*** out_keys, int* out_count);

/* Write the keys for `utf8_path` into chapters.yaml, dropping the record when
 * `count` is 0. Returns 1 on success; 0 when the file exists but could not be
 * read (never overwritten) or could not be written. */
int spdf_win_chapter_state_save(const char* utf8_path, const char* const* keys, int count);

void spdf_win_chapter_state_free_keys(char** keys, int count);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_CHAPTER_STATE_H */

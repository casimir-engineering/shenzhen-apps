/* spdf_win_md.cpp -- see spdf_win_md.h. */
#include "spdf_win_md.h"

#include "spdf_win_md_code.h"
#include "spdf_win_md_images.h"
#include "spdf_win_md_webp.h"
#include "spdf_win_state.h"

#include <windows.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

namespace {

/* Read by every opening thread, written by the UI thread. A float write is a
 * single aligned store on every Windows target; the generation is the
 * publication signal and goes through InterlockedIncrement. */
volatile float g_text_scale = 1.0f;
volatile LONG g_generation = 1;

float clamp_scale(float scale) {
    if (!(scale > 0.0f) || scale != scale) return 1.0f;
    if (scale < SPDF_WIN_MD_SCALE_MIN) return SPDF_WIN_MD_SCALE_MIN;
    if (scale > SPDF_WIN_MD_SCALE_MAX) return SPDF_WIN_MD_SCALE_MAX;
    return scale;
}

/* Two decimals, dot as the separator regardless of locale: the same rounding
 * ShenzhenPDFMac.mm applies before writing the key. */
void format_scale(float scale, char* out, size_t cap) {
    int hundredths = (int)floor(scale * 100.0f + 0.5f);
    snprintf(out, cap, "%d.%02d", hundredths / 100, hundredths % 100);
}

/* Minimal JSON scanning for one top-level numeric member. The frontend's
 * session module carries a fuller reader (spdf_win_session_json.h), but it is
 * module-internal to spdf_win_session.cpp; these thirty lines are what one
 * key needs and are pinned by md_win_test.c. */
const char* skip_ws(const char* p) {
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') ++p;
    return p;
}

const char* skip_string(const char* p) { /* p at the opening quote */
    ++p;
    while (*p && *p != '"') {
        if (*p == '\\' && p[1]) ++p;
        ++p;
    }
    return *p ? p + 1 : p;
}

const char* skip_value(const char* p) {
    int depth = 0;
    p = skip_ws(p);
    if (*p == '"') return skip_string(p);
    if (*p == '{' || *p == '[') {
        for (; *p; ++p) {
            if (*p == '"') {
                p = skip_string(p) - 1;
            } else if (*p == '{' || *p == '[') {
                ++depth;
            } else if (*p == '}' || *p == ']') {
                if (--depth == 0) return p + 1;
            }
        }
        return p;
    }
    while (*p && *p != ',' && *p != '}' && *p != ']' && *p != ' ' && *p != '\n' && *p != '\r' && *p != '\t') ++p;
    return p;
}

/* Locate the value of top-level key `key`: [*value, *end). 0 when absent. */
int find_member(const char* json, const char* key, const char** value, const char** end) {
    const char* p = skip_ws(json);
    size_t klen = strlen(key);
    if (*p != '{') return 0;
    ++p;
    for (;;) {
        const char* name;
        p = skip_ws(p);
        if (*p != '"') return 0;
        name = p + 1;
        p = skip_string(p);
        p = skip_ws(p);
        if (*p != ':') return 0;
        p = skip_ws(p + 1);
        if ((size_t)(skip_string(name - 1) - 1 - name) == klen && memcmp(name, key, klen) == 0) {
            *value = p;
            *end = skip_value(p);
            return 1;
        }
        p = skip_value(p);
        p = skip_ws(p);
        if (*p == ',') ++p;
        else return 0;
    }
}

} // namespace

/* --- options ------------------------------------------------------------------- */

float spdf_win_md_text_scale(void) {
    return g_text_scale;
}

void spdf_win_md_set_text_scale(float scale) {
    float clamped = clamp_scale(scale);
    if (fabsf(clamped - g_text_scale) < 1e-6f) return;
    g_text_scale = clamped;
    InterlockedIncrement(&g_generation);
}

int spdf_win_md_text_scale_step(int direction) {
    float before = g_text_scale;
    /* Step on the rounded hundredths so 1.0 -> 1.1 -> 1.2 stays exact. */
    int hundredths = (int)floor(before * 100.0f + 0.5f) + (direction > 0 ? 10 : -10);
    spdf_win_md_set_text_scale((float)hundredths / 100.0f);
    return fabsf(g_text_scale - before) > 1e-6f;
}

unsigned spdf_win_md_options_generation(void) {
    return (unsigned)g_generation;
}

void spdf_win_md_bump_options(void) {
    InterlockedIncrement(&g_generation);
}

void spdf_win_md_options(spdf_markdown_options* out) {
    static char cache_dir[1024];
    *out = spdf_markdown_default_options();
    out->text_scale = g_text_scale;
    out->dark_rendition = 1;
    /* The in-page picker's choices. Module storage on the other side, so the
     * borrowed pointer outlives every handle that reads it. */
    out->language_overrides = spdf_win_md_code_overrides(&out->language_override_count);
    if (spdf_win_md_images_dir(cache_dir, sizeof(cache_dir))) {
        out->remote_image = spdf_win_md_images_lookup;
        out->remote_image_user = NULL;
        out->remote_image_dir = cache_dir;
        /* The same cache holds the PNGs a local .webp is transcoded into
         * (spdf_win_md_webp.h); document_dir is filled by spdf_open_markdown. */
        out->local_image = spdf_win_md_webp_lookup;
        out->local_image_user = NULL;
    }
}

/* --- the seam --------------------------------------------------------------------- */

spdf_document* spdf_win_md_open_any(const char* utf8_path, char* err, size_t err_len) {
    spdf_markdown_options options;
    if (!spdf_path_is_markdown(utf8_path)) return spdf_open(utf8_path, err, err_len);
    spdf_win_md_options_for_path(utf8_path, &options);
    return spdf_open_markdown(utf8_path, &options, err, err_len);
}

/* --- page orientation, per file ------------------------------------------------- */

namespace {

/* Only the LANDSCAPE files are in the table: absent means portrait, which is
 * the default and what every PDF and every never-turned document has, so the
 * table stays the size of the reader's turned documents rather than of their
 * history. Read on every opening thread, written on the UI thread. */
SRWLOCK g_orient_lock = SRWLOCK_INIT;
char** g_landscape;
int g_landscape_count;
int g_landscape_cap;

char fold(char c) {
    if (c == '/') return '\\';
    if (c >= 'A' && c <= 'Z') return (char)(c - 'A' + 'a');
    return c;
}

/* Locked by the caller. */
int landscape_index(const char* path) {
    int i;
    for (i = 0; i < g_landscape_count; ++i)
        if (spdf_win_md_path_equal(g_landscape[i], path)) return i;
    return -1;
}

/* Locked by the caller. Returns 1 when the table changed. */
int landscape_set_locked(const char* path, int landscape) {
    int i = landscape_index(path);
    if (landscape && i < 0) {
        char* copy;
        if (g_landscape_count == g_landscape_cap) {
            int cap = g_landscape_cap ? g_landscape_cap * 2 : 16;
            char** grown = (char**)realloc(g_landscape, (size_t)cap * sizeof(*grown));
            if (!grown) return 0;
            g_landscape = grown;
            g_landscape_cap = cap;
        }
        copy = _strdup(path);
        if (!copy) return 0;
        g_landscape[g_landscape_count++] = copy;
        return 1;
    }
    if (!landscape && i >= 0) {
        free(g_landscape[i]);
        g_landscape[i] = g_landscape[--g_landscape_count];
        return 1;
    }
    return 0;
}

void landscape_clear_locked(void) {
    int i;
    for (i = 0; i < g_landscape_count; ++i) free(g_landscape[i]);
    g_landscape_count = 0;
}

/* A JSON string at `p` (the opening quote) into `out`, unescaped as far as
 * a path needs (\\ \" \/ and the rest of the one-character escapes; a \u
 * escape is kept literally, since no path writer here produces one). */
void unquote(const char* p, char* out, size_t cap) {
    size_t n = 0;
    ++p;
    while (*p && *p != '"' && n + 1 < cap) {
        char c = *p++;
        if (c == '\\' && *p) {
            char e = *p++;
            c = e == 'n' ? '\n' : e == 't' ? '\t' : e == 'r' ? '\r' : e;
        }
        out[n++] = c;
    }
    out[n] = 0;
}

/* Grow-as-you-go output for the writer. */
struct sbuf {
    char* data;
    size_t len, cap;
    int failed;
};

void sput(sbuf* b, const char* s) {
    size_t n = strlen(s);
    if (b->failed) return;
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap * 2 : 256;
        char* grown;
        while (cap < b->len + n + 1) cap *= 2;
        grown = (char*)realloc(b->data, cap);
        if (!grown) {
            b->failed = 1;
            return;
        }
        b->data = grown;
        b->cap = cap;
    }
    memcpy(b->data + b->len, s, n + 1);
    b->len += n;
}

void squote(sbuf* b, const char* s) {
    char one[3] = {0, 0, 0};
    sput(b, "\"");
    for (; *s; ++s) {
        if (*s == '"' || *s == '\\') {
            one[0] = '\\';
            one[1] = *s;
        } else {
            one[0] = *s;
            one[1] = 0;
        }
        sput(b, one);
    }
    sput(b, "\"");
}

} // namespace

int spdf_win_md_path_equal(const char* a, const char* b) {
    if (!a || !b) return 0;
    for (; *a && *b; ++a, ++b)
        if (fold(*a) != fold(*b)) return 0;
    return *a == 0 && *b == 0;
}

int spdf_win_md_landscape_for(const char* utf8_path) {
    int found;
    if (!utf8_path || !*utf8_path) return 0;
    AcquireSRWLockShared(&g_orient_lock);
    found = landscape_index(utf8_path) >= 0;
    ReleaseSRWLockShared(&g_orient_lock);
    return found;
}

int spdf_win_md_set_landscape(const char* utf8_path, int landscape) {
    int changed;
    if (!utf8_path || !*utf8_path) return 0;
    AcquireSRWLockExclusive(&g_orient_lock);
    changed = landscape_set_locked(utf8_path, landscape != 0);
    ReleaseSRWLockExclusive(&g_orient_lock);
    /* A different sheet is a different pagination: every handle has to be
     * remade, and the generation is how a long-lived one finds out. */
    if (changed) InterlockedIncrement(&g_generation);
    return changed;
}

int spdf_win_md_toggle_landscape(const char* utf8_path) {
    int now = !spdf_win_md_landscape_for(utf8_path);
    spdf_win_md_set_landscape(utf8_path, now);
    spdf_win_md_save_orientation();
    return now;
}

void spdf_win_md_options_for_path(const char* utf8_path, spdf_markdown_options* out) {
    spdf_win_md_options(out);
    out->landscape = spdf_win_md_landscape_for(utf8_path);
}

int spdf_win_md_orientation_from_json(const char* json) {
    const char* p;
    int read = 0;
    AcquireSRWLockExclusive(&g_orient_lock);
    landscape_clear_locked();
    p = json ? skip_ws(json) : "";
    if (*p == '{') {
        ++p;
        for (;;) {
            const char* name;
            const char* value;
            const char* end;
            char path[1024];
            p = skip_ws(p);
            if (*p != '"') break;
            name = p;
            p = skip_string(p);
            p = skip_ws(p);
            if (*p != ':') break;
            p = skip_ws(p + 1);
            /* { "<path>": { "markdownLandscape": true, ... } } -- the value of
             * the record's member decides; the record's key is the path. */
            if (*p == '{' && find_member(p, SPDF_WIN_MD_LANDSCAPE_KEY, &value, &end) &&
                strncmp(value, "true", 4) == 0) {
                unquote(name, path, sizeof(path));
                if (path[0] && landscape_set_locked(path, 1)) ++read;
            }
            p = skip_value(p);
            p = skip_ws(p);
            if (*p != ',') break;
            ++p;
        }
    }
    ReleaseSRWLockExclusive(&g_orient_lock);
    return read;
}

char* spdf_win_md_orientation_to_json(void) {
    sbuf b = {NULL, 0, 0, 0};
    int i;
    AcquireSRWLockShared(&g_orient_lock);
    sput(&b, "{");
    for (i = 0; i < g_landscape_count; ++i) {
        if (i) sput(&b, ",");
        squote(&b, g_landscape[i]);
        sput(&b, ":{\"" SPDF_WIN_MD_LANDSCAPE_KEY "\":true,\"path\":");
        squote(&b, g_landscape[i]);
        sput(&b, "}");
    }
    sput(&b, "}");
    ReleaseSRWLockShared(&g_orient_lock);
    if (b.failed) {
        free(b.data);
        return NULL;
    }
    return b.data;
}

int spdf_win_md_load_orientation(void) {
    char* json = spdf_win_state_read_json(SPDF_WIN_MD_ORIENTATION_FILE);
    int read = spdf_win_md_orientation_from_json(json);
    free(json);
    return read;
}

int spdf_win_md_save_orientation(void) {
    spdf_win_state_read_status status = SPDF_WIN_STATE_READ_FAILED;
    char* existing = spdf_win_state_read_json_checked(SPDF_WIN_MD_ORIENTATION_FILE, &status);
    char* json;
    int ok;
    free(existing);
    if (!existing && status == SPDF_WIN_STATE_READ_FAILED) return 0; /* unknown contents: never overwrite */
    json = spdf_win_md_orientation_to_json();
    if (!json) return 0;
    ok = spdf_win_state_write_json(SPDF_WIN_MD_ORIENTATION_FILE, json);
    free(json);
    return ok;
}

/* --- persistence ------------------------------------------------------------------- */

float spdf_win_md_settings_scale(const char* settings_json) {
    const char* value;
    const char* end;
    if (!settings_json || !find_member(settings_json, SPDF_WIN_MD_SETTINGS_KEY, &value, &end)) return 1.0f;
    if (*value == '"') ++value; /* a quoted number, in case a hand edit left one */
    return clamp_scale((float)atof(value));
}

char* spdf_win_md_settings_with_scale(const char* settings_json, float scale) {
    char number[32];
    const char* value = NULL;
    const char* end = NULL;
    size_t before, after, total;
    char* out;
    const char* json = settings_json && *skip_ws(settings_json) == '{' ? settings_json : "{}";

    format_scale(clamp_scale(scale), number, sizeof(number));
    if (find_member(json, SPDF_WIN_MD_SETTINGS_KEY, &value, &end)) {
        before = (size_t)(value - json);
        after = strlen(end);
        total = before + strlen(number) + after;
        out = (char*)malloc(total + 1);
        if (!out) return NULL;
        memcpy(out, json, before);
        memcpy(out + before, number, strlen(number));
        memcpy(out + before + strlen(number), end, after + 1);
        return out;
    }
    /* Absent: insert before the closing brace, with a comma if the object
     * already has members. */
    {
        const char* close = json + strlen(json);
        const char* first;
        int has_members;
        while (close > json && close[-1] != '}') --close;
        if (close == json) return NULL; /* not an object at all */
        --close;
        first = skip_ws(json + 1);
        has_members = *first != '}';
        before = (size_t)(close - json);
        total = before + 1 + strlen(SPDF_WIN_MD_SETTINGS_KEY) + 3 + strlen(number) + strlen(close) + 1;
        out = (char*)malloc(total + 1);
        if (!out) return NULL;
        memcpy(out, json, before);
        snprintf(out + before, total + 1 - before, "%s\"%s\":%s%s", has_members ? "," : "", SPDF_WIN_MD_SETTINGS_KEY,
                 number, close);
        return out;
    }
}

int spdf_win_md_load_settings(void) {
    char* json = spdf_win_state_read_json(SPDF_WIN_STATE_SETTINGS);
    const char* value;
    const char* end;
    int found = json && find_member(json, SPDF_WIN_MD_SETTINGS_KEY, &value, &end);
    spdf_win_md_set_text_scale(spdf_win_md_settings_scale(json));
    free(json);
    /* The per-file orientation table rides the same load, so main.cpp's one
     * call brings in everything this module remembers. */
    spdf_win_md_load_orientation();
    return found;
}

int spdf_win_md_save_settings(void) {
    spdf_win_state_read_status status = SPDF_WIN_STATE_READ_FAILED;
    char* json = spdf_win_state_read_json_checked(SPDF_WIN_STATE_SETTINGS, &status);
    char* merged;
    int ok;
    if (!json && status == SPDF_WIN_STATE_READ_FAILED) return 0; /* unknown contents: never overwrite */
    merged = spdf_win_md_settings_with_scale(json, g_text_scale);
    free(json);
    if (!merged) return 0;
    ok = spdf_win_state_write_json(SPDF_WIN_STATE_SETTINGS, merged);
    free(merged);
    return ok;
}

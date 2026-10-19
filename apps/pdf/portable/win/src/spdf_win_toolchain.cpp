/* spdf_win_toolchain.cpp -- the PURE half of spdf_win_toolchain.h: candidate
 * paths, PATH search, version parsing, language and Argos helpers, command
 * lines, install plans, the line splitter and the settings JSON accessors.
 * Nothing here touches the filesystem, the registry, the network or a process;
 * portable/win/tests/toolchain_test.c drives every function below with strings.
 * The Win32 half is spdf_win_toolchain_run.cpp. */
#include "spdf_win_toolchain.h"
#include "spdf_win_toolchain_internal.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* --- small string helpers -------------------------------------------------- */

size_t spdf_win_tc_put(char* out, size_t cap, size_t at, const char* s) {
    size_t n = strlen(s);
    if (!out || !cap) return at + n;
    if (at < cap) {
        size_t room = cap - 1 - at;
        size_t copy = n < room ? n : room;
        memcpy(out + at, s, copy);
        out[at + copy] = '\0';
    }
    return at + n;
}

int spdf_win_tc_join2(char* out, size_t cap, const char* dir, const char* leaf) {
    size_t n = strlen(dir);
    if (!dir[0] || n + 1 + strlen(leaf) + 1 > cap) return 0;
    memcpy(out, dir, n);
    if (dir[n - 1] != '\\' && dir[n - 1] != '/') out[n++] = '\\';
    strcpy(out + n, leaf);
    return 1;
}

static const char* trim_view(const char* s, size_t* len) {
    const char* e;
    while (*s == ' ' || *s == '\t' || *s == '\r') ++s;
    e = s + strlen(s);
    while (e > s && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\r')) --e;
    *len = (size_t)(e - s);
    return s;
}

/* --- tools ------------------------------------------------------------------ */

static const char* const k_exe[SPDF_WIN_TOOL_COUNT] = {
    "tesseract.exe", "gswin64c.exe", "python.exe", "ocrmypdf.exe", "argos-translate.exe",
    "argospm.exe",   "winget.exe",   "curl.exe",
};

const char* spdf_win_tool_exe(spdf_win_tool tool) {
    return tool >= 0 && tool < SPDF_WIN_TOOL_COUNT ? k_exe[tool] : "";
}

int spdf_win_toolchain_candidates(spdf_win_tool tool, const SpdfWinToolchainRoots* r,
                                  char out[SPDF_WIN_TC_MAX_CANDIDATES][SPDF_WIN_TC_PATH]) {
    int n = 0;
    char dir[SPDF_WIN_TC_PATH];
#define CAND(root, rel)                                                                                                \
    do {                                                                                                               \
        if (n < SPDF_WIN_TC_MAX_CANDIDATES && (root)[0] &&                                                            \
            (strcmp((rel), ".") == 0 ? (snprintf(dir, sizeof(dir), "%s", (root)) < (int)sizeof(dir))                  \
                                     : join2(dir, sizeof(dir), (root), (rel))) &&                                      \
            join2(out[n], SPDF_WIN_TC_PATH, dir, k_exe[tool]))                                                         \
            ++n;                                                                                                       \
    } while (0)
    if (!r) return 0;
    switch (tool) {
        case SPDF_WIN_TOOL_TESSERACT:
            CAND(r->program_files, "Tesseract-OCR");
            CAND(r->local_appdata, "Programs\\Tesseract-OCR");
            CAND(r->local_appdata, "Tesseract-OCR");
            break;
        case SPDF_WIN_TOOL_GHOSTSCRIPT:
            /* A per-user install first, then the installer's default. */
            CAND(r->local_appdata, "Programs\\gs\\gs*\\bin");
            CAND(r->program_files, "gs\\gs*\\bin");
            break;
        case SPDF_WIN_TOOL_PYTHON:
            CAND(r->local_appdata, "Programs\\Python\\Python3*");
            CAND(r->local_appdata, "Microsoft\\WindowsApps");
            break;
        case SPDF_WIN_TOOL_OCRMYPDF: CAND(r->user_scripts, "."); break;
        case SPDF_WIN_TOOL_ARGOS_TRANSLATE:
        case SPDF_WIN_TOOL_ARGOSPM:
            /* Our venv first (the header says why), then a pip --user install. */
            CAND(r->user_profile, ".shenzhenpdf\\argos\\Scripts");
            CAND(r->user_scripts, ".");
            break;
        case SPDF_WIN_TOOL_WINGET: CAND(r->local_appdata, "Microsoft\\WindowsApps"); break;
        case SPDF_WIN_TOOL_CURL: CAND(r->system_root, "System32"); break;
        default: break;
    }
#undef CAND
    return n;
}

int spdf_win_toolchain_search_path_env(const char* path_env, const char* exe, spdf_win_toolchain_exists_fn exists,
                                       void* user, char* out, size_t out_bytes) {
    const char* p = path_env ? path_env : "";
    char dir[SPDF_WIN_TC_PATH];
    char full[SPDF_WIN_TC_PATH];
    while (*p) {
        const char* e = strchr(p, ';');
        size_t n = e ? (size_t)(e - p) : strlen(p);
        if (n >= 2 && p[0] == '"' && p[n - 1] == '"') {
            ++p;
            n -= 2;
        }
        if (n > 0 && n < sizeof(dir)) {
            memcpy(dir, p, n);
            dir[n] = '\0';
            if (join2(full, sizeof(full), dir, exe) && exists && exists(full, user)) {
                if (strlen(full) + 1 > out_bytes) return 0;
                strcpy(out, full);
                return 1;
            }
        }
        if (!e) break;
        p = e + 1;
    }
    return 0;
}

/* Digits after the first digit in the name, as a dotted version. */
static int version_of(const char* s, int v[3]) {
    int i = 0;
    v[0] = v[1] = v[2] = 0;
    while (*s && !isdigit((unsigned char)*s)) ++s;
    if (!*s) return 0;
    while (*s && i < 3) {
        if (isdigit((unsigned char)*s)) v[i] = v[i] * 10 + (*s - '0');
        else if (*s == '.') ++i;
        else break;
        ++s;
    }
    return 1;
}

int spdf_win_toolchain_newest_version_index(const char* const* names, int count) {
    int best = -1, bv[3] = {-1, -1, -1};
    for (int i = 0; i < count; ++i) {
        int v[3];
        if (!names[i] || !version_of(names[i], v)) continue;
        if (best < 0 || v[0] > bv[0] || (v[0] == bv[0] && (v[1] > bv[1] || (v[1] == bv[1] && v[2] > bv[2])))) {
            best = i;
            memcpy(bv, v, sizeof(v));
        }
    }
    return best;
}

int spdf_win_toolchain_parse_version(const char* text, int* major, int* minor, int* patch) {
    const char* p = text ? text : "";
    while (*p) {
        if (isdigit((unsigned char)*p) && (p == text || !isalnum((unsigned char)p[-1]) || p[-1] == 'v')) {
            const char* q = p;
            int v[3] = {0, 0, 0}, i = 0;
            while (*q && i < 3) {
                if (isdigit((unsigned char)*q)) v[i] = v[i] * 10 + (*q - '0');
                else if (*q == '.' && isdigit((unsigned char)q[1])) ++i;
                else break;
                ++q;
            }
            if (i >= 1) {
                if (major) *major = v[0];
                if (minor) *minor = v[1];
                if (patch) *patch = v[2];
                return 1;
            }
            p = q;
        }
        ++p;
    }
    return 0;
}

/* --- Tesseract languages --------------------------------------------------- */

int spdf_win_ocr_language_components(const char* language, char out[8][32]) {
    const char* p = language && *language ? language : "eng";
    int n = 0;
    while (*p && n < 8) {
        const char* e = strchr(p, '+');
        size_t len = e ? (size_t)(e - p) : strlen(p);
        if (len > 0 && len < 32) {
            memcpy(out[n], p, len);
            out[n][len] = '\0';
            ++n;
        }
        if (!e) break;
        p = e + 1;
    }
    return n;
}

int spdf_win_ocr_language_uses_extra_traineddata(const char* language) {
    char parts[8][32];
    int n = spdf_win_ocr_language_components(language, parts);
    for (int i = 0; i < n; ++i)
        if (strcmp(parts[i], "eng") != 0) return 1;
    return 0;
}

static int output_lists(const char* output, const char* name) {
    const char* p = output ? output : "";
    while (*p) {
        const char* e = strchr(p, '\n');
        size_t n = e ? (size_t)(e - p) : strlen(p);
        char line[64];
        if (n < sizeof(line)) {
            size_t tl;
            const char* t;
            memcpy(line, p, n);
            line[n] = '\0';
            t = trim_view(line, &tl);
            if (tl == strlen(name) && strncmp(t, name, tl) == 0) return 1;
        }
        if (!e) break;
        p = e + 1;
    }
    return 0;
}

int spdf_win_toolchain_list_output_has_language(const char* output, const char* language) {
    char parts[8][32];
    int n = spdf_win_ocr_language_components(language, parts);
    if (n == 0) return 0;
    for (int i = 0; i < n; ++i)
        if (!output_lists(output, parts[i])) return 0;
    return 1;
}

/* --- Argos ------------------------------------------------------------------ */

int spdf_win_toolchain_is_argos_diagnostic_line(const char* line, int previous_line_was_diagnostic) {
    size_t n;
    const char* t;
    char buf[512];
    if (!line) return 0;
    t = trim_view(line, &n);
    if (n >= sizeof(buf)) n = sizeof(buf) - 1;
    memcpy(buf, t, n);
    buf[n] = '\0';
    if (strstr(buf, "WARNING: Language ") && strstr(buf, " package ") && strstr(buf, " expects ")) return 1;
    if (previous_line_was_diagnostic)
        return strcmp(buf, "added") == 0 || strncmp(buf, "which has been added", 20) == 0;
    return 0;
}

size_t spdf_win_toolchain_strip_argos_diagnostics(const char* text, char* out, size_t out_bytes) {
    const char* p = text ? text : "";
    size_t at = 0;
    int prev = 0, first = 1;
    if (out && out_bytes) out[0] = '\0';
    while (*p || (p == text && !*p)) {
        const char* e = strchr(p, '\n');
        size_t n = e ? (size_t)(e - p) : strlen(p);
        char line[2048];
        int diag;
        size_t copy = n < sizeof(line) - 1 ? n : sizeof(line) - 1;
        memcpy(line, p, copy);
        line[copy] = '\0';
        diag = spdf_win_toolchain_is_argos_diagnostic_line(line, prev);
        if (!diag) {
            if (!first) at = put(out, out_bytes, at, "\n");
            at = put(out, out_bytes, at, line);
            first = 0;
        }
        prev = diag;
        if (!e) break;
        p = e + 1;
        if (!*p) { /* text ended in '\n': keep the terminator, as g_strsplit did */
            if (!first) at = put(out, out_bytes, at, "\n");
            break;
        }
    }
    return at;
}

int spdf_win_toolchain_argos_failure_is_missing_package(const char* failure) {
    if (!failure) return 0;
    return strstr(failure, "is not an installed language") != NULL || strstr(failure, "No package") != NULL;
}

int spdf_win_toolchain_argos_package_name(const char* from_lang, const char* to_lang, char* out, size_t out_bytes) {
    if (!from_lang || !*from_lang || !to_lang || !*to_lang) return 0;
    return snprintf(out, out_bytes, "translate-%s_%s", from_lang, to_lang) < (int)out_bytes;
}

/* --- line splitter -------------------------------------------------------- */

void spdf_win_line_splitter_init(SpdfWinLineSplitter* s) { memset(s, 0, sizeof(*s)); }

static void emit(SpdfWinLineSplitter* s, spdf_win_toolchain_line_fn cb, void* user) {
    s->buf[s->len] = '\0';
    if (cb) cb(s->buf, user);
    s->len = 0;
}

void spdf_win_line_splitter_feed(SpdfWinLineSplitter* s, const char* bytes, size_t n, spdf_win_toolchain_line_fn cb,
                                 void* user) {
    for (size_t i = 0; i < n; ++i) {
        unsigned char c = (unsigned char)bytes[i];
        if (s->esc == 1) { /* after ESC */
            s->esc = c == '[' ? 2 : c == ']' ? 3 : 0;
            continue;
        }
        if (s->esc == 2) { /* CSI: parameters, then a final byte 0x40-0x7E */
            if (c >= 0x40 && c <= 0x7E) s->esc = 0;
            continue;
        }
        if (s->esc == 3) { /* OSC: until BEL or ST */
            if (c == 0x07 || c == 0x9C) s->esc = 0;
            if (c == 0x1B) s->esc = 1;
            continue;
        }
        if (c == 0x1B) {
            s->esc = 1;
            continue;
        }
        if (c == '\r') {
            if (s->len) emit(s, cb, user);
            s->pending_cr = 1;
            continue;
        }
        if (c == '\n') {
            if (!(s->pending_cr && s->len == 0)) emit(s, cb, user);
            s->pending_cr = 0;
            continue;
        }
        s->pending_cr = 0;
        if (c == '\b' || c == 0) continue;
        if (s->len >= (int)sizeof(s->buf) - 1) emit(s, cb, user);
        s->buf[s->len++] = (char)c;
    }
}

void spdf_win_line_splitter_flush(SpdfWinLineSplitter* s, spdf_win_toolchain_line_fn cb, void* user) {
    if (s->len) emit(s, cb, user);
    s->pending_cr = 0;
}

/* --- settings JSON ----------------------------------------------------------- */

/* Position of the value's opening quote for "key": "...", or NULL. */
static const char* json_find_value(const char* json, const char* key, const char** value_end) {
    char quoted[128];
    const char* p = json;
    if (!json || snprintf(quoted, sizeof(quoted), "\"%s\"", key) >= (int)sizeof(quoted)) return NULL;
    while ((p = strstr(p, quoted)) != NULL) {
        const char* q = p + strlen(quoted);
        while (*q == ' ' || *q == '\t' || *q == '\n' || *q == '\r') ++q;
        if (*q == ':') {
            ++q;
            while (*q == ' ' || *q == '\t' || *q == '\n' || *q == '\r') ++q;
            if (*q == '"') {
                const char* e = q + 1;
                while (*e && *e != '"') e += (*e == '\\' && e[1]) ? 2 : 1;
                if (!*e) return NULL;
                *value_end = e + 1;
                return q;
            }
            return NULL;
        }
        p = q;
    }
    return NULL;
}

int spdf_win_toolchain_json_get_string(const char* json, const char* key, char* out, size_t out_bytes) {
    const char* end;
    const char* q = json_find_value(json, key, &end);
    size_t at = 0;
    if (!q || !out || !out_bytes) return 0;
    for (const char* p = q + 1; p < end - 1 && at + 1 < out_bytes; ++p) {
        char c = *p;
        if (c == '\\' && p + 1 < end - 1) {
            ++p;
            c = *p == 'n' ? '\n' : *p == 't' ? '\t' : *p;
        }
        out[at++] = c;
    }
    out[at] = '\0';
    return 1;
}

int spdf_win_toolchain_json_set_string(const char* json, const char* key, const char* value, char* out,
                                       size_t out_bytes) {
    char escaped[512];
    size_t e = 0, at = 0;
    const char* end;
    const char* q;
    for (const char* p = value ? value : ""; *p && e + 2 < sizeof(escaped); ++p) {
        if (*p == '"' || *p == '\\') escaped[e++] = '\\';
        escaped[e++] = *p;
    }
    escaped[e] = '\0';
    if (!json || !*json) {
        at = put(out, out_bytes, at, "{\"");
        at = put(out, out_bytes, at, key);
        at = put(out, out_bytes, at, "\":\"");
        at = put(out, out_bytes, at, escaped);
        at = put(out, out_bytes, at, "\"}");
        return at < out_bytes;
    }
    q = json_find_value(json, key, &end);
    if (q) {
        char head[SPDF_WIN_TC_ENV];
        size_t n = (size_t)(q - json);
        if (n >= sizeof(head)) return 0;
        memcpy(head, json, n);
        head[n] = '\0';
        at = put(out, out_bytes, at, head);
        at = put(out, out_bytes, at, "\"");
        at = put(out, out_bytes, at, escaped);
        at = put(out, out_bytes, at, "\"");
        at = put(out, out_bytes, at, end);
        return at < out_bytes;
    }
    {
        const char* close = strrchr(json, '}');
        const char* body_end = close;
        char head[SPDF_WIN_TC_ENV];
        int empty;
        if (!close || (size_t)(close - json) >= sizeof(head)) return 0;
        while (body_end > json && (body_end[-1] == ' ' || body_end[-1] == '\n' || body_end[-1] == '\r' ||
                                   body_end[-1] == '\t'))
            --body_end;
        empty = body_end > json && body_end[-1] == '{';
        memcpy(head, json, (size_t)(body_end - json));
        head[body_end - json] = '\0';
        at = put(out, out_bytes, at, head);
        at = put(out, out_bytes, at, empty ? "\"" : ",\"");
        at = put(out, out_bytes, at, key);
        at = put(out, out_bytes, at, "\":\"");
        at = put(out, out_bytes, at, escaped);
        at = put(out, out_bytes, at, "\"");
        at = put(out, out_bytes, at, close);
        return at < out_bytes;
    }
}

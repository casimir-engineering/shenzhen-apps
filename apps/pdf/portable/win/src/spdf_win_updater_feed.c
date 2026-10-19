/* spdf_win_updater_feed.c — GitHub's /releases/latest, parsed; the
 * availability decision; the release-notes formatter; the sha256 sidecar.
 *
 * Transcribed from portable/linux/gtk4/spdf_updater.c sections 3 and 4
 * (:529-807) with glib removed. The one deliberate difference is the sidecar:
 * GTK looks for "<asset>.minisig" because minisign is its trust; this port's
 * trust is Authenticode inside the exe itself, so the sidecar is the
 * "<asset>.sha256" integrity file and the caller names the suffix.
 *
 * Pure C, no <windows.h>; portable/win/tests/updater_feed_test.c drives it
 * with canned JSON and never touches the network.
 */
#include "spdf_win_updater.h"
#include "spdf_win_updater_json.h"

#include <stdlib.h>
#include <string.h>

/* --- the release ---------------------------------------------------------- */

typedef struct js_asset {
    char* name;
    char* url;
    long long size;
} js_asset;

static int parse_asset(spdf_win_js_cursor* c, js_asset* asset) {
    char* key;
    int r;

    memset(asset, 0, sizeof(*asset));
    if (!spdf_win_js_enter_object(c)) return 0;
    while ((r = spdf_win_js_next_member(c, &key)) > 0) {
        int ok;
        if (strcmp(key, "name") == 0) {
            free(asset->name);
            asset->name = spdf_win_js_read_string(c);
            ok = asset->name != NULL;
        } else if (strcmp(key, "browser_download_url") == 0) {
            free(asset->url);
            asset->url = spdf_win_js_read_string(c);
            ok = asset->url != NULL;
        } else if (strcmp(key, "size") == 0) {
            ok = spdf_win_js_read_int(c, &asset->size);
        } else {
            ok = spdf_win_js_skip_value(c);
        }
        free(key);
        if (!ok) return 0;
    }
    return r == 0;
}

static char* concat(const char* a, const char* b) {
    size_t la = strlen(a), lb = strlen(b);
    char* out = (char*)malloc(la + lb + 1);
    if (!out) return NULL;
    memcpy(out, a, la);
    memcpy(out + la, b, lb + 1);
    return out;
}

static int parse_assets_array(spdf_win_js_cursor* c, const char* asset_name, const char* sidecar_name,
                              spdf_win_release_info* out) {
    int ok = 1;

    spdf_win_js_skip_ws(c);
    if (c->p >= c->end || *c->p != '[') return spdf_win_js_skip_value(c); /* "assets": null */
    c->p++;
    spdf_win_js_skip_ws(c);
    if (c->p < c->end && *c->p == ']') {
        c->p++;
        return 1;
    }
    while (ok) {
        js_asset asset;
        ok = parse_asset(c, &asset);
        if (ok && asset.name && asset.url) {
            if (strcmp(asset.name, asset_name) == 0) {
                free(out->asset_url);
                out->asset_url = asset.url;
                asset.url = NULL;
                out->asset_size = asset.size;
            } else if (strcmp(asset.name, sidecar_name) == 0) {
                free(out->sidecar_url);
                out->sidecar_url = asset.url;
                asset.url = NULL;
            }
        }
        free(asset.name);
        free(asset.url);
        if (!ok) break;
        spdf_win_js_skip_ws(c);
        if (c->p < c->end && *c->p == ',') {
            c->p++;
            continue;
        }
        if (c->p < c->end && *c->p == ']') {
            c->p++;
            return 1;
        }
        ok = 0;
    }
    return ok;
}

int spdf_win_updater_parse_release(const char* json, long len, const char* asset_name, const char* sidecar_suffix,
                                   spdf_win_release_info* out) {
    spdf_win_js_cursor c;
    char* sidecar_name;
    char* key;
    int r = -1;
    int ok = 1;

    if (out) memset(out, 0, sizeof(*out));
    if (!json || !asset_name || !out) return 0;
    c.p = json;
    c.end = json + (len < 0 ? (long)strlen(json) : len);
    sidecar_name = concat(asset_name, sidecar_suffix ? sidecar_suffix : "");
    if (!sidecar_name) return 0;

    if (!spdf_win_js_enter_object(&c)) ok = 0;
    while (ok && (r = spdf_win_js_next_member(&c, &key)) > 0) {
        if (strcmp(key, "tag_name") == 0) {
            free(out->tag);
            out->tag = spdf_win_js_read_string(&c);
            ok = out->tag != NULL;
        } else if (strcmp(key, "draft") == 0) {
            ok = spdf_win_js_read_bool(&c, &out->draft);
        } else if (strcmp(key, "prerelease") == 0) {
            ok = spdf_win_js_read_bool(&c, &out->prerelease);
        } else if (strcmp(key, "body") == 0) {
            spdf_win_js_skip_ws(&c);
            if (c.p < c.end && *c.p == '"') {
                free(out->notes);
                out->notes = spdf_win_js_read_string(&c);
                ok = out->notes != NULL;
            } else {
                ok = spdf_win_js_skip_value(&c); /* null body */
            }
        } else if (strcmp(key, "assets") == 0) {
            ok = parse_assets_array(&c, asset_name, sidecar_name, out);
        } else {
            ok = spdf_win_js_skip_value(&c);
        }
        free(key);
    }
    free(sidecar_name);
    if (!ok || r != 0 || !out->tag || !*out->tag) {
        spdf_win_release_info_clear(out);
        return 0;
    }
    return 1;
}

void spdf_win_release_info_clear(spdf_win_release_info* info) {
    if (!info) return;
    free(info->tag);
    free(info->notes);
    free(info->asset_url);
    free(info->sidecar_url);
    memset(info, 0, sizeof(*info));
}

/* --- the decision --------------------------------------------------------- */

int spdf_win_updater_release_available(const spdf_win_release_info* info, const char* running,
                                       const char* highest_seen) {
    if (!info || !info->tag || !*info->tag || !running || !*running) return 0;
    if (info->draft || info->prerelease) return 0;
    if (!info->asset_url || !*info->asset_url) return 0;
    if (!info->sidecar_url || !*info->sidecar_url) return 0; /* incomplete release: never offer */
    if (spdf_win_updater_compare_versions(info->tag, running) <= 0) return 0;
    /* Downgrade/replay guard against the high-water mark. */
    if (highest_seen && *highest_seen && spdf_win_updater_compare_versions(info->tag, highest_seen) < 0) return 0;
    return 1;
}

/* --- the sidecar ---------------------------------------------------------- */

int spdf_win_updater_parse_sha256_sidecar(const char* text, char* out_hex, size_t out_len) {
    int i;
    if (!out_hex || out_len < 65) return 0;
    out_hex[0] = '\0';
    if (!text) return 0;
    while (*text == ' ' || *text == '\t' || *text == '\r' || *text == '\n') text++;
    for (i = 0; i < 64; ++i) {
        char ch = text[i];
        if (ch >= '0' && ch <= '9') out_hex[i] = ch;
        else if (ch >= 'a' && ch <= 'f') out_hex[i] = ch;
        else if (ch >= 'A' && ch <= 'F') out_hex[i] = (char)(ch - 'A' + 'a');
        else {
            out_hex[0] = '\0';
            return 0;
        }
    }
    /* The 65th character must end the digest: a 65-hex-digit string is not a
     * SHA-256 with a typo, it is not a SHA-256. */
    if (text[64] && text[64] != ' ' && text[64] != '\t' && text[64] != '\r' && text[64] != '\n' &&
        text[64] != '*') {
        out_hex[0] = '\0';
        return 0;
    }
    out_hex[64] = '\0';
    return 1;
}

/* --- the release notes ---------------------------------------------------- */

static int starts_with(const char* s, const char* prefix) {
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

/* Trims in place; returns the new start. */
static char* strip(char* s) {
    char* end;
    while (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n') s++;
    end = s + strlen(s);
    while (end > s && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r' || end[-1] == '\n')) *--end = '\0';
    return s;
}

/* Every occurrence of `marker` removed. */
static void remove_marker(spdf_win_sb* out, const char* in, const char* marker) {
    size_t mlen = strlen(marker);
    while (*in) {
        if (strncmp(in, marker, mlen) == 0) {
            in += mlen;
            continue;
        }
        spdf_win_sb_append_c(out, *in++);
    }
}

/* One decoded code point and its byte length; 0 length ends the walk on an
 * invalid sequence, which mirrors the original's g_utf8_get_char_validated. */
static int utf8_next(const char* p, unsigned* cp) {
    unsigned char b = (unsigned char)*p;
    if (b < 0x80) { *cp = b; return 1; }
    if ((b & 0xE0) == 0xC0 && (p[1] & 0xC0) == 0x80) {
        *cp = ((unsigned)(b & 0x1F) << 6) | (unsigned)(p[1] & 0x3F);
        return 2;
    }
    if ((b & 0xF0) == 0xE0 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80) {
        *cp = ((unsigned)(b & 0x0F) << 12) | ((unsigned)(p[1] & 0x3F) << 6) | (unsigned)(p[2] & 0x3F);
        return 3;
    }
    if ((b & 0xF8) == 0xF0 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80 && (p[3] & 0xC0) == 0x80) {
        *cp = ((unsigned)(b & 0x07) << 18) | ((unsigned)(p[1] & 0x3F) << 12) | ((unsigned)(p[2] & 0x3F) << 6) |
              (unsigned)(p[3] & 0x3F);
        return 4;
    }
    return 0;
}

/* Port of spdf_updater_format_notes, which is a port of
 * spdf_format_release_notes_for_alert (SPDFUpdater.mm). The lines are gathered
 * one per array slot so that a hard-wrapped continuation can be joined onto the
 * previous one and a bullet can be kept as its own line -- which is the whole
 * of the 26.7.17-1 fix: the prompt shows the highlights as a bulleted list, not
 * one run-together paragraph. */
char* spdf_win_updater_format_notes(const char* body) {
    char* copy;
    char** lines = NULL;
    size_t nlines = 0, cap = 0;
    char* line;
    char* next;
    spdf_win_sb joined;
    spdf_win_sb cleaned;
    char* text;
    const char* p;
    long chars;
    size_t i;

    if (!body || !*body) {
        char* empty = (char*)malloc(1);
        if (empty) empty[0] = '\0';
        return empty;
    }
    copy = concat(body, "");
    if (!copy) return NULL;

    for (line = copy; line; line = next) {
        const char* raw = line;
        char* work;
        char* s;
        int is_bullet = 0;
        int continuation;
        spdf_win_sb sb;
        const char* markers[3];
        int m;

        next = strchr(line, '\n');
        if (next) {
            *next = '\0';
            if (next > line && next[-1] == '\r') next[-1] = '\0'; /* \r\n */
            next++;
        }

        work = concat(line, "");
        if (!work) break;
        s = strip(work);
        /* Highlights only: stop at the first horizontal rule. */
        if (starts_with(s, "---") || starts_with(s, "***") || starts_with(s, "___")) {
            free(work);
            break;
        }
        while (*s == '#') s++;
        if (starts_with(s, "> ")) s += 2;
        s = strip(s);
        spdf_win_sb_init(&sb);
        if (starts_with(s, "- ") || starts_with(s, "* ") || starts_with(s, "+ ")) {
            spdf_win_sb_append(&sb, "\xE2\x80\xA2 "); /* U+2022 BULLET */
            spdf_win_sb_append(&sb, s + 2);
            is_bullet = 1;
        } else {
            spdf_win_sb_append(&sb, s);
        }
        free(work);
        work = spdf_win_sb_finish(&sb);
        if (!work) break;
        markers[0] = "**";
        markers[1] = "`";
        markers[2] = "_";
        for (m = 0; m < 3; ++m) {
            spdf_win_sb_init(&sb);
            remove_marker(&sb, work, markers[m]);
            free(work);
            work = spdf_win_sb_finish(&sb);
            if (!work) break;
        }
        if (!work) break;
        /* A hard-wrapped continuation (indented in the raw body) rejoins the
         * previous line so the prompt wraps it naturally. */
        continuation = !is_bullet && *work && starts_with(raw, "  ") && nlines > 0 && *lines[nlines - 1];
        if (continuation) {
            spdf_win_sb_init(&sb);
            spdf_win_sb_append(&sb, lines[nlines - 1]);
            spdf_win_sb_append_c(&sb, ' ');
            spdf_win_sb_append(&sb, work);
            free(lines[nlines - 1]);
            free(work);
            lines[nlines - 1] = spdf_win_sb_finish(&sb);
            if (!lines[nlines - 1]) break;
        } else if (*work) {
            if (nlines == cap) {
                size_t want = cap ? cap * 2 : 16;
                char** grown = (char**)realloc(lines, want * sizeof(*lines));
                if (!grown) {
                    free(work);
                    break;
                }
                lines = grown;
                cap = want;
            }
            lines[nlines++] = work;
        } else {
            free(work); /* blank lines add nothing in the compact prompt */
        }
    }
    free(copy);

    spdf_win_sb_init(&joined);
    for (i = 0; i < nlines; ++i) {
        if (i) spdf_win_sb_append_c(&joined, '\n');
        spdf_win_sb_append(&joined, lines[i]);
        free(lines[i]);
    }
    free(lines);
    text = spdf_win_sb_finish(&joined);
    if (!text) return NULL;

    /* Neutralise control and bidi override characters so a crafted body cannot
     * reorder or hide the version text in the prompt. */
    spdf_win_sb_init(&cleaned);
    for (p = text; *p;) {
        unsigned u;
        int n = utf8_next(p, &u);
        if (!n) break;
        if (u != '\n') {
            if (u < 0x20 || u == 0x7F) { p += n; continue; }
            if (u >= 0x202A && u <= 0x202E) { p += n; continue; } /* embeddings/overrides */
            if (u >= 0x2066 && u <= 0x2069) { p += n; continue; } /* isolates */
        }
        spdf_win_sb_append_n(&cleaned, p, (size_t)n);
        p += n;
    }
    free(text);
    text = spdf_win_sb_finish(&cleaned);
    if (!text) return NULL;
    {
        char* stripped = strip(text);
        if (stripped != text) memmove(text, stripped, strlen(stripped) + 1);
    }

    /* Cap at 500 characters (code points, not bytes) on a line boundary. */
    chars = 0;
    for (p = text; *p;) {
        unsigned u;
        int n = utf8_next(p, &u);
        if (!n) break;
        if (++chars > SPDF_WIN_UPDATER_NOTES_CHAR_CAP) {
            const char* cut = p;
            const char* q;
            char* trimmed;
            char* result;
            for (q = p; q > text; --q) {
                if (*q == '\n') {
                    cut = q;
                    break;
                }
            }
            trimmed = (char*)malloc((size_t)(cut - text) + 1);
            if (!trimmed) {
                free(text);
                return NULL;
            }
            memcpy(trimmed, text, (size_t)(cut - text));
            trimmed[cut - text] = '\0';
            result = concat(strip(trimmed), "\n\xE2\x80\xA6"); /* "\n…" */
            free(trimmed);
            free(text);
            return result;
        }
        p += n;
    }
    return text;
}

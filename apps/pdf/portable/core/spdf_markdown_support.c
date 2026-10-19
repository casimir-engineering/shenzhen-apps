/* spdf_markdown_support.c -- the byte buffer, escaping, heading slugs, the two
 * palettes and the stylesheet they fill, and the document wrapper.
 *
 * THE STYLESHEET IS ONE TEMPLATE, TWO PALETTES. Every colour in it is a `$role`
 * token substituted from the table below; nothing else varies between the
 * light and the dark rendition. That is the whole guarantee behind the core's
 * dark_doc: MuPDF lays both out and gets the same page breaks because the
 * geometry-bearing declarations are byte-identical. SPDFCoreMarkdownTests
 * asserts it by diffing the two outputs and checking every difference is a
 * hex colour.
 *
 * The palette values are the ones portable/mac/markdown/SPDFMarkdownTheme.mm
 * paints with (GitHub-Primer light, Obsidian-default dark), so a Windows page
 * and a Mac page agree on every role even though they are laid out by
 * different engines. The dark paper #1E1E1E and ink #DCDDDE are also
 * spdf_recolor_default_dark_theme()'s endpoints, which is what lets a dark
 * Markdown page sit beside a recoloured dark PDF page without a seam.
 */
#include "spdf_markdown.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* --- buffer ---------------------------------------------------------------- */

void spdf_md_buf_init(spdf_md_buf* b) {
    memset(b, 0, sizeof(*b));
}

void spdf_md_buf_free(spdf_md_buf* b) {
    free(b->data);
    memset(b, 0, sizeof(*b));
}

static int buf_reserve(spdf_md_buf* b, size_t extra) {
    size_t need;
    size_t cap;
    char* grown;

    if (b->failed) return 0;
    need = b->len + extra + 1;
    if (need <= b->cap) return 1;
    cap = b->cap ? b->cap : 1024;
    while (cap < need) cap *= 2;
    grown = (char*)realloc(b->data, cap);
    if (!grown) {
        b->failed = 1;
        return 0;
    }
    b->data = grown;
    b->cap = cap;
    return 1;
}

void spdf_md_buf_append(spdf_md_buf* b, const char* text, size_t n) {
    if (!n || !buf_reserve(b, n)) return;
    memcpy(b->data + b->len, text, n);
    b->len += n;
}

void spdf_md_buf_puts(spdf_md_buf* b, const char* text) {
    spdf_md_buf_append(b, text, strlen(text));
}

void spdf_md_buf_putc(spdf_md_buf* b, char c) {
    spdf_md_buf_append(b, &c, 1);
}

void spdf_md_buf_escape(spdf_md_buf* b, const char* text, size_t n) {
    size_t i;
    size_t run = 0;

    for (i = 0; i < n; ++i) {
        const char* rep = NULL;
        switch (text[i]) {
            case '&': rep = "&amp;"; break;
            case '<': rep = "&lt;"; break;
            case '>': rep = "&gt;"; break;
            case '"': rep = "&quot;"; break;
            default: break;
        }
        if (!rep) continue;
        spdf_md_buf_append(b, text + run, i - run);
        spdf_md_buf_puts(b, rep);
        run = i + 1;
    }
    spdf_md_buf_append(b, text + run, n - run);
}

char* spdf_md_buf_detach(spdf_md_buf* b) {
    char* out;

    if (b->failed || !buf_reserve(b, 0)) {
        spdf_md_buf_free(b);
        return NULL;
    }
    b->data[b->len] = '\0';
    out = b->data;
    memset(b, 0, sizeof(*b));
    return out;
}

/* --- tokens ------------------------------------------------------------------ */

void spdf_md_tokens_add(spdf_md_tokens* t, size_t start, size_t end, char kind) {
    if (end <= start || t->failed) return;
    if (t->count == t->cap) {
        size_t cap = t->cap ? t->cap * 2 : 64;
        spdf_md_token* grown = (spdf_md_token*)realloc(t->items, cap * sizeof(*grown));
        if (!grown) {
            t->failed = 1;
            return;
        }
        t->items = grown;
        t->cap = cap;
    }
    t->items[t->count].start = start;
    t->items[t->count].end = end;
    t->items[t->count].kind = kind;
    ++t->count;
}

void spdf_md_tokens_free(spdf_md_tokens* t) {
    free(t->items);
    memset(t, 0, sizeof(*t));
}

void spdf_md_buf_attr(spdf_md_buf* b, const char* name, const char* value) {
    if (!value || !*value) return;
    spdf_md_buf_putc(b, ' ');
    spdf_md_buf_puts(b, name);
    spdf_md_buf_puts(b, "=\"");
    spdf_md_buf_escape(b, value, strlen(value));
    spdf_md_buf_putc(b, '"');
}

/* --- slugs and paths ------------------------------------------------------- */

void spdf_markdown_slug(const char* text, size_t len, char* out, size_t cap) {
    size_t i;
    size_t o = 0;

    if (!cap) return;
    for (i = 0; i < len && o + 1 < cap; ++i) {
        unsigned char c = (unsigned char)text[i];
        if (c >= 0x80 || isalnum(c) || c == '-' || c == '_') {
            out[o++] = (char)tolower(c);
        } else if (c == ' ' || c == '\t') {
            out[o++] = '-';
        }
        /* GitHub drops every other punctuation mark. */
    }
    out[o] = '\0';
}

void spdf_markdown_unique_slug(spdf_md_buf* used, const char* text, size_t len, char* out, size_t cap) {
    char slug[256];
    int suffix = 0;

    spdf_markdown_slug(text, len, slug, sizeof(slug));
    if (!slug[0]) strcpy(slug, "section");
    /* GitHub appends -1, -2... to a repeated heading. The used list is
     * "\nslug\nslug\n", so a whole-entry match is one scan. */
    for (;;) {
        size_t n;
        const char* p = used->data;
        const char* end = p ? p + used->len : NULL;
        int taken = 0;
        if (suffix == 0) snprintf(out, cap, "%s", slug);
        else snprintf(out, cap, "%s-%d", slug, suffix);
        n = strlen(out);
        while (p && p + n + 2 <= end) {
            if (p[0] == '\n' && memcmp(p + 1, out, n) == 0 && p[n + 1] == '\n') {
                taken = 1;
                break;
            }
            ++p;
        }
        if (!taken) break;
        ++suffix;
    }
    if (!used->len) spdf_md_buf_putc(used, '\n');
    spdf_md_buf_puts(used, out);
    spdf_md_buf_putc(used, '\n');
}

/* Obsidian YAML front matter: a leading "---" block, skipped whole. An
 * unterminated block is content, not front matter. */
size_t spdf_markdown_front_matter_length(const char* md, size_t len) {
    size_t i = 3;
    if (len < 4 || memcmp(md, "---", 3) != 0 || (md[3] != '\n' && md[3] != '\r')) return 0;
    while (i < len) {
        size_t line = i;
        while (line < len && md[line] != '\n') ++line;
        if (i > 3 && line - i >= 3 && memcmp(md + i, "---", 3) == 0 &&
            (line - i == 3 || (line - i == 4 && md[i + 3] == '\r')))
            return line < len ? line + 1 : len;
        i = line + 1;
    }
    return 0;
}

static int equals_fold(const char* a, size_t n, const char* b) {
    size_t i;
    if (strlen(b) != n) return 0;
    for (i = 0; i < n; ++i)
        if (tolower((unsigned char)a[i]) != (unsigned char)b[i]) return 0;
    return 1;
}

int spdf_path_is_markdown(const char* path) {
    size_t n;
    const char* dot;

    if (!path) return 0;
    n = strlen(path);
    dot = path + n;
    while (dot > path && dot[-1] != '.' && dot[-1] != '/' && dot[-1] != '\\') --dot;
    if (dot == path || dot[-1] != '.') return 0;
    return equals_fold(dot, strlen(dot), "md") || equals_fold(dot, strlen(dot), "markdown");
}

/* --- source policy ----------------------------------------------------------- */

static int starts_fold(const char* s, size_t n, const char* prefix) {
    size_t m = strlen(prefix);
    return n >= m && equals_fold(s, m, prefix);
}

/* "scheme:" before any '/', '#' or '?' -- the length of the scheme, or 0. */
static size_t scheme_len(const char* s, size_t n) {
    size_t i;
    for (i = 0; i < n; ++i) {
        char c = s[i];
        if (c == ':') return i;
        if (c == '/' || c == '#' || c == '?' || c == '\\') return 0;
        if (!isalnum((unsigned char)c) && c != '+' && c != '-' && c != '.') return 0;
    }
    return 0;
}

static int has_parent_segment(const char* s, size_t n) {
    size_t i = 0;
    while (i < n) {
        size_t j = i;
        while (j < n && s[j] != '/' && s[j] != '\\') ++j;
        if (j - i == 2 && s[i] == '.' && s[i + 1] == '.') return 1;
        i = j + 1;
    }
    return 0;
}

int spdf_markdown_href_allowed(const char* href, size_t len) {
    size_t n = scheme_len(href, len);
    if (!n) return 1; /* relative path or #anchor */
    return equals_fold(href, n, "http") || equals_fold(href, n, "https") || equals_fold(href, n, "mailto");
}

/* A cache file name is a BARE name inside the mounted directory: no separator,
 * no parent segment, and it has to fit under the mount prefix. */
static int mount_cache_name(const char* name, char* out, size_t cap) {
    size_t i;
    if (!name || !name[0]) return 0;
    for (i = 0; name[i]; ++i)
        if (name[i] == '/' || name[i] == '\\') return 0;
    if (has_parent_segment(name, strlen(name))) return 0;
    if (strlen(SPDF_MARKDOWN_REMOTE_MOUNT) + 1 + strlen(name) + 1 > cap) return 0;
    strcpy(out, SPDF_MARKDOWN_REMOTE_MOUNT "/");
    strcat(out, name);
    return 1;
}

/* The extensions MuPDF has no decoder for but a frontend may be able to
 * transcode (options->local_image). Only WebP today: mupdf/source/fitz has
 * load-png/jpeg/gif/bmp/tiff/jpx/psd/pnm/jbig2/jxr and no load-webp. */
static int needs_transcode(const char* src, size_t len) {
    static const char* const k_ext[] = {".webp"};
    size_t e;
    for (e = 0; e < sizeof(k_ext) / sizeof(k_ext[0]); ++e) {
        size_t n = strlen(k_ext[e]);
        if (len > n && equals_fold(src + len - n, n, k_ext[e])) return 1;
    }
    return 0;
}

int spdf_markdown_resolve_image(const spdf_markdown_options* options, const char* src, size_t len, char* out,
                                size_t cap) {
    char name[512];

    if (!out || !cap) return 0;
    out[0] = '\0';
    while (len && isspace((unsigned char)src[0])) ++src, --len;
    while (len && isspace((unsigned char)src[len - 1])) --len;
    if (!len || len + 1 >= cap) return 0;

    if (starts_fold(src, len, "https://")) {
        char url[1024];
        if (!options || !options->remote_image || !options->remote_image_dir || len >= sizeof(url)) return 0;
        memcpy(url, src, len);
        url[len] = '\0';
        name[0] = '\0';
        if (!options->remote_image(options->remote_image_user, url, name, sizeof(name)) || !name[0]) return 0;
        return mount_cache_name(name, out, cap);
    }
    if (scheme_len(src, len)) return 0;              /* http:, data:, file:, ... */
    if (src[0] == '/' || src[0] == '\\') return 0;    /* absolute */
    if (len >= 2 && isalpha((unsigned char)src[0]) && src[1] == ':') return 0; /* drive letter */
    if (has_parent_segment(src, len)) return 0;       /* escapes the document's directory */

    /* A .webp next to the document: offer it to the transcoder before handing
     * MuPDF a file it cannot read. A refusal falls through to the plain
     * relative path, which is exactly today's behaviour. */
    if (options && options->local_image && options->remote_image_dir && options->document_dir &&
        options->document_dir[0] && needs_transcode(src, len)) {
        char abs[1280];
        size_t dir_len = strlen(options->document_dir);
        char last = options->document_dir[dir_len - 1];
        int joined = (last == '/' || last == '\\');
        if (dir_len + (joined ? 0u : 1u) + len + 1 <= sizeof(abs)) {
            memcpy(abs, options->document_dir, dir_len);
            if (!joined) abs[dir_len++] = '/';
            memcpy(abs + dir_len, src, len);
            abs[dir_len + len] = '\0';
            name[0] = '\0';
            if (options->local_image(options->local_image_user, abs, name, sizeof(name)) && name[0] &&
                mount_cache_name(name, out, cap))
                return 1;
            out[0] = '\0';
        }
    }
    memcpy(out, src, len);
    out[len] = '\0';
    return 1;
}

const char* spdf_markdown_language_override_for(const spdf_markdown_options* options, int index) {
    const char* found = NULL;
    int i;
    if (!options || !options->language_overrides || index < 0) return NULL;
    for (i = 0; i < options->language_override_count; ++i)
        if (options->language_overrides[i].fence_index == index && options->language_overrides[i].language_id &&
            options->language_overrides[i].language_id[0])
            found = options->language_overrides[i].language_id;
    return found;
}

spdf_markdown_options spdf_markdown_default_options(void) {
    spdf_markdown_options o;
    memset(&o, 0, sizeof(o));
    o.text_scale = 1.0f;
    o.dark_rendition = 1;
    return o;
}

/* --- palettes ---------------------------------------------------------------- */

typedef struct palette_role {
    const char* token;
    const char* light;
    const char* dark;
} palette_role;

/* Longer tokens first where one is a prefix of another ($codestroke before
 * $code would otherwise be needed; none collide today, but the rule stands). */
static const palette_role k_palette[] = {
    {"$paper", "#FFFFFF", "#1E1E1E"},      {"$text", "#1F2328", "#DCDDDE"},   {"$muted", "#59636E", "#999999"},
    {"$link", "#0969DA", "#7F6DF2"},       {"$chip", "#EFF1F2", "#2A2A2A"},   {"$codebox", "#F6F8FA", "#262626"},
    {"$codestroke", "#D0D7DE", "#363636"}, {"$rule", "#D1D9E0", "#333333"},   {"$thead", "#EAEEF2", "#262626"},
    {"$stripe", "#FAFBFC", "#232323"},     {"$hcomment", "#59636E", "#7F848E"}, {"$hstring", "#0A3069", "#98C379"},
    {"$hnumber", "#0550AE", "#D19A66"},    {"$hkey", "#953800", "#E5C07B"},   {"$hmarkup", "#8250DF", "#61AFEF"},
    {"$hkeyword", "#CF222E", "#C678DD"},
};

/* Word-like margins on A4: 60pt top and bottom, 61pt left and right, a 473pt
 * column -- the figure width the Mac's paginator offers (markdown/README.md).
 * Sizes are in em so fz_layout_document's em (the A-/A+ text size) scales
 * everything but the paper and its margins. */
static const char* const k_stylesheet =
    "@page{margin:60pt 61pt}\n"
    "html{background-color:$paper}\n"
    "body{font-family:sans-serif;color:$text;line-height:1.5;margin:0}\n"
    "h1,h2,h3,h4,h5,h6{font-weight:bold;page-break-after:avoid;margin:1em 0 0.6em}\n"
    "h1{font-size:2em;padding-bottom:0.3em;border-bottom:1px solid $rule;margin-top:0.8em}\n"
    "h2{font-size:1.5em;padding-bottom:0.3em;border-bottom:1px solid $rule}\n"
    "h3{font-size:1.25em}\n"
    ".h4,.h5,.h6{font-weight:bold;margin:1em 0 0.5em;page-break-after:avoid}\n"
    ".h4{font-size:1em}\n.h5{font-size:0.875em}\n.h6{font-size:0.85em;color:$muted}\n"
    "p{margin:0 0 1em}\n"
    "a{color:$link;text-decoration:underline}\n"
    "blockquote{margin:0 0 1em;padding:0 1em;color:$muted;border-left:4px solid $rule}\n"
    "blockquote p{margin-bottom:0.5em}\n"
    "code,kbd,pre{font-family:monospace}\n"
    "code{font-size:0.85em;background-color:$chip;padding:0.15em 0.3em}\n"
    "pre{background-color:$codebox;border:1px solid $codestroke;padding:12pt;margin:0 0 1em;"
    "white-space:pre-wrap;overflow-wrap:break-word;font-size:0.85em;line-height:1.45}\n"
    "pre code{background-color:$codebox;padding:0;font-size:1em}\n"
    "table{border-collapse:collapse;margin:0 0 1em}\n"
    "th,td{border:1px solid $rule;padding:5pt 12pt;text-align:left;vertical-align:top}\n"
    "th{background-color:$thead;font-weight:bold}\n"
    "tbody tr:nth-child(even) td{background-color:$stripe}\n"
    ".ac{text-align:center}\n.ar{text-align:right}\n.al{text-align:left}\n"
    "hr{border:0;border-top:2px solid $rule;margin:1.5em 0}\n"
    "kbd{font-size:0.85em;background-color:$chip;border:1px solid $codestroke;padding:0.1em 0.4em}\n"
    "ul,ol{margin:0 0 1em;padding-left:2em}\n"
    "li{margin:0.15em 0}\n"
    "li.task{list-style-type:none}\n"
    "figure{margin:0 0 1em;text-align:center}\n"
    "figcaption{color:$muted;font-size:0.9em}\n"
    "del{text-decoration:line-through}\n"
    ".details{margin:0 0 1em}\n.summary{font-weight:bold;margin:0 0 0.5em}\n"
    ".wikilink{color:$link}\n"
    ".callout{font-weight:bold;color:$text}\n"
    ".mdisplay{display:block;text-align:center;font-size:1.15em;margin:0.6em 0}\n"
    ".img-missing{color:$muted;font-style:italic}\n"
    "sub,sup{font-size:0.75em}\n"
    ".hk{color:$hkeyword}\n.hs{color:$hstring}\n.hn{color:$hnumber}\n.hc{color:$hcomment}\n"
    ".hy{color:$hkey}\n.hm{color:$hmarkup}\n";

char* spdf_markdown_stylesheet(int dark) {
    spdf_md_buf out;
    const char* p = k_stylesheet;

    spdf_md_buf_init(&out);
    while (*p) {
        size_t i;
        if (*p != '$') {
            spdf_md_buf_putc(&out, *p++);
            continue;
        }
        for (i = 0; i < sizeof(k_palette) / sizeof(k_palette[0]); ++i) {
            size_t n = strlen(k_palette[i].token);
            if (strncmp(p, k_palette[i].token, n) == 0 && !isalnum((unsigned char)p[n])) {
                spdf_md_buf_puts(&out, dark ? k_palette[i].dark : k_palette[i].light);
                p += n;
                break;
            }
        }
        if (i == sizeof(k_palette) / sizeof(k_palette[0])) spdf_md_buf_putc(&out, *p++); /* unknown: literal */
    }
    return spdf_md_buf_detach(&out);
}

char* spdf_markdown_document_html(const char* body, int dark) {
    spdf_md_buf out;
    char* css = spdf_markdown_stylesheet(dark);

    if (!css) return NULL;
    spdf_md_buf_init(&out);
    spdf_md_buf_puts(&out, "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><style>\n");
    spdf_md_buf_puts(&out, css);
    spdf_md_buf_puts(&out, "</style></head><body>\n");
    spdf_md_buf_puts(&out, body ? body : "");
    spdf_md_buf_puts(&out, "\n</body></html>\n");
    free(css);
    return spdf_md_buf_detach(&out);
}

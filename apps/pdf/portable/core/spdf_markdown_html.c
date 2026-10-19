/* spdf_markdown_html.c -- README HTML through a strict whitelist.
 *
 * The inline HTML real READMEs lean on (centered <div align> blocks, badge
 * images sized by width/height, <kbd>, <sub>/<sup>, <details>, simple
 * tables) is rewritten tag by tag into the same HTML the converter emits for
 * Markdown, and everything else is removed. Nothing is ever evaluated: there
 * is no script engine anywhere in the reader, so "stripping" here is about the
 * DOCUMENT -- a <script> block must not appear as visible text, an iframe must
 * not become a hole, an event handler must not survive as an attribute MuPDF
 * would faithfully ignore but a later engine might not.
 *
 * WHY A TOKENISER AND NOT A TREE. md4c hands raw HTML over in fragments -- one
 * tag for an inline island, one line-run for a block -- and the GitHub
 * container pattern (<div align="center"> ... markdown ... </div>) puts the
 * opening and closing tags in DIFFERENT fragments with Markdown between them.
 * A tree parser per fragment would see unbalanced input every time; a tag
 * tokeniser passes the balanced structure straight through, and MuPDF's HTML5
 * parser downstream tolerates whatever imbalance an author wrote, exactly as
 * a browser does. The vendored Gumbo parser (ext/gumbo-parser, 33k lines)
 * stays available if a construct ever needs real tree semantics; nothing in
 * the README whitelist does.
 *
 * Three verdicts per element:
 *   KEEP     -- re-emitted with only the whitelisted attributes, possibly
 *               renamed (<center> -> <div class="ac">, <details> -> a div).
 *   DROP     -- the tag disappears, its children flow (span, font, picture).
 *   SWALLOW  -- the element and everything up to its close tag disappear
 *               (script, style, iframe, form controls, media, svg, math).
 *               The swallow persists across fragments (spdf_md_sanitizer).
 */
#include "spdf_markdown.h"

#include <ctype.h>
#include <string.h>

typedef struct attr {
    const char* name;
    size_t name_len;
    const char* value;
    size_t value_len;
} attr;

#define MAX_ATTRS 12

static int name_is(const char* name, size_t len, const char* want) {
    size_t i;
    if (strlen(want) != len) return 0;
    for (i = 0; i < len; ++i)
        if (tolower((unsigned char)name[i]) != want[i]) return 0;
    return 1;
}

static int name_in(const char* name, size_t len, const char* const* list) {
    for (; *list; ++list)
        if (name_is(name, len, *list)) return 1;
    return 0;
}

static const char* const k_swallow[] = {"script", "style", "iframe", "object", "embed", "form", "input",
                                        "select", "textarea", "button", "video", "audio", "svg", "math",
                                        "canvas", "link", "meta", "template", "noscript", "head", "title",
                                        "base", "frame", "frameset", "applet", "source", "track", NULL};
static const char* const k_void[] = {"br", "hr", "img", "input", "meta", "link", "source", "wbr", "track", NULL};
/* Kept under their own name, no attributes. */
static const char* const k_plain[] = {"b", "strong", "i", "em", "u", "ins", "code", "kbd", "sub", "sup",
                                      "br", "small", "abbr", "cite", "q", "dfn", "var", "del", "blockquote",
                                      "ul", "li", "pre", "hr", "table", "thead", "tbody", "tfoot", "tr",
                                      "caption", "dl", "dt", "dd", "figure", "figcaption", "span", NULL};
/* Block containers that take align (and headings, which also keep an id). */
static const char* const k_aligned[] = {"p", "div", "h1", "h2", "h3", "h4", "h5", "h6", NULL};

static const attr* find_attr(const attr* attrs, int count, const char* name) {
    int i;
    for (i = 0; i < count; ++i)
        if (name_is(attrs[i].name, attrs[i].name_len, name)) return &attrs[i];
    return NULL;
}

/* An attribute value is already HTML: entities stay, only the quote and a
 * stray angle bracket are re-escaped. */
static void put_attr(spdf_md_buf* out, const char* name, const char* value, size_t len) {
    size_t i;
    spdf_md_buf_putc(out, ' ');
    spdf_md_buf_puts(out, name);
    spdf_md_buf_puts(out, "=\"");
    for (i = 0; i < len; ++i) {
        if (value[i] == '"') spdf_md_buf_puts(out, "&quot;");
        else if (value[i] == '<') spdf_md_buf_puts(out, "&lt;");
        else spdf_md_buf_putc(out, value[i]);
    }
    spdf_md_buf_putc(out, '"');
}

static int all_digits(const char* s, size_t n) {
    size_t i;
    if (!n || n > 5) return 0;
    for (i = 0; i < n; ++i)
        if (!isdigit((unsigned char)s[i])) return 0;
    return 1;
}

static void put_align_class(spdf_md_buf* out, const attr* a) {
    if (!a) return;
    if (name_is(a->value, a->value_len, "center")) spdf_md_buf_puts(out, " class=\"ac\"");
    else if (name_is(a->value, a->value_len, "right")) spdf_md_buf_puts(out, " class=\"ar\"");
    else if (name_is(a->value, a->value_len, "left")) spdf_md_buf_puts(out, " class=\"al\"");
}

static void put_id(spdf_md_buf* out, const attr* a) {
    size_t i;
    if (!a || !a->value_len) return;
    spdf_md_buf_puts(out, " id=\"");
    for (i = 0; i < a->value_len; ++i) {
        unsigned char c = (unsigned char)a->value[i];
        if (isalnum(c) || c == '-' || c == '_') spdf_md_buf_putc(out, (char)c);
    }
    spdf_md_buf_putc(out, '"');
}

static void emit_img(spdf_md_sanitizer* s, spdf_md_buf* out, const attr* attrs, int count) {
    const attr* src = find_attr(attrs, count, "src");
    const attr* alt = find_attr(attrs, count, "alt");
    const attr* title = find_attr(attrs, count, "title");
    const attr* w = find_attr(attrs, count, "width");
    const attr* h = find_attr(attrs, count, "height");
    char resolved[1024];

    if (src && spdf_markdown_resolve_image(s->options, src->value, src->value_len, resolved, sizeof(resolved))) {
        spdf_md_buf_puts(out, "<img");
        put_attr(out, "src", resolved, strlen(resolved));
        if (alt) put_attr(out, "alt", alt->value, alt->value_len);
        if (title) put_attr(out, "title", title->value, title->value_len);
        if (w && all_digits(w->value, w->value_len)) put_attr(out, "width", w->value, w->value_len);
        if (h && all_digits(h->value, h->value_len)) put_attr(out, "height", h->value, h->value_len);
        spdf_md_buf_putc(out, '>');
        return;
    }
    spdf_md_buf_puts(out, "<span class=\"img-missing\">[Image: ");
    if (alt) spdf_md_buf_append(out, alt->value, alt->value_len);
    spdf_md_buf_puts(out, "]</span>");
}

static void emit_tag(spdf_md_sanitizer* s, spdf_md_buf* out, const char* name, size_t len, int closing,
                     const attr* attrs, int count) {
    const char* slash = closing ? "</" : "<";

    if (name_in(name, len, k_plain)) {
        spdf_md_buf_puts(out, slash);
        if (name_is(name, len, "u") || name_is(name, len, "ins")) spdf_md_buf_puts(out, "u");
        else spdf_md_buf_append(out, name, len);
        spdf_md_buf_putc(out, '>');
        return;
    }
    if (name_is(name, len, "tt") || name_is(name, len, "samp")) {
        spdf_md_buf_puts(out, slash);
        spdf_md_buf_puts(out, "code>");
        return;
    }
    if (name_is(name, len, "s") || name_is(name, len, "strike")) {
        spdf_md_buf_puts(out, slash);
        spdf_md_buf_puts(out, "del>");
        return;
    }
    if (name_is(name, len, "mark")) {
        spdf_md_buf_puts(out, slash);
        spdf_md_buf_puts(out, "b>");
        return;
    }
    if (name_is(name, len, "img")) {
        if (!closing) emit_img(s, out, attrs, count);
        return;
    }
    if (name_is(name, len, "a")) {
        const attr* href = find_attr(attrs, count, "href");
        const attr* title = find_attr(attrs, count, "title");
        if (closing) {
            spdf_md_buf_puts(out, "</a>");
            return;
        }
        spdf_md_buf_puts(out, "<a");
        if (href && spdf_markdown_href_allowed(href->value, href->value_len))
            put_attr(out, "href", href->value, href->value_len);
        if (title) put_attr(out, "title", title->value, title->value_len);
        spdf_md_buf_putc(out, '>');
        return;
    }
    if (name_in(name, len, k_aligned)) {
        spdf_md_buf_puts(out, slash);
        spdf_md_buf_append(out, name, len);
        if (!closing) {
            put_id(out, find_attr(attrs, count, "id"));
            put_align_class(out, find_attr(attrs, count, "align"));
        }
        spdf_md_buf_putc(out, '>');
        return;
    }
    if (name_is(name, len, "center")) {
        spdf_md_buf_puts(out, closing ? "</div>" : "<div class=\"ac\">");
        return;
    }
    if (name_is(name, len, "details")) {
        spdf_md_buf_puts(out, closing ? "</div>" : "<div class=\"details\">");
        return;
    }
    if (name_is(name, len, "summary")) {
        /* Always expanded, behind a bold disclosure line -- collapsing is the
         * documented limitation, as on macOS. */
        spdf_md_buf_puts(out, closing ? "</div>" : "<div class=\"summary\">\xE2\x96\xB8 ");
        return;
    }
    if (name_is(name, len, "th") || name_is(name, len, "td")) {
        const attr* span;
        spdf_md_buf_puts(out, slash);
        spdf_md_buf_append(out, name, len);
        if (!closing) {
            put_align_class(out, find_attr(attrs, count, "align"));
            span = find_attr(attrs, count, "colspan");
            if (span && all_digits(span->value, span->value_len)) put_attr(out, "colspan", span->value, span->value_len);
            span = find_attr(attrs, count, "rowspan");
            if (span && all_digits(span->value, span->value_len)) put_attr(out, "rowspan", span->value, span->value_len);
        }
        spdf_md_buf_putc(out, '>');
        return;
    }
    if (name_is(name, len, "ol")) {
        const attr* start = find_attr(attrs, count, "start");
        spdf_md_buf_puts(out, slash);
        spdf_md_buf_puts(out, "ol");
        if (!closing && start && all_digits(start->value, start->value_len))
            put_attr(out, "start", start->value, start->value_len);
        spdf_md_buf_putc(out, '>');
        return;
    }
    if (name_is(name, len, "section") || name_is(name, len, "article") || name_is(name, len, "header") ||
        name_is(name, len, "footer") || name_is(name, len, "main") || name_is(name, len, "nav") ||
        name_is(name, len, "aside")) {
        spdf_md_buf_puts(out, closing ? "</div>" : "<div>");
        return;
    }
    /* Unknown or harmless-but-unstyled (font, picture, big, wbr...): the tag
     * goes, its children stay. */
}

/* Parse one tag starting at html[i] == '<'. Returns the index after '>' (or
 * len when unterminated) and fills the pieces; *name_len == 0 means "not a
 * tag" and the caller emits a literal '<'. */
static size_t parse_tag(const char* html, size_t len, size_t i, const char** name, size_t* name_len, int* closing,
                        int* self_closing, attr* attrs, int* attr_count) {
    size_t j = i + 1;

    *closing = 0;
    *self_closing = 0;
    *attr_count = 0;
    *name_len = 0;
    if (j < len && html[j] == '/') {
        *closing = 1;
        ++j;
    }
    *name = html + j;
    while (j < len && (isalnum((unsigned char)html[j]))) ++j;
    *name_len = (size_t)(html + j - *name);
    if (!*name_len) return i + 1;

    while (j < len && html[j] != '>') {
        attr a;
        while (j < len && (isspace((unsigned char)html[j]) || html[j] == '/')) {
            if (html[j] == '/' && j + 1 < len && html[j + 1] == '>') *self_closing = 1;
            ++j;
        }
        if (j >= len || html[j] == '>') break;
        a.name = html + j;
        while (j < len && !isspace((unsigned char)html[j]) && html[j] != '=' && html[j] != '>' && html[j] != '/') ++j;
        a.name_len = (size_t)(html + j - a.name);
        a.value = html + j;
        a.value_len = 0;
        while (j < len && isspace((unsigned char)html[j])) ++j;
        if (j < len && html[j] == '=') {
            ++j;
            while (j < len && isspace((unsigned char)html[j])) ++j;
            if (j < len && (html[j] == '"' || html[j] == '\'')) {
                char q = html[j++];
                a.value = html + j;
                while (j < len && html[j] != q) ++j;
                a.value_len = (size_t)(html + j - a.value);
                if (j < len) ++j;
            } else {
                a.value = html + j;
                while (j < len && !isspace((unsigned char)html[j]) && html[j] != '>') ++j;
                a.value_len = (size_t)(html + j - a.value);
            }
        }
        if (a.name_len && *attr_count < MAX_ATTRS) attrs[(*attr_count)++] = a;
    }
    return j < len ? j + 1 : len;
}

void spdf_md_sanitizer_init(spdf_md_sanitizer* s, const spdf_markdown_options* options) {
    memset(s, 0, sizeof(*s));
    s->options = options;
}

void spdf_md_sanitize(spdf_md_sanitizer* s, const char* html, size_t len, spdf_md_buf* out) {
    size_t i = 0;

    while (i < len) {
        const char* name;
        size_t name_len;
        int closing, self_closing, count;
        attr attrs[MAX_ATTRS];
        size_t next;

        if (s->skip_tag[0]) {
            /* Inside a swallowed element: only its own close tag gets us out. */
            size_t tag_len = strlen(s->skip_tag);
            if (html[i] == '<' && i + 2 + tag_len <= len && html[i + 1] == '/' &&
                name_is(html + i + 2, tag_len, s->skip_tag)) {
                while (i < len && html[i] != '>') ++i;
                if (i < len) ++i;
                s->skip_tag[0] = '\0';
            } else {
                ++i;
            }
            continue;
        }
        if (html[i] != '<') {
            size_t run = i;
            while (i < len && html[i] != '<') ++i;
            spdf_md_buf_append(out, html + run, i - run);
            continue;
        }
        if (i + 4 <= len && memcmp(html + i, "<!--", 4) == 0) {
            const char* end = NULL;
            size_t k;
            for (k = i + 4; k + 3 <= len; ++k)
                if (memcmp(html + k, "-->", 3) == 0) {
                    end = html + k + 3;
                    break;
                }
            i = end ? (size_t)(end - html) : len;
            continue;
        }
        if (i + 1 < len && (html[i + 1] == '!' || html[i + 1] == '?')) {
            while (i < len && html[i] != '>') ++i;
            if (i < len) ++i;
            continue;
        }
        next = parse_tag(html, len, i, &name, &name_len, &closing, &self_closing, attrs, &count);
        if (!name_len) {
            spdf_md_buf_puts(out, "&lt;");
            i = next;
            continue;
        }
        if (name_in(name, name_len, k_swallow)) {
            if (!closing && !self_closing && !name_in(name, name_len, k_void) && name_len < sizeof(s->skip_tag)) {
                size_t k;
                for (k = 0; k < name_len; ++k) s->skip_tag[k] = (char)tolower((unsigned char)name[k]);
                s->skip_tag[name_len] = '\0';
            }
        } else {
            emit_tag(s, out, name, name_len, closing, attrs, count);
        }
        i = next;
    }
}

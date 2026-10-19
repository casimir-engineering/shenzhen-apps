/* spdf_markdown.c -- Markdown to the HTML body, through md4c's SAX callbacks.
 *
 * md4c (ext/md4c, 0.5.3, GitHub dialect + LaTeX math spans + wikilinks) walks
 * the document and calls back per block, span and text run; this file turns
 * each callback into the HTML the stylesheet in spdf_markdown_support.c
 * styles. Most output goes straight to the body buffer. A few constructs need
 * to see their whole content before deciding what to emit, and for those a
 * CAPTURE STACK redirects the text callbacks into a side buffer until the
 * block or span closes:
 *
 *   heading    -> its inner HTML plus its plain text, so the GitHub-style
 *                 anchor id (slug) can be computed for the outline and for
 *                 #links, then <hN id=...>inner</hN>.
 *   paragraph  -> so a paragraph holding nothing but images renders as a
 *                 centered <figure> with a caption line (title, else alt),
 *                 the way GitHub and the Mac reader show a standalone image
 *                 or a badge row.
 *   image      -> the alt text (a span's content in md4c) for the attribute.
 *   code block -> the whole code, so it can be tokenised as one unit.
 *   html block -> the whole block, so a tag split across lines is one tag.
 *   math span  -> the LaTeX source for the typesetter.
 *
 * Everything the body links to or loads goes through the policy functions in
 * spdf_markdown_support.c (spdf_markdown_href_allowed,
 * spdf_markdown_resolve_image); raw HTML goes through spdf_markdown_html.c.
 */
#include "spdf_markdown.h"

/* Relative on purpose: no build here adds ext/md4c to the include path, and the
 * Mac Makefile compiles md4c.c from the same relative location. */
#include "../../ext/md4c/md4c.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CAPTURE_DEPTH 16
#define LINK_DEPTH 32

typedef struct conv {
    const spdf_markdown_options* opts;
    spdf_md_buf out;
    spdf_md_buf* stack[CAPTURE_DEPTH];
    int depth;

    spdf_md_buf heading_html;
    spdf_md_buf heading_text;
    int heading_level;
    spdf_md_buf slugs; /* "\nslug\nslug\n" -- used anchors, for de-duplication */

    spdf_md_buf para;
    spdf_md_buf captions;
    int para_images;
    int para_text;

    spdf_md_buf img_alt;
    char img_src[1024];
    char img_title[512];

    spdf_md_buf code;
    char code_lang[64];
    int code_index; /* the next fence's ordinal; see close_code */

    spdf_md_buf html;
    spdf_md_sanitizer sanitizer;

    spdf_md_buf math;
    int math_display;

    int callout; /* 1: a blockquote just opened, watch for "[!TYPE]"; 2: inside the title line */
    int link_ok[LINK_DEPTH];
    int links;
    int aborted;
} conv;

static spdf_md_buf* cur(conv* c) {
    return c->stack[c->depth];
}

static void push(conv* c, spdf_md_buf* b) {
    if (c->depth + 1 >= CAPTURE_DEPTH) {
        c->aborted = 1;
        return;
    }
    b->len = 0;
    c->stack[++c->depth] = b;
}

static void pop(conv* c) {
    if (c->depth > 0) --c->depth;
}

static void attribute_text(const MD_ATTRIBUTE* a, char* out, size_t cap) {
    size_t n = a && a->text ? a->size : 0;
    if (n >= cap) n = cap - 1;
    memcpy(out, a->text, n);
    out[n] = '\0';
}

/* --- headings ------------------------------------------------------------------ */

static void close_heading(conv* c) {
    char probe[264];
    /* H1-H3 are real headings and feed MuPDF's outline, which is the chapter
     * sidebar; the Mac reader lists exactly those three levels. H4-H6 become
     * bold paragraphs that keep their anchor and their look but stay out of the
     * outline (MuPDF would otherwise list all six levels). */
    int real = c->heading_level <= 3;
    char tag[4] = {'h', (char)('0' + c->heading_level), '\0', '\0'};
    char klass[4] = {'h', (char)('0' + c->heading_level), '\0', '\0'};

    pop(c);
    spdf_markdown_unique_slug(&c->slugs, c->heading_text.data ? c->heading_text.data : "", c->heading_text.len, probe,
                              sizeof(probe));

    spdf_md_buf_putc(cur(c), '<');
    spdf_md_buf_puts(cur(c), real ? tag : "p");
    if (!real) spdf_md_buf_attr(cur(c), "class", klass);
    spdf_md_buf_attr(cur(c), "id", probe);
    spdf_md_buf_putc(cur(c), '>');
    spdf_md_buf_append(cur(c), c->heading_html.data, c->heading_html.len);
    spdf_md_buf_puts(cur(c), "</");
    spdf_md_buf_puts(cur(c), real ? tag : "p");
    spdf_md_buf_puts(cur(c), ">\n");
    c->heading_level = 0;
}

/* --- paragraphs and images ---------------------------------------------------- */

static void close_paragraph(conv* c) {
    pop(c);
    if (c->para_images > 0 && !c->para_text) {
        spdf_md_buf_puts(cur(c), "<figure>");
        spdf_md_buf_append(cur(c), c->para.data, c->para.len);
        if (c->captions.len) {
            spdf_md_buf_puts(cur(c), "<figcaption>");
            spdf_md_buf_append(cur(c), c->captions.data, c->captions.len);
            spdf_md_buf_puts(cur(c), "</figcaption>");
        }
        spdf_md_buf_puts(cur(c), "</figure>\n");
    } else {
        spdf_md_buf_puts(cur(c), "<p>");
        spdf_md_buf_append(cur(c), c->para.data, c->para.len);
        spdf_md_buf_puts(cur(c), "</p>\n");
    }
    c->callout = 0;
}

static void close_image(conv* c) {
    char resolved[1024];
    const char* caption;
    size_t caption_len;

    pop(c);
    if (spdf_markdown_resolve_image(c->opts, c->img_src, strlen(c->img_src), resolved, sizeof(resolved))) {
        spdf_md_buf_puts(cur(c), "<img");
        spdf_md_buf_attr(cur(c), "src", resolved);
        if (c->img_alt.len) {
            spdf_md_buf_puts(cur(c), " alt=\"");
            spdf_md_buf_append(cur(c), c->img_alt.data, c->img_alt.len); /* already escaped */
            spdf_md_buf_putc(cur(c), '"');
        }
        spdf_md_buf_attr(cur(c), "title", c->img_title);
        spdf_md_buf_putc(cur(c), '>');
    } else {
        spdf_md_buf_puts(cur(c), "<span class=\"img-missing\">[Image: ");
        spdf_md_buf_append(cur(c), c->img_alt.data, c->img_alt.len);
        spdf_md_buf_puts(cur(c), "]</span>");
    }
    if (cur(c) == &c->para) {
        ++c->para_images;
        caption = c->img_title[0] ? c->img_title : c->img_alt.data;
        caption_len = c->img_title[0] ? strlen(c->img_title) : c->img_alt.len;
        if (caption && caption_len) {
            if (c->captions.len) spdf_md_buf_puts(&c->captions, " \xC2\xB7 ");
            if (c->img_title[0]) spdf_md_buf_escape(&c->captions, caption, caption_len);
            else spdf_md_buf_append(&c->captions, caption, caption_len);
        }
    }
}

/* --- code ------------------------------------------------------------------------ */

static void close_code(conv* c) {
    const spdf_markdown_language* lang;
    const char* id;
    char anchor[48];
    size_t len = c->code.len;
    int index = c->code_index++;

    pop(c);
    /* md4c terminates the last line with '\n'; the box should not end with an
     * empty line. */
    if (len && c->code.data[len - 1] == '\n') --len;
    /* The anchor is how a frontend asks the laid-out document where this fence
     * ended up, for the in-page language picker and copy button: fence N is
     * "#spdf-code-N", and spdf_markdown_scan_fences numbers the same N.
     * Invisible, and MuPDF resolves it through fz_resolve_link like any id. */
    snprintf(anchor, sizeof(anchor), "%s%d", SPDF_MARKDOWN_CODE_ANCHOR_PREFIX, index);
    spdf_md_buf_puts(cur(c), "<pre");
    spdf_md_buf_attr(cur(c), "id", anchor);
    spdf_md_buf_puts(cur(c), "><code>");
    /* The picker's choice beats the fence's own info string, and beats the rule
     * below that leaves a diagram fence uncoloured; "plain" tokenises to nothing,
     * which is how Plain Text clears highlighting. */
    id = spdf_markdown_language_override_for(c->opts, index);
    if (!id) {
        lang = spdf_markdown_language_for_fence(c->code_lang, strlen(c->code_lang));
        if (lang && !spdf_markdown_is_diagram_fence(c->code_lang, strlen(c->code_lang))) id = lang->id;
    }
    if (id) spdf_markdown_highlight_html(id, c->code.data ? c->code.data : "", len, cur(c));
    else /* unknown language, and diagram fences, which stay a code box here */
        spdf_md_buf_escape(cur(c), c->code.data ? c->code.data : "", len);
    spdf_md_buf_puts(cur(c), "</code></pre>\n");
}

/* --- md4c callbacks -------------------------------------------------------------- */

static int enter_block(MD_BLOCKTYPE type, void* detail, void* user) {
    conv* c = (conv*)user;
    spdf_md_buf* b = cur(c);

    switch (type) {
        case MD_BLOCK_DOC: break;
        case MD_BLOCK_QUOTE:
            spdf_md_buf_puts(b, "<blockquote>\n");
            c->callout = 1;
            break;
        case MD_BLOCK_UL: spdf_md_buf_puts(b, "<ul>\n"); break;
        case MD_BLOCK_OL: {
            const MD_BLOCK_OL_DETAIL* d = (const MD_BLOCK_OL_DETAIL*)detail;
            char start[24];
            spdf_md_buf_puts(b, "<ol");
            if (d->start != 1) {
                snprintf(start, sizeof(start), "%u", d->start);
                spdf_md_buf_attr(b, "start", start);
            }
            spdf_md_buf_puts(b, ">\n");
            break;
        }
        case MD_BLOCK_LI: {
            const MD_BLOCK_LI_DETAIL* d = (const MD_BLOCK_LI_DETAIL*)detail;
            if (d->is_task)
                spdf_md_buf_puts(b, d->task_mark == ' ' ? "<li class=\"task\">\xE2\x98\x90 " : "<li class=\"task\">\xE2\x98\x91 ");
            else
                spdf_md_buf_puts(b, "<li>");
            break;
        }
        case MD_BLOCK_HR: spdf_md_buf_puts(b, "<hr>\n"); break;
        case MD_BLOCK_H:
            c->heading_level = (int)((const MD_BLOCK_H_DETAIL*)detail)->level;
            c->heading_text.len = 0;
            push(c, &c->heading_html);
            break;
        case MD_BLOCK_CODE:
            attribute_text(&((const MD_BLOCK_CODE_DETAIL*)detail)->lang, c->code_lang, sizeof(c->code_lang));
            push(c, &c->code);
            break;
        case MD_BLOCK_HTML: push(c, &c->html); break;
        case MD_BLOCK_P:
            c->para_images = 0;
            c->para_text = 0;
            c->captions.len = 0;
            push(c, &c->para);
            break;
        case MD_BLOCK_TABLE: spdf_md_buf_puts(b, "<table>\n"); break;
        case MD_BLOCK_THEAD: spdf_md_buf_puts(b, "<thead>\n"); break;
        case MD_BLOCK_TBODY: spdf_md_buf_puts(b, "<tbody>\n"); break;
        case MD_BLOCK_TR: spdf_md_buf_puts(b, "<tr>"); break;
        case MD_BLOCK_TH:
        case MD_BLOCK_TD: {
            MD_ALIGN align = ((const MD_BLOCK_TD_DETAIL*)detail)->align;
            spdf_md_buf_puts(b, type == MD_BLOCK_TH ? "<th" : "<td");
            if (align == MD_ALIGN_CENTER) spdf_md_buf_puts(b, " class=\"ac\"");
            else if (align == MD_ALIGN_RIGHT) spdf_md_buf_puts(b, " class=\"ar\"");
            spdf_md_buf_putc(b, '>');
            break;
        }
    }
    return c->aborted;
}

static int leave_block(MD_BLOCKTYPE type, void* detail, void* user) {
    conv* c = (conv*)user;
    (void)detail;

    switch (type) {
        case MD_BLOCK_DOC: break;
        case MD_BLOCK_QUOTE:
            spdf_md_buf_puts(cur(c), "</blockquote>\n");
            c->callout = 0;
            break;
        case MD_BLOCK_UL: spdf_md_buf_puts(cur(c), "</ul>\n"); break;
        case MD_BLOCK_OL: spdf_md_buf_puts(cur(c), "</ol>\n"); break;
        case MD_BLOCK_LI: spdf_md_buf_puts(cur(c), "</li>\n"); break;
        case MD_BLOCK_HR: break;
        case MD_BLOCK_H: close_heading(c); break;
        case MD_BLOCK_CODE: close_code(c); break;
        case MD_BLOCK_HTML:
            pop(c);
            spdf_md_sanitize(&c->sanitizer, c->html.data ? c->html.data : "", c->html.len, cur(c));
            spdf_md_buf_putc(cur(c), '\n');
            break;
        case MD_BLOCK_P: close_paragraph(c); break;
        case MD_BLOCK_TABLE: spdf_md_buf_puts(cur(c), "</table>\n"); break;
        case MD_BLOCK_THEAD: spdf_md_buf_puts(cur(c), "</thead>\n"); break;
        case MD_BLOCK_TBODY: spdf_md_buf_puts(cur(c), "</tbody>\n"); break;
        case MD_BLOCK_TR: spdf_md_buf_puts(cur(c), "</tr>\n"); break;
        case MD_BLOCK_TH: spdf_md_buf_puts(cur(c), "</th>"); break;
        case MD_BLOCK_TD: spdf_md_buf_puts(cur(c), "</td>"); break;
    }
    return c->aborted;
}

static int enter_span(MD_SPANTYPE type, void* detail, void* user) {
    conv* c = (conv*)user;
    spdf_md_buf* b = cur(c);

    if (type != MD_SPAN_A && type != MD_SPAN_IMG && b == &c->para) c->para_text = 1;
    switch (type) {
        case MD_SPAN_EM: spdf_md_buf_puts(b, "<em>"); break;
        case MD_SPAN_STRONG: spdf_md_buf_puts(b, "<strong>"); break;
        case MD_SPAN_U: spdf_md_buf_puts(b, "<u>"); break;
        case MD_SPAN_DEL: spdf_md_buf_puts(b, "<del>"); break;
        case MD_SPAN_CODE: spdf_md_buf_puts(b, "<code>"); break;
        case MD_SPAN_A: {
            const MD_SPAN_A_DETAIL* d = (const MD_SPAN_A_DETAIL*)detail;
            char href[2048];
            char title[512];
            int ok;
            attribute_text(&d->href, href, sizeof(href));
            attribute_text(&d->title, title, sizeof(title));
            ok = href[0] && spdf_markdown_href_allowed(href, strlen(href));
            if (c->links < LINK_DEPTH) c->link_ok[c->links] = ok;
            ++c->links;
            if (ok) {
                spdf_md_buf_puts(b, "<a");
                spdf_md_buf_attr(b, "href", href);
                spdf_md_buf_attr(b, "title", title);
                spdf_md_buf_putc(b, '>');
            } else {
                spdf_md_buf_puts(b, "<span>");
            }
            break;
        }
        case MD_SPAN_IMG: {
            const MD_SPAN_IMG_DETAIL* d = (const MD_SPAN_IMG_DETAIL*)detail;
            attribute_text(&d->src, c->img_src, sizeof(c->img_src));
            attribute_text(&d->title, c->img_title, sizeof(c->img_title));
            push(c, &c->img_alt);
            break;
        }
        case MD_SPAN_LATEXMATH:
        case MD_SPAN_LATEXMATH_DISPLAY:
            c->math_display = type == MD_SPAN_LATEXMATH_DISPLAY;
            push(c, &c->math);
            break;
        case MD_SPAN_WIKILINK: spdf_md_buf_puts(b, "<span class=\"wikilink\">"); break;
    }
    return c->aborted;
}

static int leave_span(MD_SPANTYPE type, void* detail, void* user) {
    conv* c = (conv*)user;
    (void)detail;

    switch (type) {
        case MD_SPAN_EM: spdf_md_buf_puts(cur(c), "</em>"); break;
        case MD_SPAN_STRONG: spdf_md_buf_puts(cur(c), "</strong>"); break;
        case MD_SPAN_U: spdf_md_buf_puts(cur(c), "</u>"); break;
        case MD_SPAN_DEL: spdf_md_buf_puts(cur(c), "</del>"); break;
        case MD_SPAN_CODE: spdf_md_buf_puts(cur(c), "</code>"); break;
        case MD_SPAN_A:
            if (c->links > 0) --c->links;
            spdf_md_buf_puts(cur(c), c->links < LINK_DEPTH && c->link_ok[c->links] ? "</a>" : "</span>");
            break;
        case MD_SPAN_IMG: close_image(c); break;
        case MD_SPAN_LATEXMATH:
        case MD_SPAN_LATEXMATH_DISPLAY:
            pop(c);
            spdf_markdown_math_html(c->math.data ? c->math.data : "", c->math.len, c->math_display, cur(c));
            break;
        case MD_SPAN_WIKILINK: spdf_md_buf_puts(cur(c), "</span>"); break;
    }
    return c->aborted;
}

/* "> [!NOTE] Title" -- Obsidian/GitHub callouts: the marker becomes a bold
 * title word (the type, title-cased) and the rest of the line stays. */
static size_t callout_marker(conv* c, const char* text, size_t n) {
    size_t i = 0, start, end;
    char type[24];
    size_t k;

    if (n < 4 || text[0] != '[' || text[1] != '!') return 0;
    start = 2;
    end = start;
    while (end < n && text[end] != ']') ++end;
    if (end >= n || end == start || end - start >= sizeof(type)) return 0;
    for (k = 0; k < end - start; ++k) type[k] = (char)(k ? tolower((unsigned char)text[start + k]) : toupper((unsigned char)text[start + k]));
    type[end - start] = '\0';
    spdf_md_buf_puts(cur(c), "<span class=\"callout\">");
    spdf_md_buf_escape(cur(c), type, strlen(type));
    spdf_md_buf_puts(cur(c), "</span>");
    i = end + 1;
    c->callout = 2;
    return i;
}

static int text(MD_TEXTTYPE type, const MD_CHAR* text, MD_SIZE size, void* user) {
    conv* c = (conv*)user;
    spdf_md_buf* b = cur(c);
    size_t skip = 0;

    if (c->heading_level && (type == MD_TEXT_NORMAL || type == MD_TEXT_CODE || type == MD_TEXT_ENTITY))
        spdf_md_buf_append(&c->heading_text, text, size);

    /* An inline <script>...</script> island: md4c hands the tags over as HTML
     * and the text between them as ordinary text. The sanitizer is swallowing
     * that element, so its Markdown-side content must go too. */
    if (c->sanitizer.skip_tag[0] && type != MD_TEXT_HTML) return c->aborted;

    switch (type) {
        case MD_TEXT_NORMAL:
            if (b == &c->para) {
                size_t i;
                if (c->callout == 1) skip = callout_marker(c, text, size);
                for (i = skip; i < size; ++i)
                    if (!isspace((unsigned char)text[i])) {
                        c->para_text = 1;
                        break;
                    }
            }
            spdf_md_buf_escape(b, text + skip, size - skip);
            break;
        case MD_TEXT_NULLCHAR: spdf_md_buf_puts(b, "\xEF\xBF\xBD"); break;
        case MD_TEXT_BR: spdf_md_buf_puts(b, "<br>\n"); break;
        case MD_TEXT_SOFTBR:
            if (c->callout == 2) { /* the callout title ends with its line */
                spdf_md_buf_puts(b, "<br>\n");
                c->callout = 0;
            } else {
                spdf_md_buf_putc(b, '\n');
            }
            break;
        case MD_TEXT_ENTITY: spdf_md_buf_append(b, text, size); break;
        case MD_TEXT_CODE:
            if (b == &c->code) spdf_md_buf_append(b, text, size); /* highlighted at close */
            else spdf_md_buf_escape(b, text, size);
            break;
        case MD_TEXT_HTML:
            if (b == &c->html) spdf_md_buf_append(b, text, size); /* sanitised at close */
            else spdf_md_sanitize(&c->sanitizer, text, size, b);
            break;
        case MD_TEXT_LATEXMATH: spdf_md_buf_append(b, text, size); break;
    }
    if (c->callout == 1 && type != MD_TEXT_SOFTBR) c->callout = 0; /* first run was not a marker */
    return c->aborted;
}

char* spdf_markdown_body_html(const char* markdown, size_t len, const spdf_markdown_options* options) {
    conv c;
    MD_PARSER parser;
    size_t skip;
    int rc;
    char* result;

    memset(&c, 0, sizeof(c));
    c.opts = options;
    c.stack[0] = &c.out;
    spdf_md_sanitizer_init(&c.sanitizer, options);
    if (!markdown) markdown = "", len = 0;
    if (len >= 3 && (unsigned char)markdown[0] == 0xEF && (unsigned char)markdown[1] == 0xBB &&
        (unsigned char)markdown[2] == 0xBF)
        markdown += 3, len -= 3; /* UTF-8 BOM */
    skip = spdf_markdown_front_matter_length(markdown, len);

    memset(&parser, 0, sizeof(parser));
    parser.flags = MD_DIALECT_GITHUB | MD_FLAG_LATEXMATHSPANS | MD_FLAG_WIKILINKS;
    parser.enter_block = enter_block;
    parser.leave_block = leave_block;
    parser.enter_span = enter_span;
    parser.leave_span = leave_span;
    parser.text = text;
    rc = md_parse(markdown + skip, (MD_SIZE)(len - skip), &parser, &c);

    result = rc == 0 && !c.aborted ? spdf_md_buf_detach(&c.out) : NULL;
    spdf_md_buf_free(&c.out);
    spdf_md_buf_free(&c.heading_html);
    spdf_md_buf_free(&c.heading_text);
    spdf_md_buf_free(&c.slugs);
    spdf_md_buf_free(&c.para);
    spdf_md_buf_free(&c.captions);
    spdf_md_buf_free(&c.img_alt);
    spdf_md_buf_free(&c.code);
    spdf_md_buf_free(&c.html);
    spdf_md_buf_free(&c.math);
    return result;
}

/* spdf_markdown_fences.c -- the document's fenced code blocks, in the order the
 * converter numbers them.
 *
 * WHY A SECOND md4c PASS RATHER THAN A TABLE BUILT DURING CONVERSION. The
 * converter is a pure function of its arguments with one output, the HTML
 * (spdf_markdown.h); handing it a second out-parameter would mean every caller
 * carrying a table it does not want, and the two Markdown renditions building
 * it twice. A scan is cheap -- md4c over a README is well under a millisecond,
 * and the frontend runs it once per document, not once per paint -- so the
 * cheaper thing to buy is the separation.
 *
 * WHAT MAKES THE ORDINALS AGREE. This file uses the SAME parser flags
 * (MD_DIALECT_GITHUB | MD_FLAG_LATEXMATHSPANS | MD_FLAG_WIKILINKS) after the
 * SAME BOM and front-matter skip as spdf_markdown_body_html, and md4c visits
 * blocks in document order. So the Nth MD_BLOCK_CODE here is the Nth one there,
 * which is the one the converter gave id="spdf-code-N". That is a construction,
 * not a match: no geometry, no text heuristics, nothing to drift. If either side
 * ever changes its flags or its skip, SPDFCoreMarkdownTests' agreement case --
 * which counts the converter's anchors and this scan's fences over the same
 * document and compares the languages -- fails immediately.
 *
 * INDENTED CODE BLOCKS ARE INCLUDED, deliberately: md4c reports a four-space
 * block as MD_BLOCK_CODE too, and the converter emits a <pre> for it with the
 * same numbering. Such a block has no info string, so it reads as Plain Text --
 * which is what it is, and it still gets a copy button.
 */
#include "spdf_markdown.h"

/* Relative on purpose, as in spdf_markdown.c: no build adds ext/md4c to the
 * include path. */
#include "../../ext/md4c/md4c.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The same ceiling the converter's other budgets have in spirit: a document
 * with more code blocks than this is not one a person is reading, and the
 * frontend would be publishing a mark per fence per paint. */
#define SPDF_MD_FENCE_MAX 4096

typedef struct scan {
    spdf_markdown_fences* out;
    int cap;
    spdf_md_buf code; /* the open block's source */
    int inside;
    char info[96];
    int failed;
} scan;

static void copy_trimmed(const MD_ATTRIBUTE* a, char* out, size_t cap) {
    const char* text = a && a->text ? a->text : "";
    size_t n = a && a->text ? (size_t)a->size : 0;
    while (n && isspace((unsigned char)text[0])) ++text, --n;
    while (n && isspace((unsigned char)text[n - 1])) --n;
    if (n >= cap) n = cap - 1;
    memcpy(out, text, n);
    out[n] = '\0';
}

static int reserve(scan* s) {
    int want = s->out->count + 1;
    spdf_markdown_fence* grown;
    int cap;
    if (want <= s->cap) return 1;
    cap = s->cap ? s->cap * 2 : 8;
    while (cap < want) cap *= 2;
    grown = (spdf_markdown_fence*)realloc(s->out->items, (size_t)cap * sizeof(*grown));
    if (!grown) return 0;
    memset(grown + s->cap, 0, (size_t)(cap - s->cap) * sizeof(*grown));
    s->out->items = grown;
    s->cap = cap;
    return 1;
}

static int enter_block(MD_BLOCKTYPE type, void* detail, void* user) {
    scan* s = (scan*)user;
    if (type != MD_BLOCK_CODE) return 0;
    if (s->out->count >= SPDF_MD_FENCE_MAX) {
        s->failed = 1;
        return 1;
    }
    copy_trimmed(detail ? &((const MD_BLOCK_CODE_DETAIL*)detail)->info : NULL, s->info, sizeof(s->info));
    s->code.len = 0;
    s->inside = 1;
    return 0;
}

static int leave_block(MD_BLOCKTYPE type, void* detail, void* user) {
    scan* s = (scan*)user;
    spdf_markdown_fence* f;
    const spdf_markdown_language* lang;
    size_t len;

    (void)detail;
    if (type != MD_BLOCK_CODE) return 0;
    s->inside = 0;
    if (!reserve(s)) {
        s->failed = 1;
        return 1;
    }
    /* md4c terminates the last line with '\n'; the copy should not end with a
     * blank line the author did not write. Interior blank lines are kept, which
     * is the whole point of copying the RAW source. */
    len = s->code.len;
    if (len && s->code.data && s->code.data[len - 1] == '\n') --len;

    f = &s->out->items[s->out->count];
    f->index = s->out->count;
    snprintf(f->info, sizeof(f->info), "%s", s->info);
    f->diagram = spdf_markdown_is_diagram_fence(s->info, strlen(s->info));
    lang = spdf_markdown_language_for_fence(s->info, strlen(s->info));
    snprintf(f->language, sizeof(f->language), "%s", lang ? lang->id : "");
    f->code = (char*)malloc(len + 1);
    if (!f->code) {
        s->failed = 1;
        return 1;
    }
    if (len) memcpy(f->code, s->code.data, len);
    f->code[len] = '\0';
    f->code_len = len;
    ++s->out->count;
    return 0;
}

/* md4c calls every callback in MD_PARSER unconditionally -- a NULL one is a
 * jump through a null pointer, not a "not interested". Spans carry nothing a
 * code block needs, so these are no-ops, but they have to exist. (Left out
 * once: the first *emphasis* in the document took the process down.) */
static int enter_span(MD_SPANTYPE type, void* detail, void* user) {
    (void)type;
    (void)detail;
    (void)user;
    return 0;
}

static int leave_span(MD_SPANTYPE type, void* detail, void* user) {
    (void)type;
    (void)detail;
    (void)user;
    return 0;
}

static int text_run(MD_TEXTTYPE type, const MD_CHAR* text, MD_SIZE size, void* user) {
    scan* s = (scan*)user;
    if (!s->inside) return 0;
    switch (type) {
        /* Inside a code block md4c reports the source as CODE runs and the line
         * ends as BR; nothing is escaped and nothing is a span, so the runs
         * concatenate back into exactly the bytes between the fences. */
        case MD_TEXT_BR:
        case MD_TEXT_SOFTBR: spdf_md_buf_putc(&s->code, '\n'); break;
        case MD_TEXT_NULLCHAR: spdf_md_buf_putc(&s->code, '\0'); break;
        default: spdf_md_buf_append(&s->code, text, size); break;
    }
    return s->code.failed;
}

int spdf_markdown_scan_fences(const char* markdown, size_t len, spdf_markdown_fences* out) {
    scan s;
    MD_PARSER parser;
    size_t skip;
    int rc;

    if (!out) return 0;
    memset(out, 0, sizeof(*out));
    memset(&s, 0, sizeof(s));
    s.out = out;
    spdf_md_buf_init(&s.code);

    if (!markdown) markdown = "", len = 0;
    if (len >= 3 && (unsigned char)markdown[0] == 0xEF && (unsigned char)markdown[1] == 0xBB &&
        (unsigned char)markdown[2] == 0xBF)
        markdown += 3, len -= 3;
    skip = spdf_markdown_front_matter_length(markdown, len);

    memset(&parser, 0, sizeof(parser));
    parser.flags = MD_DIALECT_GITHUB | MD_FLAG_LATEXMATHSPANS | MD_FLAG_WIKILINKS;
    parser.enter_block = enter_block;
    parser.leave_block = leave_block;
    parser.enter_span = enter_span;
    parser.leave_span = leave_span;
    parser.text = text_run;
    rc = md_parse(markdown + skip, (MD_SIZE)(len - skip), &parser, &s);

    spdf_md_buf_free(&s.code);
    if (rc != 0 || s.failed) {
        spdf_markdown_free_fences(out);
        return 0;
    }
    return 1;
}

void spdf_markdown_free_fences(spdf_markdown_fences* list) {
    int i;
    if (!list) return;
    for (i = 0; i < list->count; ++i) free(list->items[i].code);
    free(list->items);
    list->items = NULL;
    list->count = 0;
}

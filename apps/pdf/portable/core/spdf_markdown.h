/* spdf_markdown.h -- the Markdown subsystem's internal seams.
 *
 * THE ROUTE (portable/docs/windows-markdown-design.md): Markdown is turned into
 * a self-contained HTML document -- GitHub-flavoured structure, a generated
 * stylesheet, syntax-coloured code, sanitised README HTML, typeset math -- and
 * MuPDF's own HTML engine lays it out on A4 sheets. From there it is an
 * ordinary document to the core: the same render, search, selection, outline,
 * link, print and export paths a PDF takes.
 *
 * WHAT IS PURE. Everything declared here except spdf_markdown_open.c's
 * functions (which live in shenzhen_pdf_core.h) is a pure function of its
 * arguments: no I/O, no globals, no MuPDF. Same input, same bytes out, on every
 * platform -- which is what lets portable/core/tests/SPDFCoreMarkdownTests.c
 * pin the converter byte for byte without a document, a context or a font.
 * The one outward call is the remote-image hook in spdf_markdown_options,
 * and the converter only ever asks it "is this URL cached, and as what name".
 *
 * The public entry points (spdf_open_markdown, spdf_export_pdf,
 * spdf_path_is_markdown, spdf_markdown_default_options) are declared in
 * shenzhen_pdf_core.h, appended to the shared ABI. This header is for the
 * subsystem's own units and its tests.
 */
#ifndef SPDF_MARKDOWN_H
#define SPDF_MARKDOWN_H

#include "shenzhen_pdf_core.h"

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --- growable byte buffer -------------------------------------------------
 * Every producer here appends to one of these. `failed` latches on the first
 * allocation failure and every later append becomes a no-op, so a caller
 * checks once at the end instead of after every write. */
typedef struct spdf_md_buf {
    char* data;
    size_t len;
    size_t cap;
    int failed;
} spdf_md_buf;

void spdf_md_buf_init(spdf_md_buf* b);
void spdf_md_buf_free(spdf_md_buf* b);
void spdf_md_buf_append(spdf_md_buf* b, const char* text, size_t n);
void spdf_md_buf_puts(spdf_md_buf* b, const char* text);
void spdf_md_buf_putc(spdf_md_buf* b, char c);
/* HTML-escape & < > " into entities. Safe for text content and attribute values. */
void spdf_md_buf_escape(spdf_md_buf* b, const char* text, size_t n);
/* ` name="value"` with the value escaped; nothing when value is NULL or "". */
void spdf_md_buf_attr(spdf_md_buf* b, const char* name, const char* value);
/* NUL-terminate and hand the bytes over (caller frees); NULL if any append failed. */
char* spdf_md_buf_detach(spdf_md_buf* b);

/* --- the converter --------------------------------------------------------
 * Markdown -> the <body> contents. GitHub dialect (tables, strikethrough, task
 * lists, autolinks) plus LaTeX math spans and wikilinks; Obsidian YAML front
 * matter is skipped. Never returns partial output: NULL on allocation failure. */
char* spdf_markdown_body_html(const char* markdown, size_t len, const spdf_markdown_options* options);

/* The generated stylesheet for one palette (0 light GitHub-Primer, 1 Obsidian
 * dark). The two differ ONLY in colour values, which is what makes the two
 * renditions paginate identically -- SPDFCoreMarkdownTests pins that. */
char* spdf_markdown_stylesheet(int dark);

/* Wrap a body in the full document with the stylesheet for `dark`. */
char* spdf_markdown_document_html(const char* body, int dark);

/* GitHub-style heading anchor: lowercase, punctuation dropped, spaces to '-'.
 * Writes at most `cap` bytes including the terminator. */
void spdf_markdown_slug(const char* text, size_t len, char* out, size_t cap);
/* The slug made unique against `used` (a "\nslug\n..." list this call appends
 * to): "title", then "title-1", "title-2"... as GitHub numbers repeats. */
void spdf_markdown_unique_slug(spdf_md_buf* used, const char* text, size_t len, char* out, size_t cap);
/* Bytes of a leading Obsidian "---" YAML front-matter block, 0 when none. */
size_t spdf_markdown_front_matter_length(const char* markdown, size_t len);

/* --- syntax highlighting ---------------------------------------------------
 * Token classes, emitted as <span class="X">. One letter each so the generated
 * HTML stays small on a code-heavy README. */
enum {
    SPDF_MD_TOKEN_KEYWORD = 'k',
    SPDF_MD_TOKEN_STRING = 's',
    SPDF_MD_TOKEN_NUMBER = 'n',
    SPDF_MD_TOKEN_COMMENT = 'c',
    SPDF_MD_TOKEN_KEY = 'y',
    SPDF_MD_TOKEN_MARKUP = 'm'
};

typedef struct spdf_md_token {
    size_t start;
    size_t end;
    char kind;
} spdf_md_token;

typedef struct spdf_md_tokens {
    spdf_md_token* items;
    size_t count;
    size_t cap;
    int failed;
} spdf_md_tokens;

void spdf_md_tokens_add(spdf_md_tokens* t, size_t start, size_t end, char kind);
void spdf_md_tokens_free(spdf_md_tokens* t);

typedef struct spdf_markdown_language {
    const char* id;      /* "cpp" */
    const char* name;    /* "C++" -- the picker's display name */
    const char* aliases; /* space-separated fence aliases, lower case: "c++ cc cxx" */
} spdf_markdown_language;

/* The 31-entry catalog, sorted by display name as the picker shows it. */
int spdf_markdown_language_count(void);
const spdf_markdown_language* spdf_markdown_language_at(int index);
/* Resolve a fence info string ("c++ title=x") by its first token, case-
 * insensitively, through ids and aliases. NULL when unknown. */
const spdf_markdown_language* spdf_markdown_language_for_fence(const char* info, size_t len);
/* mermaid / sequence / flow: the fences macOS draws as diagrams. */
int spdf_markdown_is_diagram_fence(const char* info, size_t len);
/* The picker's searchable list, as one predicate: 1 when the catalog entry at
 * `index` matches `query` -- a case-insensitive SUBSTRING of its id, its display
 * name or any of its aliases, which is what -languagesMatchingQuery: does on
 * macOS. An empty or blank query matches everything, so the list opens on the
 * whole catalog. Not a fuzzy score: substring keeps the catalog's own order,
 * and the order is the sorted display names the picker shows. */
int spdf_markdown_language_matches(int index, const char* query);
/* The language id options->language_overrides names for the fence at `index`,
 * or NULL when there is no entry -- the fence's own info string then decides.
 * Last entry wins, so a frontend may append rather than rewrite. */
const char* spdf_markdown_language_override_for(const spdf_markdown_options* options, int index);

/* Tokenise `code` for language `id`. Returns 0 when the language is not one of
 * the catalog's (or is "plain"), in which case `out` is left empty. Tokens are
 * in order and never overlap. */
int spdf_markdown_tokenize(const char* id, const char* code, size_t len, spdf_md_tokens* out);
/* Escape `code` into `out` with the tokens wrapped in <span class="X">. */
void spdf_markdown_highlight_html(const char* id, const char* code, size_t len, spdf_md_buf* out);

/* --- LaTeX subset -> HTML --------------------------------------------------
 * Greek and operator symbols to Unicode, ^ and _ to <sup>/<sub>, \frac to a
 * vulgar fraction or a fraction slash, \sqrt to a radical, \text upright,
 * single letters in italic; an unknown command degrades to its visible name
 * in the code font. Content is never dropped. */
void spdf_markdown_math_html(const char* latex, size_t len, int display, spdf_md_buf* out);

/* --- README HTML, sanitised -------------------------------------------------
 * State that persists across the fragments md4c hands over: a dangerous
 * element opened in one fragment keeps swallowing until its close tag. */
typedef struct spdf_md_sanitizer {
    char skip_tag[16]; /* the drop-with-content element currently open, or "" */
    const spdf_markdown_options* options;
} spdf_md_sanitizer;

void spdf_md_sanitizer_init(spdf_md_sanitizer* s, const spdf_markdown_options* options);
/* Rewrite one raw-HTML fragment through the whitelist into `out`. */
void spdf_md_sanitize(spdf_md_sanitizer* s, const char* html, size_t len, spdf_md_buf* out);

/* --- image sources -------------------------------------------------------
 * Resolve an image source under the reader's policy: a relative path inside
 * the document's directory stays; an https URL becomes ".spdf-remote/<name>"
 * when the hook has it cached; everything else (http, data:, file:, absolute
 * or parent-traversing paths, an uncached URL) returns 0 and the caller
 * renders the "[Image: alt]" placeholder. */
int spdf_markdown_resolve_image(const spdf_markdown_options* options, const char* src, size_t len, char* out,
                                size_t cap);
/* 1 when href may be emitted as a link (http, https, mailto, #anchor, or a
 * relative path); javascript:, data:, file: and the like return 0. */
int spdf_markdown_href_allowed(const char* href, size_t len);

#define SPDF_MARKDOWN_REMOTE_MOUNT ".spdf-remote"

/* --- lexer primitives (spdf_markdown_lang.c, shared with spdf_markdown_lex.c) --
 * Byte-oriented over UTF-8; any byte >= 0x80 is an identifier character. */
int spdf_md_lex_ident_start(unsigned char c);
int spdf_md_lex_ident_continue(unsigned char c);
int spdf_md_lex_matches(const char* code, size_t len, size_t i, const char* needle);
size_t spdf_md_lex_until(const char* code, size_t len, size_t i, const char* close);
size_t spdf_md_lex_line(const char* code, size_t len, size_t i);
size_t spdf_md_lex_quoted(const char* code, size_t len, size_t i, char quote, int allow_triple);
size_t spdf_md_lex_number(const char* code, size_t len, size_t i);
size_t spdf_md_lex_ident(const char* code, size_t len, size_t i);
int spdf_md_lex_grammar(const char* id, const char* code, size_t len, spdf_md_tokens* out);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_MARKDOWN_H */

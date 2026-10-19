#ifndef SHENZHEN_PDF_CORE_H
#define SHENZHEN_PDF_CORE_H

#include "spdf_recolor.h"

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct spdf_document spdf_document;

typedef enum spdf_open_status {
    SPDF_OPEN_OK = 0,
    SPDF_OPEN_PASSWORD_REQUIRED = 1,
    SPDF_OPEN_BAD_PASSWORD = 2,
    SPDF_OPEN_ERROR = 3
} spdf_open_status;

/* Authentication classes returned by MuPDF. They are flags because a
 * document handler may report more than one successful class. */
typedef enum spdf_authentication {
    SPDF_AUTHENTICATION_NOT_REQUIRED = 0,
    SPDF_AUTHENTICATION_WITHOUT_PASSWORD = 1 << 0,
    SPDF_AUTHENTICATION_USER_PASSWORD = 1 << 1,
    SPDF_AUTHENTICATION_OWNER_PASSWORD = 1 << 2
} spdf_authentication;

typedef struct spdf_bitmap {
    int width;
    int height;
    int stride;
    unsigned char* rgba;
} spdf_bitmap;

typedef struct spdf_outline_item {
    char* title;
    int page_index;
    int level;
    /* Destination point of the heading on its page, taken from the PDF outline
     * link (fz_outline.x/y). PDF destination coordinates are in PDF user space
     * (origin bottom-left, y increases UPWARD). has_dest is 0 when the outline
     * entry carries no usable point (e.g. /Fit-style dests, or non-finite
     * coordinates); callers must fall back to page-only attribution then.
     * Appended at the end of the struct so the Linux build, which ignores these
     * fields, is unaffected. */
    float dest_x;
    float dest_y;
    int has_dest;
} spdf_outline_item;

typedef struct spdf_outline {
    spdf_outline_item* items;
    int count;
} spdf_outline;

typedef struct spdf_rect {
    float x0;
    float y0;
    float x1;
    float y1;
} spdf_rect;

typedef enum spdf_selection_status {
    SPDF_SELECTION_ERROR = -1,
    SPDF_SELECTION_NONE = 0,
    SPDF_SELECTION_OK = 1
} spdf_selection_status;

typedef enum spdf_selection_granularity {
    SPDF_SELECTION_RANGE = 0,
    SPDF_SELECTION_WORD = 1,
    SPDF_SELECTION_BLOCK = 2
} spdf_selection_granularity;

enum {
    SPDF_SELECTION_GEOMETRY_INCOMPLETE = 1 << 0,
    SPDF_SELECTION_UNICODE_INCOMPLETE = 1 << 1
};

typedef struct spdf_text_selection {
    char* text;
    spdf_rect* rects;
    int rect_count;
    unsigned flags;
} spdf_text_selection;

typedef struct spdf_comment_item {
    char* author;
    char* text;
    char* type;
    int index;
    int page_index;
    spdf_rect bounds;
} spdf_comment_item;

typedef struct spdf_comments {
    spdf_comment_item* items;
    int count;
} spdf_comments;

typedef struct spdf_text_line {
    char* text;
    spdf_rect bounds;
    float font_size;
} spdf_text_line;

typedef struct spdf_text_lines {
    spdf_text_line* items;
    int count;
    int image_backed;
} spdf_text_lines;

typedef enum spdf_translation_background {
    SPDF_TRANSLATION_BACKGROUND_NONE = -1,
    SPDF_TRANSLATION_BACKGROUND_AUTO = 0,
    SPDF_TRANSLATION_BACKGROUND_OPAQUE = 1
} spdf_translation_background;

typedef struct spdf_translated_line {
    int page_index;
    spdf_rect bounds;
    const char* text;
    float font_size;
    int opaque_background;
} spdf_translated_line;

typedef enum spdf_link_kind {
    SPDF_LINK_NONE = 0,
    SPDF_LINK_URI = 1,
    SPDF_LINK_INTERNAL = 2
} spdf_link_kind;

typedef struct spdf_link_target {
    spdf_link_kind kind;
    char* uri;
    int page_index;
    float x;
    float y;
    float zoom;
} spdf_link_target;

/* Cooperative render cancellation. A token wraps a mupdf fz_cookie; canceling
 * sets the cookie's abort flag, which mupdf polls between content-stream tokens
 * and display-list nodes, stopping the render within milliseconds. A canceled
 * render returns 0 with err "Render canceled." -- callers must treat that as a
 * non-error cancellation, not a render failure. spdf_render_token_cancel() is
 * safe to call from any thread while a render using the token is running;
 * free() only after no render is using the token. Passing NULL keeps the
 * legacy non-cancelable behavior. */
typedef struct spdf_render_token spdf_render_token;

spdf_render_token* spdf_render_token_new(void);
void spdf_render_token_cancel(spdf_render_token* token); /* thread-safe: sets cookie.abort = 1 */
void spdf_render_token_free(spdf_render_token* token);

enum {
    SPDF_RENDER_DEFAULT = 0,
    SPDF_RENDER_USE_PAGE_LIST = 1 << 0, /* render by replaying a cached per-page display list */
    /* Recolor the page for the dark reading theme (see spdf_recolor.h). This
     * is opt-in PER RENDER rather than a mode set on the document, so that
     * print, export and Copy Page get the document's own colors by doing
     * nothing: a PDF's colors are its content, and a file that baked in our
     * dark paper would be wrong everywhere else it is ever opened. It also
     * means a preference change needs no state pushed onto the several
     * document handles (per tab, per render thread) that alias one file. */
    SPDF_RENDER_DARK_THEME = 1 << 1,
    /* With SPDF_RENDER_DARK_THEME: leave the page's image regions in their
     * original colors instead of recoloring them, so photographs are not
     * lightness-inverted. Ignored on a page that is essentially one big image
     * (a scan), which is recolored whole -- otherwise this setting would
     * silently turn dark mode off on scanned documents. Costs one structured
     * text pass the first time a page is rendered, cached thereafter. */
    SPDF_RENDER_PRESERVE_IMAGES = 1 << 2
};

/* How the LAST render on this document got its pixels (profiling aid). */
typedef struct spdf_render_stats {
    int used_list;   /* 1 if the render replayed a display list */
    int built_list;  /* 1 if that render had to build the list first */
    double build_ms; /* display-list build time for that render, 0 when not built */
} spdf_render_stats;

/* Open and, when needed, authenticate a document. A NULL password means no
 * credential was supplied; an empty string is a supplied empty password.
 * Locked documents never produce a partially initialized document. */
spdf_document* spdf_open_with_password(const char* path, const char* password, spdf_open_status* status,
                                       spdf_authentication* authentication, char* err, size_t err_len);
/* Compatibility opener. It opens unprotected documents and returns NULL with
 * "Password required." for locked documents. */
spdf_document* spdf_open(const char* path, char* err, size_t err_len);
void spdf_close(spdf_document* doc);

int spdf_page_count(spdf_document* doc);
const char* spdf_title(spdf_document* doc);
/* Look up a document metadata string by mupdf key ("format", "encryption",
 * "info:Title", "info:Author", "info:Subject", "info:Keywords", "info:Creator",
 * "info:Producer", "info:CreationDate", "info:ModDate"). Returns 1 and fills
 * buf (NUL-terminated, possibly truncated) when a non-empty value exists;
 * returns 0 (buf set to "") when the key is absent, empty, or unsupported by
 * the document's format handler. */
int spdf_lookup_metadata(spdf_document* doc, const char* key, char* buf, size_t buf_len);
/* Permission check. `permission` is an fz_permission character constant:
 * 'p' print, 'c' copy, 'e' edit, 'n' annotate. Returns 1 when allowed (also
 * for formats without a permission model), 0 when the document denies it.
 * Permission-query failures on password-protected documents fail closed.
 *
 * 'c' (COPY) ALWAYS returns 1, by product decision. The PDF copy flag is an
 * advisory request to the viewer rather than access control: by the time it
 * could be consulted the document is decrypted and its text is on screen and
 * selectable, and general-purpose extractors ignore it. Honouring it only
 * stopped a reader quoting a document they are already looking at. Print,
 * edit and annotate still answer the document's own flags. */
int spdf_has_permission(spdf_document* doc, int permission);
/* Non-mutating snapshots captured during open. Unlike MuPDF's
 * fz_needs_password(), these calls cannot reset an authenticated PDF. */
int spdf_is_password_protected(const spdf_document* doc);
spdf_authentication spdf_authentication_result(const spdf_document* doc);
/* Compatibility alias for spdf_is_password_protected(). */
int spdf_needs_password(spdf_document* doc);
int spdf_set_page_size_cache(spdf_document* doc, int page_index, float width, float height);
int spdf_page_size(spdf_document* doc, int page_index, float* width, float* height, char* err, size_t err_len);

int spdf_render_page_rgba(spdf_document* doc, int page_index, float zoom, spdf_bitmap* out, char* err, size_t err_len);
int spdf_render_page_region_rgba(spdf_document* doc, int page_index, float zoom, spdf_rect region, spdf_bitmap* out,
                                 char* err, size_t err_len);
int spdf_render_page_rgba_opts(spdf_document* doc, int page_index, float zoom, unsigned flags, spdf_render_token* token,
                               spdf_bitmap* out, char* err, size_t err_len);
int spdf_render_page_region_rgba_opts(spdf_document* doc, int page_index, float zoom, spdf_rect region, unsigned flags,
                                      spdf_render_token* token, spdf_bitmap* out, char* err, size_t err_len);
void spdf_drop_page_list_cache(spdf_document* doc, int page_index); /* -1 = drop all cached page lists */
spdf_render_stats spdf_last_render_stats(const spdf_document* doc);
void spdf_free_bitmap(spdf_bitmap* bitmap);

int spdf_search_page(spdf_document* doc, int page_index, const char* needle, char* err, size_t err_len);
int spdf_search_page_rects(spdf_document* doc, int page_index, const char* needle, spdf_rect* rects, int rect_max,
                           char* err, size_t err_len);
int spdf_search_page_options(spdf_document* doc, int page_index, const char* needle, int regex, int regex_multiline,
                             char* err, size_t err_len);
int spdf_search_page_rects_options(spdf_document* doc, int page_index, const char* needle, int regex,
                                   int regex_multiline, spdf_rect* rects, int rect_max, char* err, size_t err_len);
/* RANGE uses both endpoints. WORD and BLOCK use only (ax, ay), require a hit
 * inside real glyph geometry, and never snap across image/OCR gaps. OK returns
 * owned UTF-8 text plus all finite, non-empty rectangles. NONE is a valid
 * request without selectable geometry. ERROR zeroes out and fills err. */
spdf_selection_status spdf_select_text(spdf_document* doc, int page_index, spdf_selection_granularity granularity,
                                       float ax, float ay, float bx, float by, spdf_text_selection* out, char* err,
                                       size_t err_len);
/* Frees text and rectangles and zeroes the structure. */
void spdf_free_text_selection(spdf_text_selection* selection);
int spdf_select_page_text(spdf_document* doc, int page_index, float ax, float ay, float bx, float by, spdf_rect* rects,
                          int rect_max, char** text_out, char* err, size_t err_len);
void spdf_free_string(char* text);
int spdf_extract_page_text_lines(spdf_document* doc, int page_index, spdf_text_lines* out, char* err, size_t err_len);
void spdf_free_text_lines(spdf_text_lines* lines);

int spdf_load_outline(spdf_document* doc, spdf_outline* out, char* err, size_t err_len);
void spdf_free_outline(spdf_outline* outline);
int spdf_load_comments(spdf_document* doc, spdf_comments* out, char* err, size_t err_len);
void spdf_free_comments(spdf_comments* comments);
/* detect_text_links: when non-zero, also scan the page's structured text for
 * plain-text URLs (builds the full stext page — expensive on dense pages, so
 * pass 0 for hover/cursor hit-testing and 1 only when actually following a
 * link on click). */
int spdf_link_at_point(spdf_document* doc, int page_index, float x, float y, spdf_link_target* out,
                       int detect_text_links, char* err, size_t err_len);
void spdf_free_link_target(spdf_link_target* target);
/* Collect the page-space rectangles of every clickable link on the page:
 * all link annotations with a target (the same set spdf_link_at_point
 * follows), plus, when detect_text_links is non-zero, plain-text URLs found
 * in the page's structured text (builds the full stext page once - callers
 * cache the result rather than calling this per hit-test). Fills up to
 * rect_max rects and returns the number written, or -1 on error (err is
 * filled). Rects are unpadded; the at-point text-URL check applies a 2pt
 * slop, so hover hit-testing should expand them by the same amount. */
int spdf_page_link_rects(spdf_document* doc, int page_index, int detect_text_links, spdf_rect* rects, int rect_max,
                         char* err, size_t err_len);
int spdf_add_highlight_comment(spdf_document* doc, int page_index, const spdf_rect* rects, int rect_count,
                               const char* text, const char* author, char* err, size_t err_len);
int spdf_add_text_comment(spdf_document* doc, int page_index, float x, float y, const char* text, const char* author,
                          char* err, size_t err_len);
int spdf_update_comment(spdf_document* doc, int comment_index, const char* text, const char* author, char* err,
                        size_t err_len);
int spdf_delete_comment(spdf_document* doc, int comment_index, char* err, size_t err_len);
int spdf_rotate_page(spdf_document* doc, int page_index, int degrees, char* err, size_t err_len);
/* Remove every text-showing operation from every page (keeping images and
 * graphics) and rewrite the file at path (garbage-collected, so the old text
 * streams are dropped, not just orphaned) so the document can be re-OCR'd.
 * Returns 1 on success, 0 on failure (err is filled). */
int spdf_delete_all_text(spdf_document* doc, const char* path, char* err, size_t err_len);
int spdf_save_document(spdf_document* doc, const char* path, char* err, size_t err_len);
int spdf_document_has_text(spdf_document* doc, int max_pages, char* err, size_t err_len);
int spdf_save_translated_copy(spdf_document* doc, const char* path, const spdf_translated_line* lines, int line_count,
                              char* err, size_t err_len);
/* Replacement text for one outline entry or one comment in the translated
 * copy. `index` is the item's position in spdf_load_outline order (pre-order
 * walk) for outline titles, or the visible comment index from
 * spdf_load_comments for comments. Arrays passed to
 * spdf_save_translated_copy_full must be sorted by ascending index. */
typedef struct spdf_translated_text {
    int index;
    const char* text;
} spdf_translated_text;
/* Like spdf_save_translated_copy, additionally replacing the titles of the
 * given outline entries and the text contents of the given comments in the
 * written copy. Outline structure, destinations and expansion state are
 * preserved; annotations keep their type, position and appearance (FreeText
 * comments get their appearance regenerated so the translated text shows). */
int spdf_save_translated_copy_full(spdf_document* doc, const char* path, const spdf_translated_line* lines,
                                   int line_count, const spdf_translated_text* outline_titles, int outline_title_count,
                                   const spdf_translated_text* comment_texts, int comment_text_count, char* err,
                                   size_t err_len);
/* Returns 1 when the UTF-8 string contains at least one Han ideograph
 * (CJK Unified Ideographs U+4E00-U+9FFF, Extension A U+3400-U+4DBF,
 * compatibility ideographs U+F900-U+FAFF, or supplementary-plane extensions
 * U+20000-U+2FA1F). Malformed UTF-8 bytes are skipped. Pure helper shared by
 * the translation pipeline so Chinese-source translation can leave blocks
 * with no Chinese text untouched. */
int spdf_text_contains_han(const char* utf8);
/* Returns 1 when the UTF-8 string contains at least one Latin letter (ASCII
 * A-Z/a-z, Latin-1 letters, Latin Extended-A/B, or Latin Extended
 * Additional). Digits, punctuation and non-Latin scripts do not count.
 * Malformed UTF-8 bytes are skipped. */
int spdf_text_contains_latin(const char* utf8);
/* Script family of a translation language code, for the per-item
 * translate/skip decision. Matches the primary subtag case-insensitively
 * ("zh", "zh-TW", "pt_BR"...). */
typedef enum spdf_translation_script {
    SPDF_TRANSLATION_SCRIPT_UNKNOWN = 0, /* unrecognized language code */
    SPDF_TRANSLATION_SCRIPT_LATIN = 1,   /* language written in Latin script */
    SPDF_TRANSLATION_SCRIPT_HAN = 2,     /* Chinese ("zh" simplified, "zt" traditional) */
    SPDF_TRANSLATION_SCRIPT_OTHER = 3    /* recognized language in a script the detectors cannot classify */
} spdf_translation_script;
spdf_translation_script spdf_translation_script_for_language(const char* code);
/* Per-item translate/skip decision for whole-document translation, used
 * uniformly for body text blocks, outline titles and comments. A source
 * language with a detectable script takes precedence: Chinese source keeps
 * only items containing Han text (existing behavior); a Latin-script source
 * keeps only Latin-script items without Han text. When the source script is
 * unknown the target decides: Chinese target keeps Latin-script items,
 * Latin-script target keeps Han items. Items in neither script (digits,
 * punctuation) or already in the target script are skipped. Sources in other
 * scripts (Cyrillic, Japanese...) are never filtered. */
int spdf_translation_should_translate(const char* utf8, spdf_translation_script source_script,
                                      spdf_translation_script target_script);
/* Write a standalone single-page PDF (the given page grafted into a fresh
 * document) to path. Backs the "Copy Page" clipboard action on both platforms.
 * Returns 1 on success, 0 on failure (err is filled). */
int spdf_save_single_page_pdf(spdf_document* doc, int page_index, const char* path, char* err, size_t err_len);

/* ===========================================================================
 * Markdown (portable/core/spdf_markdown*.c) -- ADDITIVE. Nothing above this
 * line changes behaviour for a frontend that never calls these.
 *
 * A Markdown file opens as an ordinary spdf_document: md4c parses it,
 * spdf_markdown.c emits GitHub-flavoured HTML with a generated stylesheet, and
 * MuPDF's HTML engine paginates it onto A4. Every other call in this header
 * (render, search, select, outline, links, print, Copy Page...) then works on
 * it unchanged. See portable/docs/windows-markdown-design.md.
 * =========================================================================== */

/* Asked for each https image while converting: is `url` in the frontend's disk
 * cache? Return 1 and write the CACHE FILE NAME (a bare file name inside
 * options->remote_image_dir, e.g. "3fa9...e1.png") into `cache_name_out`, or
 * return 0 for "not cached" -- the image then renders as a text placeholder
 * and the frontend may fetch it and reopen. The converter never opens a
 * connection; the hook must not either (it runs inside open). */
typedef int (*spdf_markdown_image_hook)(void* user, const char* url, char* cache_name_out, size_t cap);

/* One entry of spdf_markdown_options.language_overrides: "highlight the fence
 * at this position as this catalog language, whatever its info string says". */
typedef struct spdf_markdown_language_override {
    int fence_index;         /* 0-based, document order */
    const char* language_id; /* a spdf_markdown_language id, or "plain" */
} spdf_markdown_language_override;

typedef struct spdf_markdown_options {
    /* Body text size multiplier, the A-/A+ control; clamped to [0.5, 3.0] like
     * macOS's markdownFontScale. 1.0 is an 11pt body on A4. */
    float text_scale;
    /* 0: A4 portrait. 1: A4 landscape (the Rotate commands on a Markdown tab). */
    int landscape;
    /* Also lay out the Obsidian-dark rendition, drawn when a render carries
     * SPDF_RENDER_DARK_THEME. Costs a second layout at open; a frontend
     * without a dark theme passes 0. Print and export never see it. */
    int dark_rendition;
    /* Remote images: NULL means every https image is a placeholder. */
    spdf_markdown_image_hook remote_image;
    void* remote_image_user;
    /* Absolute directory holding the files the hook names; mounted into the
     * document's resource tree so MuPDF can load them. NULL disables. */
    const char* remote_image_dir;
    /* LOCAL IMAGES MuPDF CANNOT DECODE. MuPDF 1.27 has no WebP loader (there is
     * no load-webp.c in mupdf/source/fitz), so `![](shot.webp)` reaches
     * load_html_image(), fails to decode and draws MuPDF's own "[image]" word.
     * When this hook is set, a document-relative image whose extension is one
     * of those (today only .webp) is offered to the frontend FIRST, as an
     * absolute path built from document_dir; the frontend transcodes it into
     * remote_image_dir and answers with the cache file name, exactly as
     * remote_image answers for an https URL, and the converter points the <img>
     * at ".spdf-remote/<name>". Answering 0 leaves the original source in
     * place, so the "[image]" fallback is what a machine without the codec
     * still gets. Needs remote_image_dir and document_dir to be set too. */
    spdf_markdown_image_hook local_image;
    void* local_image_user;
    /* The document's own folder, no trailing separator. spdf_open_markdown
     * fills this in from the path it was given; a caller converting HTML by
     * hand sets it only if it also sets local_image. */
    const char* document_dir;
    /* PER-FENCE LANGUAGE OVERRIDES, the in-page language picker's whole effect
     * on the document. `count` entries; each names a fence by its 0-based
     * position in the document and the catalog id to highlight it as. An entry
     * wins over the fence's own info string, and over the diagram-fence rule
     * that leaves mermaid uncoloured; "plain" clears highlighting, which is why
     * Plain Text is an explicit choice rather than the absence of one. An index
     * no fence has is ignored. Borrowed, not copied: the frontend owns the
     * array and must outlive the open. */
    const spdf_markdown_language_override* language_overrides;
    int language_override_count;
} spdf_markdown_options;

/* text_scale 1.0, portrait, dark rendition on, no remote images. */
spdf_markdown_options spdf_markdown_default_options(void);

/* 1 for a path ending in .md or .markdown (case-insensitive). The core's
 * spdf_open() does NOT dispatch on this -- a frontend that wants Markdown
 * calls spdf_open_markdown() for these paths and keeps spdf_open() for the
 * rest, so existing callers see no change. */
int spdf_path_is_markdown(const char* path);

/* Open a Markdown file as a paginated document. NULL options = defaults.
 * Returns NULL with err filled on failure (unreadable file, over the 64 MiB
 * budget, layout failure). The document carries no password state. */
spdf_document* spdf_open_markdown(const char* path, const spdf_markdown_options* options, char* err, size_t err_len);

/* Write the document's pages -- all of them when page_index is -1, else the
 * one page -- as a PDF with vector, selectable text, through MuPDF's document
 * writer. Works for ANY open document (Markdown, EPUB, XPS...), which is why
 * it is not a Markdown-named call; for a PDF prefer spdf_save_document /
 * spdf_save_single_page_pdf, which keep the original bytes. Always the LIGHT
 * rendition: this path never sees a render flag. Returns 1 on success. */
int spdf_export_pdf(spdf_document* doc, const char* path, int page_index, char* err, size_t err_len);

/* --- fenced code blocks, for the in-page controls --------------------------
 * The language picker and the copy button need three things the laid-out page
 * cannot tell them: which fence is which, what language it is showing, and the
 * raw source to put on the clipboard. All three come from one pure scan of the
 * Markdown, and the ordinals it produces are the SAME ordinals the converter
 * numbers its <pre> elements with -- both walk md4c with identical flags after
 * the identical front-matter skip -- so fence N and anchor "#spdf-code-N" are
 * the same block by construction rather than by a heuristic match. */
typedef struct spdf_markdown_fence {
    int index;          /* 0-based, document order */
    char info[96];      /* the info string as written, trimmed ("c++ title=x") */
    char language[32];  /* the catalog id it resolves to; "" when unknown */
    int diagram;        /* 1 for a mermaid/sequence/flow fence */
    char* code;         /* the raw source, NUL-terminated, newlines kept */
    size_t code_len;
} spdf_markdown_fence;

typedef struct spdf_markdown_fences {
    spdf_markdown_fence* items;
    int count;
} spdf_markdown_fences;

/* Every fenced code block, in document order. `out` is zeroed first, so a
 * document with none succeeds with count 0. Returns 0 only on a parse or
 * allocation failure, and then `out` is empty. Pure: no I/O, no MuPDF. */
int spdf_markdown_scan_fences(const char* markdown, size_t len, spdf_markdown_fences* out);
void spdf_markdown_free_fences(spdf_markdown_fences* list);

/* The id the converter puts on every <pre>, so a frontend can ask the laid-out
 * document where fence N ended up: "#spdf-code-7". */
#define SPDF_MARKDOWN_CODE_ANCHOR_PREFIX "spdf-code-"

/* The generated stylesheet's own geometry, in points, for a frontend that has to
 * turn "where is fence N" into a rectangle: the page box is
 * @page{margin:60pt 61pt} and a code box pads its first glyph 12pt in from its
 * own edge (spdf_markdown_support.c). Points, so the A-/A+ text size -- which
 * changes only the em -- does not change them. */
#define SPDF_MARKDOWN_PAGE_MARGIN_TOP_PT 60.0f
#define SPDF_MARKDOWN_PAGE_MARGIN_SIDE_PT 61.0f
#define SPDF_MARKDOWN_CODE_BOX_PADDING_PT 12.0f

/* Where an internal anchor -- "#name", an id in a reflowable document -- landed:
 * its page and the y of that point in page space (PDF points, y down). 1 on
 * success; 0 when the document has no such anchor, and then nothing is written.
 * Reflowable formats only in practice, which is why it lives with Markdown. */
int spdf_markdown_resolve_anchor(spdf_document* doc, const char* uri, int* page_index, float* page_y);

#ifdef __cplusplus
}
#endif

#endif

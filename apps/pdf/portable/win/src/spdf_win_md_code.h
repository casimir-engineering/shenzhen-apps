/* spdf_win_md_code.h -- the code box's in-page controls: a copy button on the
 * left of the box's top edge and a language pill on the right.
 *
 * WHAT THIS IS FOR. 26.8.29-2 promises "a quiet language control in the box
 * header" that "opens instantly as a searchable list anchored to the code
 * block", and 26.9.2-1 adds "a copy button to the left of its language picker".
 * The Windows port has no HTML widgets -- the page is a picture MuPDF drew -- so
 * both are canvas chrome: a Direct2D pill drawn over the page after the pages
 * and before the window furniture, hit-tested against the very rectangles that
 * were drawn.
 *
 * GEOMETRY IS PUBLISHED, NOT QUERIED -- the same discipline spdf_win_annot.h
 * states and for the same reason. The input router knows nothing about pages,
 * so the paint that drew the pages hands over each control's rectangle in CLIENT
 * DEVICE PIXELS (spdf_win_md_code_publish_geometry) and the router tests points
 * against those (spdf_win_md_code_marks.h). Painting and hit-testing therefore
 * cannot disagree, because they are the same numbers.
 *
 * HOW A FENCE IS FOUND ON THE PAGE. Not by looking at the picture. The
 * converter puts id="spdf-code-N" on every <pre> and spdf_markdown_scan_fences
 * numbers the same N (portable/core/spdf_markdown_fences.c), so one
 * spdf_markdown_resolve_anchor per fence gives the page it landed on and the y
 * of its top edge, once per document rather than once per paint. The horizontal
 * extent is the stylesheet's own text column -- @page{margin:60pt 61pt}, so 61pt
 * in from each edge of the sheet, in points and therefore independent of the
 * A-/A+ text size. That is an approximation in exactly one case, a fence nested
 * inside a list, where the real box is indented; the pills then sit a little
 * wide of it. Nothing else in the reader depends on the number, and the
 * alternative -- reconstructing the box from the laid-out text's rectangles --
 * costs a structured-text pass per fence to buy a few points of accuracy.
 *
 * THE ROW RESTS ON the box's top edge, reaching a 2px lip inside it: the pills
 * read as chrome fastened to the box and still cannot cover a line of code,
 * which both a row inside the box and a row centred on its edge did -- the
 * anchor MuPDF resolves is the first line's BASELINE, and the box's own padding
 * is only 12pt, so there is no room in it for a 20px pill. The mac reserves a
 * band above the box instead, because its paginator can; MuPDF's cannot without
 * changing where every code block breaks, and an empty reserved band would then
 * appear in every printed and exported page, where there are no controls to put
 * in it.
 *
 * NOTHING HERE REACHES PRINT OR EXPORT, by construction rather than by a check:
 * the pills are painted only in the canvas phase of spdf_win_paint, and print,
 * Save as PDF and Copy Page render through spdf_export_pdf and the flagless
 * render path, which never see a scene. md_code_test pins that the published
 * marks are empty for a document that is not Markdown.
 */
#ifndef SPDF_WIN_MD_CODE_H
#define SPDF_WIN_MD_CODE_H

#include "spdf_win_chrome_state.h" /* SpdfWinMdCodeMark */

#include "shenzhen_pdf_core.h"

#ifdef __cplusplus
extern "C" {
#endif

struct spdf_win_scene;

/* --- metrics, transcribed from the mac's code-control row -------------------
 * SPDFMacMarkdownPageCanvas+Decorations.mm:14-25. Logical pixels; every one is
 * multiplied by the scene's dpi_scale where it is used. */
#define SPDF_WIN_MD_CODE_HEIGHT 20.0f
#define SPDF_WIN_MD_CODE_RADIUS 5.0f
#define SPDF_WIN_MD_CODE_SIDE_INSET 10.0f
#define SPDF_WIN_MD_CODE_PAD_X 9.0f  /* each side of the title */
#define SPDF_WIN_MD_CODE_HIT_SLOP 7.0f
#define SPDF_WIN_MD_CODE_MIN_GAP 6.0f
/* How far the row's bottom edge reaches inside the box's top border. */
#define SPDF_WIN_MD_CODE_LIP 2.0f
#define SPDF_WIN_MD_CODE_TITLE_PX 11.0f
/* How long "Copied" stays up, in milliseconds (the mac's 1.2 s). */
#define SPDF_WIN_MD_CODE_FEEDBACK_MS 1200u
/* The stylesheet's own geometry, from the core (shenzhen_pdf_core.h). */
#define SPDF_WIN_MD_CODE_COLUMN_INSET_PT SPDF_MARKDOWN_PAGE_MARGIN_SIDE_PT
#define SPDF_WIN_MD_CODE_BOX_PADDING_PT SPDF_MARKDOWN_CODE_BOX_PADDING_PT

/* One code box's two controls as the INPUT ROUTER sees them: both rectangles
 * already inflated by the hit slop and already in CLIENT device pixels, so the
 * router tests a point with four comparisons and knows nothing about pages.
 * `copy_*` are all zero when the copy button stood down for want of room --
 * the language pill always keeps the row, as on the mac. */
/* SpdfWinMdCodeMark is declared in spdf_win_chrome_state.h, beside
 * SpdfWinAnnotMark and for the same reason: the router that hit-tests these
 * and the ten tests that include it must not need this module. */

/* What the painter needs for one control, in CANVAS-LOCAL device pixels like
 * every other scene overlay. `title` is UTF-16 because DirectWrite is. */
typedef struct SpdfWinMdCodePill {
    float x, y, w, h;
    const wchar_t* title;
} SpdfWinMdCodePill;

/* --- the document's fences -------------------------------------------------- */

/* Rebuild the table for the document about to be shown: scan `path` for fences,
 * then ask `doc` where each one's anchor landed. One md4c pass plus one anchor
 * resolve per fence, ONCE per document -- never on the paint path. A path that
 * is not Markdown, a NULL doc, or an unreadable file clears the table, which is
 * what makes every non-Markdown tab publish nothing. */
void spdf_win_md_code_sync(spdf_document* doc, const char* path);

/* How many fences the last sync found. */
int spdf_win_md_code_count(void);
/* The catalog language id shown for fence `index` -- its override when it has
 * one, else the language its info string resolved to, else "plain". Never NULL
 * for a valid index; NULL for an invalid one. */
const char* spdf_win_md_code_language(int index);
/* The display name for that id, as the pill's title ("C++", "Plain Text"). */
const char* spdf_win_md_code_language_name(int index);
/* The fence's raw source, for the clipboard. NULL for an invalid index. */
const char* spdf_win_md_code_source(int index, size_t* len_out);

/* --- the override map ------------------------------------------------------- */

/* Record the picker's choice for one fence and bump the options generation, so
 * every handle that reopens the document paginates the same way. Returns 1 when
 * the value actually changed -- the caller re-shows the tab only then. */
int spdf_win_md_code_set_language(int index, const char* language_id);
/* The map as the core wants it, for spdf_win_md_options(). Points at module
 * storage that lives as long as the process. */
const spdf_markdown_language_override* spdf_win_md_code_overrides(int* out_count);
/* Forget every override (a new document, and a test hook). */
void spdf_win_md_code_clear_overrides(void);

/* --- the copied-feedback state ---------------------------------------------- */

/* Put fence `index`'s source on the clipboard and arm the brief "Copied" title.
 * 0 when there is nothing to copy or the clipboard refused, and then no
 * feedback is shown -- a failed copy must not look like a successful one. */
int spdf_win_md_code_copy(int index);
/* The fence currently showing "Copied", or -1. Expires on its own: the answer
 * is -1 once SPDF_WIN_MD_CODE_FEEDBACK_MS has passed, with no timer to leak. */
int spdf_win_md_code_copied(void);
/* Pure half of the above, for the test: which fence is armed given the armed
 * fence, when it was armed, and the time now. */
int spdf_win_md_code_copied_at(int armed, unsigned long long armed_ms, unsigned long long now_ms);

/* --- per paint -------------------------------------------------------------- */

/* From the scene the canvas just built (pages in canvas-local px), the canvas
 * rect's client origin and the zoom (device px per PDF point), publish one mark
 * per fence whose page is drawn. Call once per paint, after build_scene. A NULL
 * scene clears the marks, which is what a document-less frame gets. */
void spdf_win_md_code_publish_geometry(const struct spdf_win_scene* scene, float canvas_x, float canvas_y, float zoom);
const SpdfWinMdCodeMark* spdf_win_md_code_marks(int* out_count);

/* Sync-if-needed then publish, so the one call a foreign paint site has to make
 * carries no policy of its own. The table is rebuilt only when the path or the
 * options generation changed -- a scroll, a resize and a theme toggle all reuse
 * it, and a text-size change or a language choice (both of which bump the
 * generation, and both of which repaginate) rebuild it. */
void spdf_win_md_code_frame(spdf_document* doc, const char* path, const struct spdf_win_scene* scene, float canvas_x,
                            float canvas_y, float zoom);

/* The two pills the painter should draw, in canvas-local px, for the marks the
 * last publish produced. Writes at most `cap` and returns how many it wrote;
 * the copy button is omitted where it stood down. */
int spdf_win_md_code_pills(SpdfWinMdCodePill* out, int cap);

/* --- pure geometry, so a test can pin the row without a scene ---------------
 * `column_x0`/`column_x1` are the code box's left and right edges and `top_y`
 * its top edge, all in the same device-pixel space; `scale` is dpi_scale.
 * Returns 0 for the copy button when the row cannot hold both with
 * SPDF_WIN_MD_CODE_MIN_GAP of air between them. */
float spdf_win_md_code_pill_width(float title_chars, float scale);
int spdf_win_md_code_row(float column_x0, float column_x1, float top_y, float scale, float language_chars,
                         SpdfWinMdCodePill* language_out, SpdfWinMdCodePill* copy_out);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_MD_CODE_H */

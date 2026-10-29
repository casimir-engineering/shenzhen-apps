#ifndef SPDF_OUTLINE_H
#define SPDF_OUTLINE_H

/* A document's outline (chapters): reading it, and writing one into a PDF that has none. Part of shenzhen_pdf_core.h,
 * which includes it; implemented in spdf_outline_read.h and spdf_outline_write.h, compiled in shenzhen_pdf_core.c. */

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

struct spdf_document;

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

int spdf_load_outline(struct spdf_document* doc, spdf_outline* out, char* err, size_t err_len);
void spdf_free_outline(spdf_outline* outline);
/* Chapters for a PDF that has none: `items` in reading order, each with its level (0 for a top chapter), page and,
 * when has_dest, its point on the page as spdf_load_outline gives it (otherwise the top of the page). Writes them as
 * the PDF's outline, open, and saves the file in place, keeping everything else in it. A PDF that already has an
 * outline is left as it is. Returns 1 on success (also for none to add), 0 with err filled. */
int spdf_pdf_add_outline(const char* path, const spdf_outline_item* items, int count, char* err, size_t err_len);

#ifdef __cplusplus
}
#endif

#endif

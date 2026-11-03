#pragma once

/* Dates for comments that have none (defined in spdf_comment_review.h, compiled into shenzhen_pdf_core.c). */

#ifdef __cplusplus
extern "C" {
#endif

struct spdf_document;

/* Dates the newest annotation on page `page_index` (the last one in its list, the one spdf_add_text_comment or
 * spdf_add_highlight_comment just made, which they leave undated): /CreationDate and /M set to now, to the second, as
 * Acrobat writes them. An annotation that already has a date keeps it. 1 on success, 0 with err filled. Save with
 * spdf_save_document. */
int spdf_date_newest_comment(struct spdf_document* doc, int page_index, char* err, size_t err_len);

#ifdef __cplusplus
}
#endif

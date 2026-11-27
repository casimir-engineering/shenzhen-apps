#pragma once
/* A save of a PDF's changes made in memory, written a moment later instead of at once (implemented in
 * spdf_core_open_hooks.h, inside shenzhen_pdf_core.c).
 *
 * Fill & Sign and Annotate change the document in memory, show the change, and owe the file a save. Writing it after
 * every change made a quick run of changes (Backspace five times, a few nudges) wait for one save each, and the first
 * save after opening a large PDF reads every object of the file first (MuPDF's pdf_check_document). Now the frontend
 * marks the save as owed and writes it once the changes rest; whatever closes the document first writes it then
 * (spdf_close), so a closed document never drops a change without telling (spdf_core_set_save_failed_hook). Same threading contract as the document itself
 * (spdf_core_document.h): one thread at a time, the main thread for the app's document. */
#include "shenzhen_pdf_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The document's changes are owed to `path` (copied). A later call with another path replaces it. 0 on no memory. */
int spdf_defer_save(spdf_document* doc, const char* path);
/* The path a save is owed to, or NULL. */
const char* spdf_deferred_save_path(const spdf_document* doc);
/* Writes the owed save (spdf_save_document) and forgets it. 1 when saved or nothing was owed. 0 when it failed, with
 * the reason in err, and the save still owed (a later call, or spdf_close, tries again). It is not written when the
 * file changed since the document read it (spdf_deferred_save_file_changed): err is then SPDF_FILE_CHANGED_ELSEWHERE. */
int spdf_save_deferred(spdf_document* doc, char* err, size_t err_len);
/* 1 when the file the save is owed to is not as this document left it (opened from it, or saved into it): another
 * app replaced, grew or cut it, or it is gone. An increment appended there would damage it. */
int spdf_deferred_save_file_changed(const spdf_document* doc);
#define SPDF_FILE_CHANGED_ELSEWHERE "The file was changed by another app after it was opened here."
/* Writes the whole document, with the owed changes, to a new file at `path` (written beside it, then renamed into
 * place), and forgets the owed save: it is kept there instead. 1 on success; 0 with the reason in err, still owed.
 * The document keeps reading its own file, so the frontend should reopen it from `path` to go on editing there. */
int spdf_save_deferred_copy(spdf_document* doc, const char* path, char* err, size_t err_len);
/* Called by spdf_close, while the document is still whole, when the save it owed could not be written (err says why,
 * SPDF_FILE_CHANGED_ELSEWHERE included): the frontend can keep the changes (spdf_save_deferred_copy) and tell the
 * person. Without one the reason goes to stderr. */
typedef void (*spdf_core_save_failed_hook)(spdf_document* doc, const char* path, const char* err);
void spdf_core_set_save_failed_hook(spdf_core_save_failed_hook hook);

/* Reads up to `max_objects` more of the file's objects into memory, so the first save after opening finds them read
 * and does not stop to read them all at once (the reading can be spread over idle moments). 1 when every object is
 * read (or the document is not a PDF), 0 when more remain. */
int spdf_prepare_save_step(spdf_document* doc, int max_objects);

#ifdef __cplusplus
}
#endif

#pragma once
/* A save of a PDF's changes made in memory, written a moment later instead of at once (implemented in
 * spdf_core_open_hooks.h, inside shenzhen_pdf_core.c).
 *
 * Fill & Sign and Annotate change the document in memory, show the change, and owe the file a save. Writing it after
 * every change made a quick run of changes (Backspace five times, a few nudges) wait for one save each, and the first
 * save after opening a large PDF reads every object of the file first (MuPDF's pdf_check_document). Now the frontend
 * marks the save as owed and writes it once the changes rest; whatever closes the document first writes it then
 * (spdf_close), so a closed document never drops a change. Same threading contract as the document itself
 * (spdf_core_document.h): one thread at a time, the main thread for the app's document. */
#include "shenzhen_pdf_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The document's changes are owed to `path` (copied). A later call with another path replaces it. 0 on no memory. */
int spdf_defer_save(spdf_document* doc, const char* path);
/* The path a save is owed to, or NULL. */
const char* spdf_deferred_save_path(const spdf_document* doc);
/* Writes the owed save (spdf_save_document) and forgets it, failed or not. 1 when saved or nothing was owed. */
int spdf_save_deferred(spdf_document* doc, char* err, size_t err_len);

/* Reads up to `max_objects` more of the file's objects into memory, so the first save after opening finds them read
 * and does not stop to read them all at once (the reading can be spread over idle moments). 1 when every object is
 * read (or the document is not a PDF), 0 when more remain. */
int spdf_prepare_save_step(spdf_document* doc, int max_objects);

#ifdef __cplusplus
}
#endif

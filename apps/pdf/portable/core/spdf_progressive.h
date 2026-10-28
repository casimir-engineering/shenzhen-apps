/* spdf_progressive.h -- documents read while they download.
 *
 * A frontend downloading a document writes its bytes into the file at their own offsets (the file already has its
 * final size) and registers the path here with what has arrived. Until it unregisters, every spdf_open of that path,
 * on any thread, reads it through a MuPDF stream in progressive mode: a read of bytes that have not arrived asks the
 * frontend for them (the `want` callback, which must only queue the request and return) and fails with MuPDF's
 * "try later", so
 *   - an open fails until the trailer, cross-reference table and page tree have arrived (all of a linearized file's
 *     first part, or the end of any other file, which the frontend fetches first), and is retried;
 *   - a page renders only once every object it draws has arrived; a render that would have drawn without some of
 *     them (a font still missing) fails instead, so no page is ever shown wrong (spdf_progressive_render_incomplete);
 *   - a page's size is not known until its page object arrives.
 * Files are read at random, through the cross-reference table, whether linearized or not (see open_document in
 * spdf_progressive.c for why not MuPDF's front-to-back linearized reading), except when the bytes can only come in
 * order.
 *
 * Nothing here runs for a document that is not being downloaded: spdf_open asks the registry one locked question.
 * Thread-safe; the registry and each source take their own lock, never held across a callback.
 */
#ifndef SPDF_PROGRESSIVE_H
#define SPDF_PROGRESSIVE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct spdf_progressive spdf_progressive;

/* Asks for the bytes at `offset`: called on whatever thread hit them, with no lock held. */
typedef void (*spdf_progressive_want_fn)(void* user, int64_t offset);

/* Starts reading `path` (which must already be `length` bytes long) as a download. Returns NULL when the path is
 * already registered or the arguments are unusable. The returned reference belongs to the caller. */
spdf_progressive* spdf_progressive_register(const char* path, int64_t length, spdf_progressive_want_fn want, void* user);
/* Bytes [offset, offset + length) are now in the file. */
void spdf_progressive_add(spdf_progressive* source, int64_t offset, int64_t length);
/* The bytes arrive in order from the start (the server answers no range requests): documents opened from here on
 * read the file front to back (MuPDF's linearized reading) instead of at random. */
void spdf_progressive_set_sequential(spdf_progressive* source, int sequential);
/* The download stopped (a network error): reads of missing bytes fail outright instead of waiting. A later
 * spdf_progressive_resume() makes them wait again. */
void spdf_progressive_stop(spdf_progressive* source);
void spdf_progressive_resume(spdf_progressive* source);
/* The path reads as a plain file again for every later open (documents already open keep their stream, which now
 * finds every byte). Drops the caller's reference. */
void spdf_progressive_unregister(spdf_progressive* source);

int64_t spdf_progressive_length(spdf_progressive* source);
int64_t spdf_progressive_received(spdf_progressive* source);
int spdf_progressive_has(spdf_progressive* source, int64_t offset, int64_t length);
/* The first byte at or after `offset` that has not arrived, or the length when none is missing. */
int64_t spdf_progressive_next_missing(spdf_progressive* source, int64_t offset);
/* The end of the run of missing bytes that starts at `offset` (capped at the length). */
int64_t spdf_progressive_missing_end(spdf_progressive* source, int64_t offset);
/* Raised by every spdf_progressive_add: compare two readings to know whether anything arrived in between. */
uint64_t spdf_progressive_generation(spdf_progressive* source);

/* The file offsets of a downloading PDF's page objects that its page tree names so far (up to `max`), so a
 * frontend can fetch them together before a jump needs them (see kid_offsets in spdf_progressive.c). */
struct spdf_document;
int spdf_progressive_page_offsets(struct spdf_document* doc, int64_t* out, int max);

/* 1 while `path` is registered (the download is still going or stopped part way). */
int spdf_progressive_path_is_active(const char* path);

/* The arrived ranges as text ("<length>\n<start> <end>\n..."), for a frontend that keeps them beside the file so a
 * download that stopped (the app quit) carries on later; and the reverse, applied to a fresh registration. Returns
 * a malloc'd string / 1 on success. */
char* spdf_progressive_ranges_text(spdf_progressive* source);
int spdf_progressive_add_ranges_text(spdf_progressive* source, const char* text);
/* The length a ranges text was written for, or -1. */
int64_t spdf_progressive_ranges_text_length(const char* text);


#ifdef __cplusplus
}
#endif

#endif /* SPDF_PROGRESSIVE_H */

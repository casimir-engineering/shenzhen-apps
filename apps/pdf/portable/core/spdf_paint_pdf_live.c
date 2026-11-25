/* The PDF page canvases that are open, so that none outlives its document (docs/plans/annotate.md § 8 Core).
 *
 * A page canvas borrows the PDF's own context (spdf_paint_open_pdf_page), but the Mac app closes a tab's document
 * when the tab closes, while the tab itself (and the Annotate session it carries) can be released much later. The
 * canvas's history, layers and tiles were made with that context, so freeing them afterwards used a dead context.
 * spdf_close now tells us first: each canvas of the closing document frees what it made while the context is whole
 * and stays behind empty (no context, no PDF), which the frontend sees as "not open" and spdf_paint_close frees.
 *
 * The hook is installed when the first page canvas opens, never at launch. spdf_close runs on any thread (workers
 * have their own documents), so the list is guarded; a document with no canvas costs one lock and a short scan. */
#include "spdf_paint_model.h"
#include "spdf_core_document.h"

#include <pthread.h>
#include <stdlib.h>

static pthread_mutex_t live_lock = PTHREAD_MUTEX_INITIALIZER;
static spdf_paint_doc** live;
static int live_count, live_cap;

static void document_closing(spdf_document* pdf) {
    pthread_mutex_lock(&live_lock);
    for (int i = 0; i < live_count;) {
        spdf_paint_doc* doc = live[i];
        if (doc->pdf != pdf) { i++; continue; }
        spdf_paint_doc_release(doc);
        live[i] = live[--live_count];
    }
    pthread_mutex_unlock(&live_lock);
}

void spdf_paint_pdf_live_add(spdf_paint_doc* doc) {
    pthread_mutex_lock(&live_lock);
    if (live_count == live_cap) {
        int cap = live_cap ? live_cap * 2 : 16;
        spdf_paint_doc** grown = realloc(live, (size_t)cap * sizeof(*grown));
        if (grown) live = grown, live_cap = cap;
    }
    if (live_count < live_cap) live[live_count++] = doc;
    pthread_mutex_unlock(&live_lock);
    spdf_core_set_close_hook(document_closing);
}

void spdf_paint_pdf_live_remove(spdf_paint_doc* doc) {
    pthread_mutex_lock(&live_lock);
    for (int i = 0; i < live_count; i++)
        if (live[i] == doc) {
            live[i] = live[--live_count];
            break;
        }
    pthread_mutex_unlock(&live_lock);
}

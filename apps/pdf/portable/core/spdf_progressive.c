/* spdf_progressive.c -- documents read while they download (spdf_progressive.h). */
#include "spdf_progressive.h"
#include "spdf_core_document.h"

#include "mupdf/pdf.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct spdf_range {
    int64_t start, end; /* [start, end) */
} spdf_range;

struct spdf_progressive {
    pthread_mutex_t lock;
    int refs;          /* the frontend's, the registry's, one per open stream */
    int registered;
    int stopped;
    int sequential; /* the bytes come in order from the start (no range requests) */
    char* path;
    int64_t length;
    int64_t received;
    uint64_t generation;
    spdf_range* ranges; /* sorted, merged */
    int count, capacity;
    spdf_progressive_want_fn want;
    void* user;
    spdf_progressive* next; /* registry list */
};

static pthread_mutex_t registry_lock = PTHREAD_MUTEX_INITIALIZER;
static spdf_progressive* registry;
/* Size lookups ask for nothing: the reader lays out every page at open, and asking for each page's bytes then would
 * queue the whole document ahead of the page on screen. Renders ask. */
static _Thread_local int quiet;

static void set_quiet(int on) { quiet = on; }
static fz_document* open_document(fz_context* ctx, const char* path);

static void retain(spdf_progressive* source) {
    pthread_mutex_lock(&source->lock);
    source->refs++;
    pthread_mutex_unlock(&source->lock);
}

static void release(spdf_progressive* source) {
    if (!source) return;
    pthread_mutex_lock(&source->lock);
    int last = --source->refs == 0;
    pthread_mutex_unlock(&source->lock);
    if (!last) return;
    pthread_mutex_destroy(&source->lock);
    free(source->path);
    free(source->ranges);
    free(source);
}

spdf_progressive* spdf_progressive_register(const char* path, int64_t length, spdf_progressive_want_fn want,
                                           void* user) {
    if (!path || !*path || length <= 0) return NULL;
    spdf_progressive* source = (spdf_progressive*)calloc(1, sizeof(*source));
    if (!source) return NULL;
    source->path = strdup(path);
    if (!source->path) {
        free(source);
        return NULL;
    }
    pthread_mutex_init(&source->lock, NULL);
    source->refs = 2; /* the caller's and the registry's */
    source->registered = 1;
    source->length = length;
    source->want = want;
    source->user = user;
    pthread_mutex_lock(&registry_lock);
    for (spdf_progressive* s = registry; s; s = s->next) {
        if (strcmp(s->path, path) == 0) {
            pthread_mutex_unlock(&registry_lock);
            source->refs = 1;
            release(source);
            return NULL;
        }
    }
    static const spdf_core_progressive_hooks hooks = {open_document, set_quiet};
    spdf_core_set_progressive_hooks(&hooks);
    source->next = registry;
    registry = source;
    pthread_mutex_unlock(&registry_lock);
    return source;
}

void spdf_progressive_unregister(spdf_progressive* source) {
    if (!source) return;
    int was_registered = 0;
    pthread_mutex_lock(&registry_lock);
    for (spdf_progressive** link = &registry; *link; link = &(*link)->next) {
        if (*link == source) {
            *link = source->next;
            was_registered = 1;
            break;
        }
    }
    pthread_mutex_unlock(&registry_lock);
    pthread_mutex_lock(&source->lock);
    source->registered = 0;
    source->want = NULL; /* streams still open must never call back into a frontend that let go */
    pthread_mutex_unlock(&source->lock);
    if (was_registered) release(source); /* the registry's */
    release(source);                     /* the caller's */
}

static spdf_progressive* lookup(const char* path) {
    spdf_progressive* found = NULL;
    if (!path) return NULL;
    pthread_mutex_lock(&registry_lock);
    for (spdf_progressive* s = registry; s; s = s->next) {
        if (strcmp(s->path, path) == 0) {
            found = s;
            retain(found);
            break;
        }
    }
    pthread_mutex_unlock(&registry_lock);
    return found;
}

int spdf_progressive_path_is_active(const char* path) {
    if (!__atomic_load_n(&registry, __ATOMIC_ACQUIRE)) return 0; /* the common case: no download, no lock */
    spdf_progressive* source = lookup(path);
    release(source);
    return source != NULL;
}

void spdf_progressive_add(spdf_progressive* source, int64_t offset, int64_t length) {
    if (!source || length <= 0 || offset < 0) return;
    int64_t start = offset, end = offset + length;
    pthread_mutex_lock(&source->lock);
    if (end > source->length) end = source->length;
    if (start < end) {
        /* Merge into the sorted list: everything overlapping or touching [start, end) collapses into one range. */
        int first = 0;
        while (first < source->count && source->ranges[first].end < start) ++first;
        int last = first;
        while (last < source->count && source->ranges[last].start <= end) {
            if (source->ranges[last].start < start) start = source->ranges[last].start;
            if (source->ranges[last].end > end) end = source->ranges[last].end;
            ++last;
        }
        int removed = last - first;
        if (removed == 0 && source->count == source->capacity) {
            int capacity = source->capacity ? source->capacity * 2 : 16;
            spdf_range* grown = (spdf_range*)realloc(source->ranges, (size_t)capacity * sizeof(spdf_range));
            if (!grown) {
                pthread_mutex_unlock(&source->lock);
                return;
            }
            source->ranges = grown;
            source->capacity = capacity;
        }
        int64_t covered = 0;
        for (int i = first; i < last; ++i) covered += source->ranges[i].end - source->ranges[i].start;
        if (removed == 0) {
            memmove(source->ranges + first + 1, source->ranges + first,
                    (size_t)(source->count - first) * sizeof(spdf_range));
            source->count++;
        } else if (removed > 1) {
            memmove(source->ranges + first + 1, source->ranges + last, (size_t)(source->count - last) * sizeof(spdf_range));
            source->count -= removed - 1;
        }
        source->ranges[first].start = start;
        source->ranges[first].end = end;
        source->received += (end - start) - covered;
        source->generation++;
    }
    pthread_mutex_unlock(&source->lock);
}

void spdf_progressive_stop(spdf_progressive* source) {
    if (!source) return;
    pthread_mutex_lock(&source->lock);
    source->stopped = 1;
    pthread_mutex_unlock(&source->lock);
}

void spdf_progressive_set_sequential(spdf_progressive* source, int sequential) {
    if (!source) return;
    pthread_mutex_lock(&source->lock);
    source->sequential = sequential;
    pthread_mutex_unlock(&source->lock);
}

void spdf_progressive_resume(spdf_progressive* source) {
    if (!source) return;
    pthread_mutex_lock(&source->lock);
    source->stopped = 0;
    pthread_mutex_unlock(&source->lock);
}

int64_t spdf_progressive_length(spdf_progressive* source) { return source ? source->length : 0; }

int64_t spdf_progressive_received(spdf_progressive* source) {
    if (!source) return 0;
    pthread_mutex_lock(&source->lock);
    int64_t received = source->received;
    pthread_mutex_unlock(&source->lock);
    return received;
}

uint64_t spdf_progressive_generation(spdf_progressive* source) {
    if (!source) return 0;
    pthread_mutex_lock(&source->lock);
    uint64_t generation = source->generation;
    pthread_mutex_unlock(&source->lock);
    return generation;
}

/* The end of the arrived run containing `offset`, or `offset` when that byte has not arrived. Lock held. */
static int64_t run_end_locked(spdf_progressive* source, int64_t offset) {
    for (int i = 0; i < source->count; ++i) {
        if (source->ranges[i].start > offset) break;
        if (source->ranges[i].end > offset) return source->ranges[i].end;
    }
    return offset;
}

int spdf_progressive_has(spdf_progressive* source, int64_t offset, int64_t length) {
    if (!source) return 0;
    pthread_mutex_lock(&source->lock);
    int has = run_end_locked(source, offset) >= offset + length;
    pthread_mutex_unlock(&source->lock);
    return has;
}

int64_t spdf_progressive_next_missing(spdf_progressive* source, int64_t offset) {
    if (!source) return 0;
    pthread_mutex_lock(&source->lock);
    int64_t missing = offset < 0 ? 0 : offset;
    for (int64_t end; missing < source->length && (end = run_end_locked(source, missing)) > missing;) missing = end;
    if (missing > source->length) missing = source->length;
    pthread_mutex_unlock(&source->lock);
    return missing;
}

int64_t spdf_progressive_missing_end(spdf_progressive* source, int64_t offset) {
    if (!source) return 0;
    pthread_mutex_lock(&source->lock);
    int64_t end = source->length;
    for (int i = 0; i < source->count; ++i) {
        if (source->ranges[i].start > offset) {
            end = source->ranges[i].start;
            break;
        }
    }
    pthread_mutex_unlock(&source->lock);
    return end;
}

char* spdf_progressive_ranges_text(spdf_progressive* source) {
    if (!source) return NULL;
    pthread_mutex_lock(&source->lock);
    size_t cap = 32 + (size_t)source->count * 44;
    char* text = (char*)malloc(cap);
    if (text) {
        size_t n = (size_t)snprintf(text, cap, "%" PRId64 "\n", source->length);
        for (int i = 0; i < source->count && n < cap; ++i)
            n += (size_t)snprintf(text + n, cap - n, "%" PRId64 " %" PRId64 "\n", source->ranges[i].start,
                                  source->ranges[i].end);
    }
    pthread_mutex_unlock(&source->lock);
    return text;
}

int64_t spdf_progressive_ranges_text_length(const char* text) {
    char* end = NULL;
    if (!text) return -1;
    long long length = strtoll(text, &end, 10);
    return end != text && *end == '\n' && length > 0 ? (int64_t)length : -1;
}

int spdf_progressive_add_ranges_text(spdf_progressive* source, const char* text) {
    if (!source || spdf_progressive_ranges_text_length(text) != source->length) return 0;
    const char* line = strchr(text, '\n') + 1;
    while (*line) {
        char* end = NULL;
        long long start = strtoll(line, &end, 10);
        if (end == line || *end != ' ') return 0;
        const char* second = end + 1;
        long long stop = strtoll(second, &end, 10);
        if (end == second || *end != '\n' || start < 0 || stop <= start || stop > source->length) return 0;
        spdf_progressive_add(source, start, stop - start);
        line = end + 1;
    }
    return 1;
}

/* ---- the MuPDF stream ------------------------------------------------------------------------------------------ */

typedef struct reader {
    spdf_progressive* source;
    int fd;
    unsigned char buffer[64 * 1024];
} reader;

static int next_progressive(fz_context* ctx, fz_stream* stm, size_t max) {
    reader* r = (reader*)stm->state;
    spdf_progressive* source = r->source;
    (void)max;
    if (stm->pos >= source->length) return EOF;
    pthread_mutex_lock(&source->lock);
    int64_t end = run_end_locked(source, stm->pos);
    int stopped = source->stopped;
    spdf_progressive_want_fn want = source->want;
    void* user = source->user;
    pthread_mutex_unlock(&source->lock);
    if (end <= stm->pos) {
        if (stopped || !want) fz_throw(ctx, FZ_ERROR_FORMAT, "this part of the document did not download");
        if (!quiet) want(user, stm->pos);
        char where[64];
        snprintf(where, sizeof(where), "%" PRId64, (int64_t)stm->pos);
        fz_throw(ctx, FZ_ERROR_TRYLATER, "waiting for bytes at %s", where);
    }
    size_t n = (size_t)(end - stm->pos);
    if (n > sizeof(r->buffer)) n = sizeof(r->buffer);
    ssize_t got;
    do got = pread(r->fd, r->buffer, n, (off_t)stm->pos);
    while (got < 0 && errno == EINTR);
    if (got <= 0) fz_throw(ctx, FZ_ERROR_SYSTEM, "cannot read the downloading document: %s", strerror(errno));
    stm->rp = r->buffer;
    stm->wp = r->buffer + got;
    stm->pos += got;
    return *stm->rp++;
}

static void seek_progressive(fz_context* ctx, fz_stream* stm, int64_t offset, int whence) {
    reader* r = (reader*)stm->state;
    (void)ctx;
    int64_t target = whence == SEEK_END ? r->source->length + offset : offset;
    if (target < 0) target = 0;
    if (target > r->source->length) target = r->source->length;
    stm->pos = target;
    stm->rp = stm->wp = r->buffer;
}

static void drop_progressive(fz_context* ctx, void* state) {
    reader* r = (reader*)state;
    if (r->fd >= 0) close(r->fd);
    release(r->source);
    fz_free(ctx, r);
}

static fz_document* open_document(fz_context* ctx, const char* path) {
    if (!__atomic_load_n(&registry, __ATOMIC_ACQUIRE)) return NULL;
    spdf_progressive* source = lookup(path);
    if (!source) return NULL;
    fz_stream* stm = NULL;
    fz_document* doc = NULL;
    reader* r = NULL;
    fz_var(stm);
    fz_var(r);
    fz_try(ctx) {
        r = fz_malloc_struct(ctx, reader);
        r->source = source;
        r->fd = -1;
        r->fd = open(path, O_RDONLY | O_CLOEXEC);
        if (r->fd < 0) fz_throw(ctx, FZ_ERROR_SYSTEM, "cannot open the downloading document: %s", strerror(errno));
        stm = fz_new_stream(ctx, r, next_progressive, drop_progressive);
        r = NULL; /* the stream owns it, and the source reference, from here */
        stm->seek = seek_progressive;
        /* MuPDF's own progressive mode reads a linearized file front to back and finds an object only once the
         * reading has passed it; a page that names an object further on (qpdf puts the page tree near the end, and
         * every page's /Parent points at it) waits for nearly the whole file. Read at random instead: the trailer
         * and cross-reference table first (the end of the file; a linearized file's first-page table is at the
         * start), then each object where the table says it is, asking for those bytes. A linearized file keeps its
         * first page's objects at the start, so page 1 still comes first. Only a download that arrives in order
         * (no range requests) takes MuPDF's linear reading, which is the one way to show anything before its end. */
        pthread_mutex_lock(&source->lock);
        stm->progressive = source->sequential;
        pthread_mutex_unlock(&source->lock);
        doc = fz_open_document_with_stream(ctx, "application/pdf", stm);
    }
    fz_always(ctx) {
        fz_drop_stream(ctx, stm);
    }
    fz_catch(ctx) {
        if (r) {
            if (r->fd >= 0) close(r->fd);
            fz_free(ctx, r);
            release(source);
        }
        fz_rethrow(ctx);
    }
    return doc;
}

/* Where the page objects are, from the page tree's Kids (and the Kids of any intermediate node already in). MuPDF
 * finds page N by reading the type of every kid before it, so a jump to page 120 of a file whose page objects sit
 * between their images would otherwise fetch the document page by page: asking for all of them at once, a few
 * kilobytes each, makes the jump a handful of round trips. */
static void kid_offsets(fz_context* ctx, pdf_document* pdf, pdf_obj* node, int depth, int64_t* out, int max, int* n) {
    pdf_obj* kids = pdf_dict_get(ctx, node, PDF_NAME(Kids));
    int count = pdf_array_len(ctx, kids);
    for (int i = 0; i < count && *n < max; ++i) {
        pdf_obj* kid = pdf_array_get(ctx, kids, i);
        int num = pdf_to_num(ctx, kid);
        if (num <= 0 || num >= pdf_xref_len(ctx, pdf)) continue;
        pdf_xref_entry* entry = pdf_get_xref_entry_no_null(ctx, pdf, num);
        if (entry->type == 'n' && entry->ofs > 0) out[(*n)++] = entry->ofs;
        if (depth < 8 && entry->obj && pdf_name_eq(ctx, pdf_dict_get(ctx, entry->obj, PDF_NAME(Type)), PDF_NAME(Pages)))
            kid_offsets(ctx, pdf, entry->obj, depth + 1, out, max, n);
    }
}

int spdf_progressive_page_offsets(spdf_document* doc, int64_t* out, int max) {
    int n = 0;
    pdf_document* pdf = doc && doc->doc ? pdf_specifics(doc->ctx, doc->doc) : NULL;
    if (!pdf || !out || max <= 0) return 0;
    quiet = 1;
    fz_try(doc->ctx) {
        pdf_obj* root = pdf_dict_getp(doc->ctx, pdf_trailer(doc->ctx, pdf), "Root/Pages");
        kid_offsets(doc->ctx, pdf, root, 0, out, max, &n);
    }
    fz_always(doc->ctx) {
        quiet = 0;
    }
    fz_catch(doc->ctx) {
        fz_ignore_error(doc->ctx);
    }
    return n;
}

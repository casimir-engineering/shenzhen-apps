/* Shenzhen Friends client library: newline framing (PROTOCOL.md § Framing).
 *
 * Shared by the helper, this client and the fake helper, so the 8 MiB cap is enforced identically on both
 * sides of the socket. The reader never holds more than one over-cap line's worth of bytes: it checks the
 * pending line's length before copying anything in, so a peer streaming bytes without a newline cannot make it
 * allocate without bound. */

#include "client/szfriends_client.h"

#include <stdlib.h>
#include <string.h>

struct szfriends_line_reader {
    char *buffer;
    size_t capacity;
    size_t start;   /* first unconsumed byte */
    size_t length;  /* bytes from start that are buffered */
    size_t scanned; /* bytes from start already known to hold no newline */
    size_t pending; /* bytes after the last buffered newline: the line still waiting for its end */
    size_t max_frame;
    bool failed;    /* sticky: once a line was too large the stream cannot be resynchronised */
};

szfriends_line_reader *szfriends_line_reader_new(size_t max_frame_bytes) {
    szfriends_line_reader *reader;
    if (max_frame_bytes == 0) return NULL;
    reader = (szfriends_line_reader *)calloc(1, sizeof *reader);
    if (!reader) return NULL;
    reader->max_frame = max_frame_bytes;
    return reader;
}

void szfriends_line_reader_free(szfriends_line_reader *reader) {
    if (!reader) return;
    free(reader->buffer);
    free(reader);
}

/* Drops consumed bytes from the front so the buffer does not creep forward forever. */
static void compact(szfriends_line_reader *reader) {
    if (reader->start == 0) return;
    if (reader->length > 0) memmove(reader->buffer, reader->buffer + reader->start, reader->length);
    reader->start = 0;
}

static bool reserve(szfriends_line_reader *reader, size_t extra) {
    size_t needed;
    size_t capacity;
    char *grown;
    compact(reader);
    needed = reader->length + extra + 1; /* +1: room to NUL-terminate the last line in place */
    if (needed <= reader->capacity) return true;
    capacity = reader->capacity ? reader->capacity : 4096;
    while (capacity < needed) capacity *= 2;
    grown = (char *)realloc(reader->buffer, capacity);
    if (!grown) return false;
    reader->buffer = grown;
    reader->capacity = capacity;
    return true;
}

szfriends_status szfriends_line_reader_push(szfriends_line_reader *reader, const void *bytes, size_t length) {
    const char *input = (const char *)bytes;
    size_t pending;
    size_t offset = 0;

    if (!reader || (!bytes && length > 0)) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    if (reader->failed) return SZFRIENDS_ERR_FRAME_TOO_LARGE;
    if (length == 0) return SZFRIENDS_OK;

    /* Walk the input one line at a time, checking each pending line against the cap before buffering it. The
     * pending length is carried between pushes rather than rescanned, so an 8 MiB line arriving in 64 KiB
     * reads costs one pass, not one pass per read. */
    pending = reader->pending;
    while (offset < length) {
        const char *newline = (const char *)memchr(input + offset, '\n', length - offset);
        size_t segment = newline ? (size_t)(newline - (input + offset)) : length - offset;
        if (pending + segment > reader->max_frame) {
            reader->failed = true;
            return SZFRIENDS_ERR_FRAME_TOO_LARGE;
        }
        pending = newline ? 0 : pending + segment;
        offset += segment + (newline ? 1 : 0);
    }
    if (!reserve(reader, length)) return SZFRIENDS_ERR_NO_MEMORY;
    memcpy(reader->buffer + reader->start + reader->length, input, length);
    reader->length += length;
    reader->pending = pending;
    return SZFRIENDS_OK;
}

szfriends_status szfriends_line_reader_next(szfriends_line_reader *reader, const char **line, size_t *length) {
    if (!reader || !line) return SZFRIENDS_ERR_INVALID_ARGUMENT;
    *line = NULL;
    if (length) *length = 0;
    if (reader->failed) return SZFRIENDS_ERR_FRAME_TOO_LARGE;
    while (reader->length > 0) {
        char *base = reader->buffer + reader->start;
        char *newline = (char *)memchr(base + reader->scanned, '\n', reader->length - reader->scanned);
        size_t line_length;
        if (!newline) {
            reader->scanned = reader->length;
            return SZFRIENDS_OK;
        }
        line_length = (size_t)(newline - base);
        *newline = '\0';
        reader->start += line_length + 1;
        reader->length -= line_length + 1;
        reader->scanned = 0;
        if (reader->length == 0) reader->start = 0; /* the returned line stays valid: nothing moves until push */
        if (line_length == 0) continue;            /* empty lines are skipped */
        *line = base;
        if (length) *length = line_length;
        return SZFRIENDS_OK;
    }
    return SZFRIENDS_OK;
}

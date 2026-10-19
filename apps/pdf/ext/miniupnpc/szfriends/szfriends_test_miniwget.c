/* Shenzhen Friends' regression test for its local patch to getHTTPResponse (src/miniwget.c; VENDORED.md § Local
 * changes). Not part of upstream miniupnpc. Each case writes one HTTP answer into a socket pair, as the router's
 * HTTP server would, and checks what getHTTPResponse returns. friends-miniupnpc-check builds it with AddressSanitizer
 * and UndefinedBehaviorSanitizer, so the over-read the patch fixes crashes this test on an unpatched copy.
 *
 * The bounds below are the patch's: 16 KiB of headers and 64 KiB of content, far above any IGD's description or
 * SOAP answer, so a device on the LAN cannot make the helper read or allocate more. */

#include <miniwget_private.h>

#include <malloc/malloc.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

enum { MAX_HEADERS = 16384, MAX_CONTENT = 65536, REFUSED = -2 };

typedef struct {
    char *bytes;
    size_t length;
    size_t capacity;
} szf_buffer;

static int szf_failures;

static void szf_append(szf_buffer *buffer, const void *bytes, size_t length) {
    if (buffer->length + length > buffer->capacity) {
        size_t capacity = (buffer->length + length) * 2;
        char *grown = realloc(buffer->bytes, capacity);
        if (grown == NULL) abort();
        buffer->bytes = grown;
        buffer->capacity = capacity;
    }
    memcpy(buffer->bytes + buffer->length, bytes, length);
    buffer->length += length;
}

static void szf_append_text(szf_buffer *buffer, const char *text) {
    szf_append(buffer, text, strlen(text));
}

static void szf_append_repeated(szf_buffer *buffer, char byte, size_t count) {
    while (count-- > 0) szf_append(buffer, &byte, 1);
}

typedef struct {
    int descriptor;
    const szf_buffer *answer;
} szf_writer;

/* Writes the whole answer, then shuts the write side, as a server that answers and closes. A reader that gives up
 * early closes its end, which ends a blocked write with EPIPE (SIGPIPE is ignored in main). */
static void *szf_write_answer(void *context) {
    const szf_writer *writer = context;
    size_t sent = 0;
    while (sent < writer->answer->length) {
        ssize_t written = write(writer->descriptor, writer->answer->bytes + sent, writer->answer->length - sent);
        if (written <= 0) break;
        sent += (size_t)written;
    }
    shutdown(writer->descriptor, SHUT_WR);
    return NULL;
}

/* expected_length REFUSED means getHTTPResponse must refuse the answer: NULL, with size -1. */
static void szf_check(const char *name, const szf_buffer *answer, const char *expected, int expected_length) {
    int pair[2], size = 0, status = 0;
    pthread_t thread;
    szf_writer writer;
    char *content;
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) {
        fprintf(stderr, "%s: no socket pair\n", name);
        szf_failures++;
        return;
    }
    writer.descriptor = pair[0];
    writer.answer = answer;
    if (pthread_create(&thread, NULL, szf_write_answer, &writer) != 0) abort();
    content = getHTTPResponse(pair[1], &size, &status);
    close(pair[1]);
    pthread_join(thread, NULL);
    close(pair[0]);

    if (expected_length == REFUSED) {
        if (content != NULL || size != -1) {
            fprintf(stderr, "%s: expected a refusal, got %d bytes\n", name, size);
            szf_failures++;
        }
    } else if (size != expected_length || (expected_length > 0 && (content == NULL ||
               memcmp(content, expected, (size_t)expected_length) != 0)) || status != 200) {
        fprintf(stderr, "%s: expected %d bytes and status 200, got %d bytes and status %d\n", name, expected_length,
                size, status);
        szf_failures++;
    }
    if (content != NULL && malloc_size(content) > MAX_CONTENT) {
        fprintf(stderr, "%s: content buffer of %zu bytes, above %d\n", name, malloc_size(content), MAX_CONTENT);
        szf_failures++;
    }
    free(content);
}

static void szf_case(const char *name, const char *answer, const char *expected, int expected_length) {
    szf_buffer buffer = {NULL, 0, 0};
    szf_append_text(&buffer, answer);
    szf_check(name, &buffer, expected, expected_length);
    free(buffer.bytes);
}

/* Header names match exactly, so a header whose name is a prefix of one we act on counts for nothing. */
static void szf_test_header_names(void) {
    szf_case("Cont is not Content-Length", "HTTP/1.1 200 OK\r\nCont: 2\r\n\r\nabcdef", "abcdef", 6);
    szf_case("C is not Content-Length", "HTTP/1.1 200 OK\r\nC: 1\r\n\r\nabc", "abc", 3);
    szf_case("Trans is not Transfer-Encoding", "HTTP/1.1 200 OK\r\nTrans: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n",
             "3\r\nabc\r\n0\r\n\r\n", 13);
    szf_case("Content-Lengthy is not Content-Length", "HTTP/1.1 200 OK\r\nContent-Lengthy: 1\r\n\r\nabc", "abc", 3);
    szf_case("Content-Length in any case", "HTTP/1.1 200 OK\r\ncOnTeNt-LeNgTh: 3\r\n\r\nabcdef", "abc", 3);
    szf_case("Content-Length with trailing blanks", "HTTP/1.1 200 OK\r\nContent-Length: 3 \t\r\n\r\nabcdef", "abc", 3);
    szf_case("chunked still decoded",
             "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n", "abcde", 5);
    szf_case("LF-only line ends", "HTTP/1.1 200 OK\nContent-Length: 2\n\nabc", "ab", 2);
}

/* The over-read fixed by the patch: an empty Content-Length as the last header, filling the header buffer exactly,
 * so atoi skipped the CR LF CR LF and read on past the allocation. Same shape as the fuzz finding
 * (nat/fuzz/corpus/http/finding-content-length-overread.bin). An empty value is no Content-Length. */
static void szf_test_empty_length(void) {
    const char *head = "HTTP/1.1 200 OK\r\nX: ", *tail = "\r\nContent-Length:\r\n\r\n";
    szf_buffer buffer = {NULL, 0, 0};
    szf_append_text(&buffer, head);
    szf_append_repeated(&buffer, 'a', 2048 - strlen(head) - strlen(tail));
    szf_append_text(&buffer, tail);
    szf_check("empty Content-Length ending the buffer", &buffer, "", 0);
    free(buffer.bytes);
    szf_case("blank Content-Length", "HTTP/1.1 200 OK\r\nContent-Length:   \r\n\r\nabc", "abc", 3);
    szf_case("negative Content-Length", "HTTP/1.1 200 OK\r\nContent-Length: -5\r\n\r\nabc", "abc", 3);
}

static void szf_body_case(const char *name, const char *length_header, size_t body, int expected_length) {
    szf_buffer buffer = {NULL, 0, 0};
    szf_append_text(&buffer, "HTTP/1.1 200 OK\r\n");
    szf_append_text(&buffer, length_header);
    szf_append_text(&buffer, "\r\n");
    szf_append_repeated(&buffer, 'x', body);
    if (expected_length == REFUSED) {
        szf_check(name, &buffer, NULL, REFUSED);
    } else {
        szf_check(name, &buffer, buffer.bytes + buffer.length - body, expected_length);
    }
    free(buffer.bytes);
}

/* Content is bounded however its length is given: announced, chunked, or read until the server closes. */
static void szf_test_content_bound(void) {
    szf_body_case("announced 2,000,000,000 bytes", "Content-Length: 2000000000\r\n", 5000, REFUSED);
    szf_body_case("announced past every int", "Content-Length: 99999999999999999999999\r\n", 10, REFUSED);
    szf_body_case("announced at the bound", "Content-Length: 65536\r\n", MAX_CONTENT, MAX_CONTENT);
    szf_body_case("announced one past the bound", "Content-Length: 65537\r\n", MAX_CONTENT + 1, REFUSED);
    szf_body_case("unannounced at the bound", "", MAX_CONTENT, MAX_CONTENT);
    szf_body_case("unannounced past the bound", "", MAX_CONTENT + 1, REFUSED);

    szf_buffer buffer = {NULL, 0, 0};
    szf_append_text(&buffer, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
    for (int chunk = 0; chunk < 3; chunk++) {
        szf_append_text(&buffer, "8000\r\n");
        szf_append_repeated(&buffer, 'x', 0x8000);
        szf_append_text(&buffer, "\r\n");
    }
    szf_append_text(&buffer, "0\r\n\r\n");
    szf_check("chunks past the bound", &buffer, NULL, REFUSED);
    free(buffer.bytes);
}

/* The header section is bounded too: without it, a server sending header lines and never a blank line grows the
 * header buffer for as long as it keeps sending. */
static void szf_test_header_bound(void) {
    szf_buffer buffer = {NULL, 0, 0};
    szf_append_text(&buffer, "HTTP/1.1 200 OK\r\n");
    while (buffer.length <= MAX_HEADERS) szf_append_text(&buffer, "X-Pad: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n");
    szf_append_text(&buffer, "Content-Length: 2\r\n\r\nab");
    szf_check("headers past the bound", &buffer, NULL, REFUSED);
    free(buffer.bytes);

    buffer = (szf_buffer){NULL, 0, 0};
    szf_append_text(&buffer, "HTTP/1.1 200 OK\r\n");
    while (buffer.length < MAX_HEADERS - 64) szf_append_text(&buffer, "X-Pad: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n");
    szf_append_text(&buffer, "Content-Length: 2\r\n\r\nab");
    szf_check("headers within the bound", &buffer, "ab", 2);
    free(buffer.bytes);

    /* No blank line at all: refused once past the bound, not read until the server closes. */
    buffer = (szf_buffer){NULL, 0, 0};
    szf_append_text(&buffer, "HTTP/1.1 200 OK\r\n");
    while (buffer.length <= MAX_HEADERS + 4096) szf_append_text(&buffer, "X-Pad: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n");
    szf_check("headers never ending", &buffer, NULL, REFUSED);
    free(buffer.bytes);
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    szf_test_header_names();
    szf_test_empty_length();
    szf_test_content_bound();
    szf_test_header_bound();
    if (szf_failures > 0) {
        fprintf(stderr, "szfriends_test_miniwget: %d failure(s)\n", szf_failures);
        return 1;
    }
    printf("szfriends_test_miniwget passed\n");
    return 0;
}

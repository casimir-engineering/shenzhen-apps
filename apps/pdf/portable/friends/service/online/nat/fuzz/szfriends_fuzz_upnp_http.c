/* Fuzz target: miniupnpc's HTTP answer reading (getHTTPResponse in miniwget.c: headers, Content-Length, chunked
 * transfer coding), what every description fetch and SOAP call goes through. The input is written into one end of
 * a socket pair whose other end the parser reads, then the writer shuts down, as a server that answers and closes. */

#include <miniwget_private.h>

#include <stdint.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    int pair[2], buffer = 1 << 17, contentSize = 0, status = 0;
    void *content;
    if (size > 65536) return 0; /* fits the socket buffers below, so the write never blocks */
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) return 0;
    setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &buffer, sizeof buffer);
    setsockopt(pair[1], SOL_SOCKET, SO_RCVBUF, &buffer, sizeof buffer);
    if (size > 0 && write(pair[0], data, size) != (ssize_t)size) {
        close(pair[0]);
        close(pair[1]);
        return 0;
    }
    shutdown(pair[0], SHUT_WR);
    content = getHTTPResponse(pair[1], &contentSize, &status);
    free(content);
    close(pair[0]);
    close(pair[1]);
    return 0;
}

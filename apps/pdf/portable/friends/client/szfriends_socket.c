/* Shenzhen Friends client library: Unix socket helpers and version negotiation shared with the fake helper. */

#define _DARWIN_C_SOURCE 1 /* SO_NOSIGPIPE, getpeereid */

#include "client/szfriends_client_internal.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

int szfriends_socket_prepare(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    int one = 1;
    int buffer = 256 * 1024;
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) return -1;
#ifdef SO_NOSIGPIPE
    /* A helper that died mid-write must surface as EPIPE, not as a signal that kills the host app. */
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one) < 0) return -1;
#else
    (void)one;
#endif
    /* macOS gives Unix stream sockets 8 KiB buffers; a snapshot or a picture upload would then need hundreds of
     * partial writes. Best effort: the kernel may clamp it. */
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, sizeof buffer);
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, sizeof buffer);
    return 0;
}

bool szfriends_socket_peer_is_us(int fd) {
#if defined(__APPLE__) || defined(__FreeBSD__)
    uid_t uid;
    gid_t gid;
    if (getpeereid(fd, &uid, &gid) != 0) return false;
    return uid == geteuid();
#else
    struct ucred credentials;
    socklen_t length = sizeof credentials;
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) != 0) return false;
    return credentials.uid == geteuid();
#endif
}

int szfriends_socket_open_connected(const char *path, struct sockaddr_un *address, szfriends_status *status) {
    int fd;
    size_t length = strlen(path);
    *status = SZFRIENDS_OK;
    if (length >= sizeof address->sun_path) {
        *status = SZFRIENDS_ERR_PATH_TOO_LONG;
        return -1;
    }
    memset(address, 0, sizeof *address);
    address->sun_family = AF_UNIX;
    memcpy(address->sun_path, path, length + 1);
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        *status = SZFRIENDS_ERR_IO;
        return -1;
    }
    if (szfriends_socket_prepare(fd) != 0) {
        close(fd);
        *status = SZFRIENDS_ERR_IO;
        return -1;
    }
    /* A Unix socket connects or fails at once; EINPROGRESS/EAGAIN only mean a full backlog, so they are treated
     * like a missing listener and retried with backoff rather than watched for writability. */
    if (connect(fd, (struct sockaddr *)address, (socklen_t)sizeof *address) != 0) {
        int error = errno;
        close(fd);
        *status = (error == ENOENT || error == ECONNREFUSED || error == EAGAIN || error == EINPROGRESS ||
                   error == ENOTSOCK)
                      ? SZFRIENDS_ERR_NO_HELPER
                      : SZFRIENDS_ERR_IO;
        errno = error;
        return -1;
    }
    if (!szfriends_socket_peer_is_us(fd)) {
        close(fd);
        *status = SZFRIENDS_ERR_PEER_UID;
        return -1;
    }
    /* Before a single byte goes out: hello already names the app, and intents carry messages and file paths. */
    if (!szfriends_peer_signature_allowed(fd)) {
        close(fd);
        *status = SZFRIENDS_ERR_PEER_SIGNATURE;
        return -1;
    }
    return fd;
}

ssize_t szfriends_socket_write(int fd, const void *bytes, size_t length) {
#ifdef MSG_NOSIGNAL
    return send(fd, bytes, length, MSG_NOSIGNAL);
#else
    return send(fd, bytes, length, 0); /* SO_NOSIGPIPE set in szfriends_socket_prepare */
#endif
}

bool szfriends_negotiate(int helper_major, int helper_minor, int helper_min_major, int client_major,
                         int client_minor, int client_min_major, int *major_out, int *minor_out) {
    int major = helper_major < client_major ? helper_major : client_major;
    int floor = helper_min_major > client_min_major ? helper_min_major : client_min_major;
    int minor;
    if (major < floor || major < 1) return false;
    if (major == helper_major && major == client_major)
        minor = helper_minor < client_minor ? helper_minor : client_minor;
    else if (major == helper_major)
        minor = helper_minor; /* the client is a major ahead and speaks the helper's whole major */
    else
        minor = client_minor; /* the helper is a major ahead and speaks the client's whole major */
    if (major_out) *major_out = major;
    if (minor_out) *minor_out = minor;
    return true;
}

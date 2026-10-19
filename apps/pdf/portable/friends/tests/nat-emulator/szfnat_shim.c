// Puts a test process behind its emulated NAT (szfnat.h): a dylib the nat-emulator peer links, interposing sendto,
// recvfrom, sendmsg, connect and getpeername through dyld while SZFNAT_INSIDE_PORT names the NAT's inside port.
// Without that variable every call passes straight through.
//
//   - IPv4 UDP: each datagram goes to the NAT wrapped with its destination; what comes back is unwrapped and appears
//     to come from its real source. A datagram reaching the socket any other way is dropped, so nothing reaches a
//     host around its NAT. A socket's datagrams to itself (libjuice's wake-up) pass untouched.
//   - IPv4 TCP: connect() asks the NAT to dial out and then connects to the port it names; getpeername() reports the
//     endpoint the caller dialled.
//   - IPv6, connected UDP and UDP through sendmsg are refused with ENETUNREACH: this network has none of them, and
//     anything that went around the NAT would hide what the NAT does.

#include "szfnat.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define SZFNAT_DIALS_TRACKED 4096

static uint16_t gInsidePort;
static pthread_mutex_t gControlLock = PTHREAD_MUTEX_INITIALIZER;
static int gControl = -1;
static uint32_t gRequest;
// Per descriptor: the endpoint a TCP connect() named and the NAT port it really connected to.
static struct {
    struct sockaddr_in dialled;
    uint16_t contact;
} gDials[SZFNAT_DIALS_TRACKED];

__attribute__((constructor)) static void szfnat_shim_start(void) {
    const char *port = getenv(SZFNAT_ENV_INSIDE_PORT);
    long value = port ? strtol(port, NULL, 10) : 0;
    gInsidePort = value > 0 && value < 65536 ? (uint16_t)value : 0;
}

static int socket_type(int fd) {
    int type = 0;
    socklen_t length = sizeof type;
    return getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &length) == 0 ? type : -1;
}

static int own_address(int fd, struct sockaddr_in *own) {
    socklen_t length = sizeof *own;
    return getsockname(fd, (struct sockaddr *)own, &length) == 0 && own->sin_family == AF_INET;
}

static int is_loopback_port(const struct sockaddr_in *address, uint16_t port) {
    return address->sin_family == AF_INET && ntohl(address->sin_addr.s_addr) == INADDR_LOOPBACK &&
           ntohs(address->sin_port) == port;
}

// A datagram to the socket's own address (bound to 127.0.0.1 or to any address).
static int to_self(int fd, const struct sockaddr_in *destination) {
    struct sockaddr_in own;
    if (!own_address(fd, &own) || own.sin_port != destination->sin_port) return 0;
    return own.sin_addr.s_addr == destination->sin_addr.s_addr || own.sin_addr.s_addr == htonl(INADDR_ANY);
}

static struct sockaddr_in nat_address(void) {
    struct sockaddr_in address = {.sin_len = sizeof address, .sin_family = AF_INET, .sin_port = htons(gInsidePort)};
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    return address;
}

static ssize_t szfnat_sendto(int fd, const void *buffer, size_t length, int flags, const struct sockaddr *to,
                             socklen_t to_length) {
    if (gInsidePort == 0 || to == NULL || fd == gControl || socket_type(fd) != SOCK_DGRAM) {
        return sendto(fd, buffer, length, flags, to, to_length);
    }
    if (to->sa_family == AF_INET6) {
        errno = ENETUNREACH;
        return -1;
    }
    const struct sockaddr_in *destination = (const struct sockaddr_in *)(const void *)to;
    if (to->sa_family != AF_INET || to_length < sizeof *destination || to_self(fd, destination)) {
        return sendto(fd, buffer, length, flags, to, to_length);
    }
    if (length > SZFNAT_MAX_PAYLOAD) {
        errno = EMSGSIZE;
        return -1;
    }
    uint8_t packet[SZFNAT_HEADER_LENGTH + SZFNAT_MAX_PAYLOAD];
    memcpy(packet, SZFNAT_DATA_MAGIC, 4);
    memcpy(packet + 4, &destination->sin_addr.s_addr, 4);
    memcpy(packet + 8, &destination->sin_port, 2);
    memcpy(packet + SZFNAT_HEADER_LENGTH, buffer, length);
    struct sockaddr_in nat = nat_address();
    ssize_t sent = sendto(fd, packet, SZFNAT_HEADER_LENGTH + length, flags, (struct sockaddr *)&nat, sizeof nat);
    return sent < 0 ? sent : (ssize_t)length;
}

static ssize_t szfnat_recvfrom(int fd, void *buffer, size_t length, int flags, struct sockaddr *from,
                               socklen_t *from_length) {
    struct sockaddr_in own;
    // The control socket's own answers too: a sanitizer's recv() may come back through here.
    if (gInsidePort == 0 || fd == gControl || socket_type(fd) != SOCK_DGRAM || !own_address(fd, &own)) {
        return recvfrom(fd, buffer, length, flags, from, from_length);
    }
    uint8_t packet[SZFNAT_HEADER_LENGTH + SZFNAT_MAX_PAYLOAD];
    for (;;) {
        struct sockaddr_in source;
        socklen_t source_length = sizeof source;
        ssize_t received = recvfrom(fd, packet, sizeof packet, flags & ~MSG_PEEK, (struct sockaddr *)&source,
                                    &source_length);
        if (received < 0) return received;
        const uint8_t *payload = packet;
        size_t size = (size_t)received;
        if (is_loopback_port(&source, gInsidePort) && size >= SZFNAT_HEADER_LENGTH &&
            memcmp(packet, SZFNAT_DATA_MAGIC, 4) == 0) {
            memset(&source, 0, sizeof source);
            source.sin_len = sizeof source;
            source.sin_family = AF_INET;
            memcpy(&source.sin_addr.s_addr, packet + 4, 4);
            memcpy(&source.sin_port, packet + 8, 2);
            payload += SZFNAT_HEADER_LENGTH;
            size -= SZFNAT_HEADER_LENGTH;
        } else if (!(source.sin_family == AF_INET && source.sin_port == own.sin_port &&
                     ntohl(source.sin_addr.s_addr) == INADDR_LOOPBACK)) {
            continue; // around the NAT: lost
        }
        size_t copied = size < length ? size : length;
        memcpy(buffer, payload, copied);
        if (from != NULL && from_length != NULL) {
            socklen_t give = *from_length < sizeof source ? *from_length : (socklen_t)sizeof source;
            memcpy(from, &source, give);
            *from_length = sizeof source;
        }
        return (ssize_t)copied;
    }
}

static ssize_t szfnat_sendmsg(int fd, const struct msghdr *message, int flags) {
    if (gInsidePort != 0 && fd != gControl && message->msg_name != NULL && socket_type(fd) == SOCK_DGRAM) {
        const struct sockaddr *to = message->msg_name;
        if (to->sa_family == AF_INET6 ||
            (to->sa_family == AF_INET && !to_self(fd, (const struct sockaddr_in *)(const void *)to))) {
            errno = ENETUNREACH;
            return -1;
        }
    }
    return sendmsg(fd, message, flags);
}

// Asks the NAT to dial `destination` from the host's port; the port to connect to, or 0 when the dial was refused.
static uint16_t request_dial(uint16_t inside_port, const struct sockaddr_in *destination) {
    pthread_mutex_lock(&gControlLock);
    if (gControl < 0) {
        gControl = socket(AF_INET, SOCK_DGRAM, 0);
        struct sockaddr_in any = {.sin_len = sizeof any, .sin_family = AF_INET};
        any.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (gControl >= 0) bind(gControl, (struct sockaddr *)&any, sizeof any);
    }
    uint32_t request = htonl(++gRequest);
    uint16_t port = htons(inside_port), answer = 0;
    uint8_t packet[SZFNAT_CONTROL_LENGTH];
    memcpy(packet, SZFNAT_CONTROL_MAGIC, 4);
    memcpy(packet + 4, &request, 4);
    memcpy(packet + 8, &port, 2);
    memcpy(packet + 10, &destination->sin_addr.s_addr, 4);
    memcpy(packet + 14, &destination->sin_port, 2);
    struct sockaddr_in nat = nat_address();
    for (int attempt = 0; attempt < 3 && answer == 0 && gControl >= 0; attempt++) {
        sendto(gControl, packet, sizeof packet, 0, (struct sockaddr *)&nat, sizeof nat);
        struct pollfd wait = {.fd = gControl, .events = POLLIN};
        while (poll(&wait, 1, 300) > 0) {
            uint8_t reply[SZFNAT_ANSWER_LENGTH];
            ssize_t got = recv(gControl, reply, sizeof reply, 0);
            if (got != SZFNAT_ANSWER_LENGTH || memcmp(reply, SZFNAT_CONTROL_MAGIC, 4) != 0) continue;
            if (memcmp(reply + 4, &request, 4) != 0) continue; // an earlier request's late answer
            memcpy(&answer, reply + 8, 2);
            answer = ntohs(answer);
            attempt = 3;
            break;
        }
    }
    pthread_mutex_unlock(&gControlLock);
    return answer;
}

static int szfnat_connect(int fd, const struct sockaddr *to, socklen_t to_length) {
    if (gInsidePort == 0 || to == NULL || fd == gControl) return connect(fd, to, to_length);
    int type = socket_type(fd);
    if (to->sa_family == AF_INET6 && (type == SOCK_STREAM || type == SOCK_DGRAM)) {
        errno = ENETUNREACH;
        return -1;
    }
    const struct sockaddr_in *destination = (const struct sockaddr_in *)(const void *)to;
    if (to->sa_family != AF_INET || to_length < sizeof *destination || is_loopback_port(destination, gInsidePort)) {
        return connect(fd, to, to_length);
    }
    if (type == SOCK_DGRAM) {
        if (to_self(fd, destination)) return connect(fd, to, to_length);
        errno = ENETUNREACH;
        return -1;
    }
    if (type != SOCK_STREAM) return connect(fd, to, to_length);
    struct sockaddr_in own;
    if (!own_address(fd, &own) || own.sin_port == 0) {
        struct sockaddr_in any = nat_address();
        any.sin_port = 0;
        if (bind(fd, (struct sockaddr *)&any, sizeof any) != 0 || !own_address(fd, &own)) return -1;
    }
    uint16_t contact = request_dial(ntohs(own.sin_port), destination);
    if (contact == 0) {
        errno = ECONNREFUSED;
        return -1;
    }
    if (fd >= 0 && fd < SZFNAT_DIALS_TRACKED) {
        gDials[fd].dialled = *destination;
        gDials[fd].contact = contact;
    }
    struct sockaddr_in nat = nat_address();
    nat.sin_port = htons(contact);
    return connect(fd, (struct sockaddr *)&nat, sizeof nat);
}

static int szfnat_getpeername(int fd, struct sockaddr *address, socklen_t *length) {
    int result = getpeername(fd, address, length);
    if (result != 0 || gInsidePort == 0 || fd < 0 || fd >= SZFNAT_DIALS_TRACKED ||
        *length < sizeof(struct sockaddr_in)) {
        return result;
    }
    struct sockaddr_in *peer = (struct sockaddr_in *)(void *)address;
    if (gDials[fd].contact != 0 && is_loopback_port(peer, gDials[fd].contact)) *peer = gDials[fd].dialled;
    return result;
}

__attribute__((used)) static const struct {
    const void *replacement;
    const void *original;
} szfnat_interposers[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)szfnat_sendto, (const void *)sendto},
    {(const void *)szfnat_recvfrom, (const void *)recvfrom},
    {(const void *)szfnat_sendmsg, (const void *)sendmsg},
    {(const void *)szfnat_connect, (const void *)connect},
    {(const void *)szfnat_getpeername, (const void *)getpeername},
};

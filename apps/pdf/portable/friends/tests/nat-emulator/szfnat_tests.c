// friends-nat-emulator-check, first half: the emulator's own behaviour (szfnat.h). Inside hosts here speak the shim's
// wire directly; the last case runs this binary again behind a NAT, with the shim (which it links) switched on, and
// checks what a real program sees. Every wait is bounded (at most 3 s). The second half, the driver through every pair
// of NAT types, is SZFNATMatrix.m.

#include "szfnat.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static int failures;
#define EXPECT(condition, ...)                                                                                      \
    do {                                                                                                            \
        if (!(condition)) {                                                                                         \
            failures++;                                                                                             \
            fprintf(stderr, "%s:%d: expected %s ", __FILE__, __LINE__, #condition);                                 \
            fprintf(stderr, __VA_ARGS__);                                                                           \
            fprintf(stderr, "\n");                                                                                  \
        }                                                                                                           \
    } while (0)

static struct sockaddr_in loopback(uint16_t port) {
    struct sockaddr_in address = {.sin_len = sizeof address, .sin_family = AF_INET, .sin_port = htons(port)};
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    return address;
}

static int bound(int type, uint16_t *port) {
    int fd = socket(AF_INET, type, 0);
    struct sockaddr_in address = loopback(*port);
    socklen_t length = sizeof address;
    int on = 1;
    if (type == SOCK_STREAM) {
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, sizeof on);
    }
    if (bind(fd, (struct sockaddr *)&address, sizeof address) != 0) return -1;
    getsockname(fd, (struct sockaddr *)&address, &length);
    *port = ntohs(address.sin_port);
    return fd;
}

static int readable(int fd, int milliseconds) {
    struct pollfd wait = {.fd = fd, .events = POLLIN};
    return poll(&wait, 1, milliseconds) == 1;
}

// An inside host's datagram toward 127.0.0.1:port, through its NAT.
static void host_send(const szfnat_nat *nat, int fd, uint16_t port, const char *text) {
    uint8_t packet[64];
    struct sockaddr_in destination = loopback(port);
    memcpy(packet, SZFNAT_DATA_MAGIC, 4);
    memcpy(packet + 4, &destination.sin_addr.s_addr, 4);
    memcpy(packet + 8, &destination.sin_port, 2);
    size_t length = strlen(text);
    memcpy(packet + SZFNAT_HEADER_LENGTH, text, length);
    struct sockaddr_in inside = loopback(szfnat_inside_port(nat));
    sendto(fd, packet, SZFNAT_HEADER_LENGTH + length, 0, (struct sockaddr *)&inside, sizeof inside);
}

// What reached an inside host through its NAT within 500 ms: the source port, or 0.
static uint16_t host_receive(int fd) {
    uint8_t packet[256];
    if (!readable(fd, 500)) return 0;
    ssize_t got = recv(fd, packet, sizeof packet, 0);
    if (got < SZFNAT_HEADER_LENGTH || memcmp(packet, SZFNAT_DATA_MAGIC, 4) != 0) return 0;
    uint16_t port;
    memcpy(&port, packet + 8, 2);
    return ntohs(port);
}

// The source port of the next datagram a public socket gets within 500 ms, or 0.
static uint16_t public_receive(int fd) {
    uint8_t packet[256];
    struct sockaddr_in from;
    socklen_t length = sizeof from;
    if (!readable(fd, 500) || recvfrom(fd, packet, sizeof packet, 0, (struct sockaddr *)&from, &length) < 0) return 0;
    return ntohs(from.sin_port);
}

static void public_send(int fd, uint16_t port) {
    struct sockaddr_in to = loopback(port);
    sendto(fd, "x", 1, 0, (struct sockaddr *)&to, sizeof to);
}

static szfnat_config config(szfnat_mapping mapping, szfnat_filtering filtering, szfnat_allocation allocation) {
    return (szfnat_config){mapping, filtering, allocation, 30, 0, 0};
}

static void test_mapping(szfnat_world *world) {
    uint16_t s1 = 0, s2 = 0, h = 0, other = 0;
    int server1 = bound(SOCK_DGRAM, &s1), server2 = bound(SOCK_DGRAM, &s2);
    szfnat_config peer = config(SZFNAT_MAP_ENDPOINT_INDEPENDENT, SZFNAT_FILTER_ENDPOINT_INDEPENDENT,
                                SZFNAT_PORTS_SEQUENTIAL);
    szfnat_nat *far = szfnat_add(world, &peer);
    int farHost = bound(SOCK_DGRAM, &other);
    host_send(far, farHost, s1, "far");
    uint16_t farPublic = public_receive(server1);
    szfnat_mapping kinds[] = {SZFNAT_MAP_ENDPOINT_INDEPENDENT, SZFNAT_MAP_ADDRESS_DEPENDENT, SZFNAT_MAP_PORT_DEPENDENT};
    for (int k = 0; k < 3; k++) {
        szfnat_config c = config(kinds[k], SZFNAT_FILTER_ENDPOINT_INDEPENDENT, SZFNAT_PORTS_SEQUENTIAL);
        szfnat_nat *nat = szfnat_add(world, &c);
        h = 0;
        int host = bound(SOCK_DGRAM, &h);
        host_send(nat, host, s1, "a");
        host_send(nat, host, s2, "b");
        uint16_t p1 = public_receive(server1), p2 = public_receive(server2);
        host_send(nat, host, farPublic, "c");
        uint16_t p3 = host_receive(farHost);
        EXPECT(p1 != 0 && p2 != 0 && p3 != 0 && p1 != h, "mapping %d: ports %u %u %u", k, p1, p2, p3);
        // Two ports of one server are one address; the far NAT's public address is another.
        EXPECT((p1 == p2) == (kinds[k] != SZFNAT_MAP_PORT_DEPENDENT), "mapping %d: %u vs %u", k, p1, p2);
        EXPECT((p1 == p3) == (kinds[k] == SZFNAT_MAP_ENDPOINT_INDEPENDENT), "mapping %d: %u vs %u", k, p1, p3);
        close(host);
        szfnat_remove(world, nat);
    }
    szfnat_remove(world, far);
    close(farHost);
    close(server1);
    close(server2);
}

static void test_allocation(szfnat_world *world) {
    szfnat_allocation kinds[] = {SZFNAT_PORTS_SEQUENTIAL, SZFNAT_PORTS_RANDOM};
    for (int k = 0; k < 2; k++) {
        szfnat_config c = config(SZFNAT_MAP_PORT_DEPENDENT, SZFNAT_FILTER_PORT_DEPENDENT, kinds[k]);
        szfnat_nat *nat = szfnat_add(world, &c);
        uint16_t h = 0, ports[4] = {0}, servers[4] = {0};
        int host = bound(SOCK_DGRAM, &h), fds[4];
        int steps = 0;
        for (int i = 0; i < 4; i++) {
            fds[i] = bound(SOCK_DGRAM, &servers[i]);
            host_send(nat, host, servers[i], "p");
            ports[i] = public_receive(fds[i]);
            if (i > 0 && ports[i] == ports[i - 1] + 1) steps++;
        }
        EXPECT(kinds[k] == SZFNAT_PORTS_SEQUENTIAL ? steps == 3 : steps < 3, "allocation %d: %u %u %u %u", k,
               ports[0], ports[1], ports[2], ports[3]);
        EXPECT(szfnat_get_stats(world, nat).udp_mappings == 4, "four mappings");
        for (int i = 0; i < 4; i++) close(fds[i]);
        close(host);
        szfnat_remove(world, nat);
    }
}

static void test_filtering(szfnat_world *world) {
    szfnat_filtering kinds[] = {SZFNAT_FILTER_ENDPOINT_INDEPENDENT, SZFNAT_FILTER_ADDRESS_DEPENDENT,
                                SZFNAT_FILTER_PORT_DEPENDENT};
    szfnat_config open = config(SZFNAT_MAP_ENDPOINT_INDEPENDENT, SZFNAT_FILTER_ENDPOINT_INDEPENDENT,
                                SZFNAT_PORTS_SEQUENTIAL);
    for (int k = 0; k < 3; k++) {
        szfnat_config c = config(SZFNAT_MAP_ENDPOINT_INDEPENDENT, kinds[k], SZFNAT_PORTS_SEQUENTIAL);
        szfnat_nat *nat = szfnat_add(world, &c), *stranger = szfnat_add(world, &open);
        uint16_t s = 0, sameAddress = 0, h = 0, g = 0;
        int server = bound(SOCK_DGRAM, &s), neighbour = bound(SOCK_DGRAM, &sameAddress);
        int host = bound(SOCK_DGRAM, &h), strangerHost = bound(SOCK_DGRAM, &g);
        host_send(nat, host, s, "out");
        uint16_t mapped = public_receive(server);
        public_send(server, mapped);
        public_send(neighbour, mapped);  // the server's address, another port
        host_send(stranger, strangerHost, mapped, "in"); // another NAT's address
        int fromServer = 0, fromNeighbour = 0, fromStranger = 0;
        for (int i = 0; i < 3; i++) {
            uint16_t source = host_receive(host);
            if (source == s) fromServer = 1;
            else if (source == sameAddress) fromNeighbour = 1;
            else if (source != 0) fromStranger = 1;
        }
        EXPECT(fromServer, "filter %d: the server it sent to answers", k);
        EXPECT(fromNeighbour == (kinds[k] != SZFNAT_FILTER_PORT_DEPENDENT), "filter %d: same address", k);
        EXPECT(fromStranger == (kinds[k] == SZFNAT_FILTER_ENDPOINT_INDEPENDENT), "filter %d: stranger", k);
        EXPECT(szfnat_get_stats(world, nat).filtered == (size_t)k, "filter %d: %zu dropped", k,
               szfnat_get_stats(world, nat).filtered);
        close(server);
        close(neighbour);
        close(host);
        close(strangerHost);
        szfnat_remove(world, nat);
        szfnat_remove(world, stranger);
    }
}

static void test_timeout(szfnat_world *world) {
    szfnat_config c = config(SZFNAT_MAP_ENDPOINT_INDEPENDENT, SZFNAT_FILTER_ENDPOINT_INDEPENDENT,
                             SZFNAT_PORTS_SEQUENTIAL);
    c.mapping_timeout = 0.3;
    szfnat_nat *nat = szfnat_add(world, &c);
    uint16_t s = 0, h = 0;
    int server = bound(SOCK_DGRAM, &s), host = bound(SOCK_DGRAM, &h);
    host_send(nat, host, s, "1");
    uint16_t before = public_receive(server);
    usleep(150000);
    host_send(nat, host, s, "2"); // outbound traffic keeps it
    EXPECT(public_receive(server) == before, "refreshed by outbound traffic");
    usleep(700000);
    public_send(server, before);
    EXPECT(host_receive(host) == 0, "an expired mapping admits nothing");
    host_send(nat, host, s, "3");
    uint16_t after = public_receive(server);
    EXPECT(after != 0 && after != before && szfnat_get_stats(world, nat).expired == 1, "a new mapping: %u, %u",
           before, after);
    close(server);
    close(host);
    szfnat_remove(world, nat);
}

static void test_hairpin_and_private(szfnat_world *world) {
    for (int hairpin = 0; hairpin < 2; hairpin++) {
        szfnat_config c = config(SZFNAT_MAP_ENDPOINT_INDEPENDENT, SZFNAT_FILTER_ADDRESS_DEPENDENT,
                                 SZFNAT_PORTS_SEQUENTIAL);
        c.hairpinning = hairpin;
        szfnat_nat *nat = szfnat_add(world, &c);
        uint16_t s = 0, h1 = 0, h2 = 0;
        int server = bound(SOCK_DGRAM, &s), one = bound(SOCK_DGRAM, &h1), two = bound(SOCK_DGRAM, &h2);
        host_send(nat, one, s, "one");
        uint16_t p1 = public_receive(server);
        host_send(nat, two, s, "two");
        uint16_t p2 = public_receive(server);
        // To the NAT's own public address. One's mapping has never sent there, so its filter drops two's first
        // datagram; two's mapping has, by then, so one's datagram back gets through.
        host_send(nat, two, p1, "hello");
        host_send(nat, one, p2, "hello");
        uint16_t heard = host_receive(two);
        EXPECT(hairpin ? heard == p1 : heard == 0, "hairpin %d: %u from %u", hairpin, heard, p1);
        EXPECT(host_receive(one) == 0, "hairpin %d: filtered like any other address", hairpin);
        EXPECT(szfnat_get_stats(world, nat).hairpin_drops == (hairpin ? 0u : 2u), "hairpin %d drops", hairpin);
        host_send(nat, two, h1, "lan"); // a host on the same LAN, by its private address
        EXPECT(host_receive(one) == h2, "hosts behind one NAT meet directly");
        close(server);
        close(one);
        close(two);
        szfnat_remove(world, nat);
    }
    szfnat_config c = config(SZFNAT_MAP_ENDPOINT_INDEPENDENT, SZFNAT_FILTER_ENDPOINT_INDEPENDENT,
                             SZFNAT_PORTS_SEQUENTIAL);
    szfnat_nat *a = szfnat_add(world, &c), *b = szfnat_add(world, &c);
    uint16_t ha = 0, hb = 0, s = 0;
    int hostA = bound(SOCK_DGRAM, &ha), hostB = bound(SOCK_DGRAM, &hb), server = bound(SOCK_DGRAM, &s);
    host_send(b, hostB, s, "registers B's private port");
    public_receive(server);
    host_send(a, hostA, hb, "private");
    char raw[16];
    EXPECT(!readable(hostB, 300) || recv(hostB, raw, sizeof raw, 0) < 0, "a private address elsewhere is unreachable");
    EXPECT(szfnat_get_stats(world, a).unreachable == 1, "counted");
    close(hostA);
    close(hostB);
    close(server);
    szfnat_remove(world, a);
    szfnat_remove(world, b);
}

#pragma mark - TCP

// What the shim does for connect(): ask the NAT, then connect to the port it names. -1 when refused at once.
static int dial(const szfnat_nat *nat, int fd, uint16_t port) {
    uint16_t local = 0;
    struct sockaddr_in own;
    socklen_t length = sizeof own;
    getsockname(fd, (struct sockaddr *)&own, &length);
    local = own.sin_port;
    uint8_t request[SZFNAT_CONTROL_LENGTH], reply[SZFNAT_ANSWER_LENGTH];
    struct sockaddr_in destination = loopback(port), inside = loopback(szfnat_inside_port(nat));
    memcpy(request, SZFNAT_CONTROL_MAGIC, 4);
    memcpy(request + 4, "req1", 4);
    memcpy(request + 8, &local, 2);
    memcpy(request + 10, &destination.sin_addr.s_addr, 4);
    memcpy(request + 14, &destination.sin_port, 2);
    uint16_t control = 0;
    int ask = bound(SOCK_DGRAM, &control);
    sendto(ask, request, sizeof request, 0, (struct sockaddr *)&inside, sizeof inside);
    uint16_t contact = 0;
    if (readable(ask, 1000) && recv(ask, reply, sizeof reply, 0) == SZFNAT_ANSWER_LENGTH) {
        memcpy(&contact, reply + 8, 2);
    }
    close(ask);
    if (contact == 0) return -1;
    struct sockaddr_in to = loopback(ntohs(contact));
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    return connect(fd, (struct sockaddr *)&to, sizeof to) == 0 || errno == EINPROGRESS ? 0 : -1;
}

static int connected_within(int fd, int milliseconds) {
    struct pollfd wait = {.fd = fd, .events = POLLOUT};
    int error = 0;
    socklen_t length = sizeof error;
    return poll(&wait, 1, milliseconds) == 1 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 &&
           error == 0 && (wait.revents & POLLOUT);
}

// A host's TCP port behind `nat`, and the public port a listener sees it from.
static uint16_t tcp_public(const szfnat_nat *nat, int listener, uint16_t listening, uint16_t *local) {
    int fd = bound(SOCK_STREAM, local);
    if (dial(nat, fd, listening) != 0 || !connected_within(fd, 2000)) return 0;
    struct sockaddr_in peer;
    socklen_t length = sizeof peer;
    int accepted = readable(listener, 1000) ? accept(listener, (struct sockaddr *)&peer, &length) : -1;
    if (accepted >= 0) close(accepted);
    close(fd); // the mapping outlives it
    return accepted >= 0 ? ntohs(peer.sin_port) : 0;
}

static void test_tcp(szfnat_world *world) {
    // Independent mapping both sides; per-destination mapping on one; independent but dropping crossing SYNs.
    szfnat_mapping kinds[] = {SZFNAT_MAP_ENDPOINT_INDEPENDENT, SZFNAT_MAP_PORT_DEPENDENT,
                              SZFNAT_MAP_ENDPOINT_INDEPENDENT};
    for (int k = 0; k < 3; k++) {
        szfnat_config easy = config(SZFNAT_MAP_ENDPOINT_INDEPENDENT, SZFNAT_FILTER_PORT_DEPENDENT,
                                    SZFNAT_PORTS_SEQUENTIAL);
        szfnat_config c = config(kinds[k], SZFNAT_FILTER_PORT_DEPENDENT, SZFNAT_PORTS_SEQUENTIAL);
        c.drops_tcp_crossing = k == 2;
        szfnat_nat *a = szfnat_add(world, &c), *b = szfnat_add(world, &easy);
        uint16_t listening = 0, la = 0, lb = 0;
        int listener = bound(SOCK_STREAM, &listening);
        listen(listener, 8);
        uint16_t pa = tcp_public(a, listener, listening, &la), pb = tcp_public(b, listener, listening, &lb);
        EXPECT(pa != 0 && pb != 0 && pa != la && pb != lb, "tcp %d: mapped %u %u", k, pa, pb);
        // Nobody dialled: a SYN to the mapping is dropped, not answered.
        int stranger = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in target = loopback(pa);
        fcntl(stranger, F_SETFL, O_NONBLOCK);
        connect(stranger, (struct sockaddr *)&target, sizeof target);
        EXPECT(!connected_within(stranger, 400), "tcp %d: an unsolicited SYN gets nothing", k);
        close(stranger);
        int fa = bound(SOCK_STREAM, &la), fb = bound(SOCK_STREAM, &lb);
        EXPECT(dial(a, fa, pb) == 0 && dial(b, fb, pa) == 0, "tcp %d: both dial", k);
        int crossed = connected_within(fa, 2500) && connected_within(fb, 500);
        EXPECT(crossed == (k == 0), "tcp %d: simultaneous open %d", k, crossed);
        if (crossed) {
            char got[8] = {0};
            send(fa, "ping", 4, 0);
            EXPECT(readable(fb, 1000) && recv(fb, got, sizeof got, 0) == 4 && memcmp(got, "ping", 4) == 0,
                   "bytes cross the two NATs");
            EXPECT(szfnat_get_stats(world, a).tcp_spliced == 2, "tcp spliced");
        }
        close(fa);
        close(fb);
        close(listener);
        szfnat_remove(world, a);
        szfnat_remove(world, b);
    }
}

#pragma mark - Behind the shim

// The child: this binary with SZFNAT_INSIDE_PORT set. argv: --child <udp server port> <tcp listener port>.
static int child(uint16_t udpServer, uint16_t tcpServer) {
    uint16_t own = 0;
    int fd = bound(SOCK_DGRAM, &own);
    struct sockaddr_in server = loopback(udpServer), from;
    char text[64], got[64] = {0};
    snprintf(text, sizeof text, "%u", own);
    sendto(fd, text, strlen(text), 0, (struct sockaddr *)&server, sizeof server);
    socklen_t length = sizeof from;
    ssize_t n = readable(fd, 2000) ? recvfrom(fd, got, sizeof got - 1, 0, (struct sockaddr *)&from, &length) : -1;
    EXPECT(n > 0 && strncmp(got, "seen ", 5) == 0 && ntohs(from.sin_port) == udpServer,
           "the first datagram to arrive is the answer through the NAT, from the server: %s", got);
    EXPECT(n > 0 && atoi(got + 5) != own, "the server saw a mapped port, not %u", own);
    int six = socket(AF_INET6, SOCK_DGRAM, 0);
    struct sockaddr_in6 v6 = {.sin6_len = sizeof v6, .sin6_family = AF_INET6, .sin6_port = htons(udpServer)};
    v6.sin6_addr = in6addr_loopback;
    EXPECT(sendto(six, "x", 1, 0, (struct sockaddr *)&v6, sizeof v6) < 0 && errno == ENETUNREACH, "no IPv6");
    int stream = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in listener = loopback(tcpServer), peer;
    EXPECT(connect(stream, (struct sockaddr *)&listener, sizeof listener) == 0, "TCP through the NAT");
    length = sizeof peer;
    EXPECT(getpeername(stream, (struct sockaddr *)&peer, &length) == 0 && ntohs(peer.sin_port) == tcpServer,
           "getpeername names the listener: %u", ntohs(peer.sin_port));
    return failures == 0 ? 0 : 1;
}

static void test_shim(szfnat_world *world, const char *self) {
    szfnat_config c = config(SZFNAT_MAP_PORT_DEPENDENT, SZFNAT_FILTER_PORT_DEPENDENT, SZFNAT_PORTS_RANDOM);
    szfnat_nat *nat = szfnat_add(world, &c);
    uint16_t udp = 0, tcp = 0;
    int server = bound(SOCK_DGRAM, &udp), listener = bound(SOCK_STREAM, &tcp);
    listen(listener, 2);
    char udpText[8], tcpText[8], env[64];
    snprintf(udpText, sizeof udpText, "%u", udp);
    snprintf(tcpText, sizeof tcpText, "%u", tcp);
    snprintf(env, sizeof env, "%s=%u", SZFNAT_ENV_INSIDE_PORT, szfnat_inside_port(nat));
    char *argv[] = {(char *)self, "--child", udpText, tcpText, NULL}, *envp[] = {env, NULL};
    pid_t pid;
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT); // none of this world's sockets
    posix_spawn_file_actions_init(&actions);
    for (int fd = 0; fd <= 2; fd++) posix_spawn_file_actions_addinherit_np(&actions, fd);
    EXPECT(posix_spawn(&pid, self, &actions, &attributes, argv, envp) == 0, "the child starts");
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    char got[64] = {0};
    struct sockaddr_in from;
    socklen_t length = sizeof from;
    ssize_t n = readable(server, 3000) ? recvfrom(server, got, sizeof got - 1, 0, (struct sockaddr *)&from, &length)
                                       : -1;
    if (n > 0) {
        // First straight to the child's own port, around the NAT: lost. Then the answer to its mapping.
        struct sockaddr_in around = loopback((uint16_t)atoi(got));
        sendto(server, "around", 6, 0, (struct sockaddr *)&around, sizeof around);
        char answer[32];
        snprintf(answer, sizeof answer, "seen %u", ntohs(from.sin_port));
        sendto(server, answer, strlen(answer), 0, (struct sockaddr *)&from, length);
    }
    int accepted = readable(listener, 3000) ? accept(listener, NULL, NULL) : -1;
    int status = -1;
    waitpid(pid, &status, 0);
    EXPECT(n > 0 && accepted >= 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0, "the child's checks passed");
    if (accepted >= 0) close(accepted);
    close(server);
    close(listener);
    szfnat_remove(world, nat);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc == 4 && strcmp(argv[1], "--child") == 0) return child((uint16_t)atoi(argv[2]), (uint16_t)atoi(argv[3]));
    szfnat_world *world = szfnat_world_create();
    if (world == NULL) {
        fprintf(stderr, "szfnat_tests: no world\n");
        return 1;
    }
    struct {
        const char *name;
        void (*run)(szfnat_world *);
    } cases[] = {{"mapping", test_mapping},   {"allocation", test_allocation},
                 {"filtering", test_filtering}, {"timeout", test_timeout},
                 {"hairpin and private addresses", test_hairpin_and_private}, {"tcp", test_tcp}};
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        int before = failures;
        cases[i].run(world);
        printf("%s %s\n", failures == before ? "ok  " : "FAIL", cases[i].name);
    }
    int before = failures;
    test_shim(world, argv[0]);
    printf("%s behind the shim\n", failures == before ? "ok  " : "FAIL");
    szfnat_world_destroy(world);
    if (failures > 0) {
        fprintf(stderr, "szfnat_tests: %d failure(s)\n", failures);
        return 1;
    }
    printf("szfnat_tests passed\n");
    return 0;
}

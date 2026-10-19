// The NAT emulator's world and its UDP side (szfnat.h): one thread polls every NAT's inside socket and public
// mappings, translates what hosts send, filters what arrives, and ends idle mappings. TCP is in szfnat_tcp.c.

#include "szfnat_internal.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

// Sequential pools start somewhere in this range, so NATs of one run rarely meet in the port space.
static const uint16_t kSequentialLow = 20000, kSequentialSpan = 30000;
static const int kBindTries = 512;
static const int kBufferBytes = 4 << 20;

double szfnat_now(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}

struct sockaddr_in szfnat_loopback(uint16_t port) {
    struct sockaddr_in address = {.sin_len = sizeof address, .sin_family = AF_INET, .sin_port = htons(port)};
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    return address;
}

void szfnat_set_nonblocking(int fd) {
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
}

szfnat_endpoint szfnat_judge(const szfnat_world *world, const struct sockaddr_in *address, int tcp) {
    uint16_t port = ntohs(address->sin_port);
    szfnat_endpoint endpoint = {ntohl(address->sin_addr.s_addr), port};
    if (endpoint.address != INADDR_LOOPBACK) return endpoint;
    uint8_t public = tcp ? world->tcp_public[port] : world->udp_public[port];
    uint8_t inside = tcp ? world->tcp_inside[port] : world->udp_inside[port];
    if (public != 0) endpoint.address = (1ull << 32) | public; // that NAT's public address
    else if (inside != 0) endpoint.address = (2ull << 32) | inside; // a private address behind that NAT
    return endpoint;
}

int szfnat_keys_match(szfnat_mapping mapping, szfnat_endpoint a, szfnat_endpoint b) {
    switch (mapping) {
    case SZFNAT_MAP_ENDPOINT_INDEPENDENT: return 1;
    case SZFNAT_MAP_ADDRESS_DEPENDENT: return a.address == b.address;
    case SZFNAT_MAP_PORT_DEPENDENT: return a.address == b.address && a.port == b.port;
    }
    return 0;
}

// Whether no socket of this process or another holds `port` for `type` on loopback: a probe bound without reuse.
static int port_free(int type, uint16_t port) {
    int probe = socket(AF_INET, type, 0);
    if (probe < 0) return 0;
    struct sockaddr_in address = szfnat_loopback(port);
    int ok = bind(probe, (struct sockaddr *)&address, sizeof address) == 0;
    close(probe);
    return ok;
}

int szfnat_bind_public(szfnat_nat *nat, int type, uint16_t *port) {
    szfnat_world *world = nat->world;
    uint8_t *owners = type == SOCK_STREAM ? world->tcp_public : world->udp_public;
    uint16_t *next = type == SOCK_STREAM ? &nat->next_tcp_port : &nat->next_udp_port;
    for (int attempt = 0; attempt < kBindTries; attempt++) {
        uint16_t candidate;
        if (nat->config.allocation == SZFNAT_PORTS_SEQUENTIAL) {
            candidate = (*next)++;
            if (*next >= kSequentialLow + kSequentialSpan + 5000) *next = kSequentialLow;
        } else {
            candidate = (uint16_t)(1024 + arc4random_uniform(65536 - 1024));
        }
        if (owners[candidate] != 0 || world->udp_inside[candidate] != 0 || world->tcp_inside[candidate] != 0) continue;
        // TCP mappings share their port between the anchor and every outward dial (address and port reuse), so make
        // sure first that nobody else holds it: reuse would otherwise let two owners share one port.
        if (type == SOCK_STREAM && !port_free(type, candidate)) continue;
        int fd = socket(AF_INET, type, 0);
        if (fd < 0) return -1;
        int on = 1;
        if (type == SOCK_STREAM) {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, sizeof on);
        }
        struct sockaddr_in address = szfnat_loopback(candidate);
        if (bind(fd, (struct sockaddr *)&address, sizeof address) != 0) {
            close(fd);
            continue;
        }
        szfnat_set_nonblocking(fd);
        owners[candidate] = (uint8_t)(nat->index + 1);
        *port = candidate;
        return fd;
    }
    return -1;
}

void szfnat_poll_push(szfnat_world *world, int fd, short events, int kind, szfnat_nat *nat, void *owner) {
    if (world->poll_count == world->poll_capacity) {
        size_t capacity = world->poll_capacity ? world->poll_capacity * 2 : 256;
        world->polls = realloc(world->polls, capacity * sizeof *world->polls);
        world->entries = realloc(world->entries, capacity * sizeof *world->entries);
        world->poll_capacity = capacity;
    }
    world->polls[world->poll_count] = (struct pollfd){.fd = fd, .events = events};
    world->entries[world->poll_count] = (szfnat_poll_entry){kind, nat, owner};
    world->poll_count++;
}

#pragma mark - UDP

static void deliver_inside(szfnat_nat *nat, uint16_t inside_port, const struct sockaddr_in *source,
                           const uint8_t *payload, size_t length) {
    uint8_t *packet = nat->world->wrapped;
    if (length > SZFNAT_MAX_DATAGRAM - SZFNAT_HEADER_LENGTH) return;
    memcpy(packet, SZFNAT_DATA_MAGIC, 4);
    memcpy(packet + 4, &source->sin_addr.s_addr, 4);
    memcpy(packet + 8, &source->sin_port, 2);
    memcpy(packet + SZFNAT_HEADER_LENGTH, payload, length);
    struct sockaddr_in host = szfnat_loopback(inside_port);
    sendto(nat->inside_fd, packet, SZFNAT_HEADER_LENGTH + length, 0, (struct sockaddr *)&host, sizeof host);
}

static int admits(const szfnat_nat *nat, const szfnat_udp_map *map, szfnat_endpoint source) {
    if (nat->config.filtering == SZFNAT_FILTER_ENDPOINT_INDEPENDENT) return 1;
    for (size_t i = 0; i < map->permit_count; i++) {
        szfnat_endpoint permit = map->permits[i];
        if (permit.address == source.address &&
            (nat->config.filtering == SZFNAT_FILTER_ADDRESS_DEPENDENT || permit.port == source.port)) {
            return 1;
        }
    }
    return 0;
}

static void permit(szfnat_udp_map *map, szfnat_endpoint destination) {
    for (size_t i = 0; i < map->permit_count; i++) {
        if (map->permits[i].address == destination.address && map->permits[i].port == destination.port) return;
    }
    if (map->permit_count == map->permit_capacity) {
        map->permit_capacity = map->permit_capacity ? map->permit_capacity * 2 : 4;
        map->permits = realloc(map->permits, map->permit_capacity * sizeof *map->permits);
    }
    map->permits[map->permit_count++] = destination;
}

static szfnat_udp_map *udp_map_for(szfnat_nat *nat, uint16_t inside_port, szfnat_endpoint destination) {
    for (szfnat_udp_map *map = nat->udp; map != NULL; map = map->next) {
        if (map->inside_port == inside_port && szfnat_keys_match(nat->config.mapping, map->key, destination)) {
            return map;
        }
    }
    uint16_t port = 0;
    int fd = szfnat_bind_public(nat, SOCK_DGRAM, &port);
    if (fd < 0) return NULL;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &kBufferBytes, sizeof kBufferBytes);
    szfnat_udp_map *map = calloc(1, sizeof *map);
    map->fd = fd;
    map->public_port = port;
    map->inside_port = inside_port;
    map->key = destination;
    map->next = nat->udp;
    nat->udp = map;
    nat->stats.udp_mappings++;
    return map;
}

static szfnat_udp_map *udp_map_at(szfnat_nat *nat, uint16_t public_port) {
    for (szfnat_udp_map *map = nat->udp; map != NULL; map = map->next) {
        if (map->public_port == public_port) return map;
    }
    return NULL;
}

// A datagram a host sent toward `destination`: delivered on the LAN, translated and sent on, turned back by the
// hairpin, or lost on its way to a private address elsewhere.
static void udp_outbound(szfnat_nat *nat, uint16_t inside_port, const struct sockaddr_in *destination,
                         const uint8_t *payload, size_t length) {
    szfnat_world *world = nat->world;
    uint16_t port = ntohs(destination->sin_port);
    int loopback = ntohl(destination->sin_addr.s_addr) == INADDR_LOOPBACK;
    if (loopback && world->udp_inside[port] == nat->index + 1) {
        struct sockaddr_in source = szfnat_loopback(inside_port);
        deliver_inside(nat, port, &source, payload, length);
        return;
    }
    szfnat_endpoint judged = szfnat_judge(world, destination, 0);
    szfnat_udp_map *map = udp_map_for(nat, inside_port, judged);
    if (map == NULL) return;
    map->last_out = szfnat_now();
    permit(map, judged);
    if (loopback && world->udp_public[port] == nat->index + 1) {
        szfnat_udp_map *target = udp_map_at(nat, port);
        if (!nat->config.hairpinning) {
            nat->stats.hairpin_drops++;
            return;
        }
        struct sockaddr_in source = szfnat_loopback(map->public_port);
        if (target != NULL && admits(nat, target, szfnat_judge(world, &source, 0))) {
            nat->stats.hairpinned++;
            deliver_inside(nat, target->inside_port, &source, payload, length);
        } else nat->stats.filtered++;
        return;
    }
    if (loopback && world->udp_inside[port] != 0) {
        nat->stats.unreachable++;
        return;
    }
    nat->stats.udp_sent++;
    sendto(map->fd, payload, length, 0, (const struct sockaddr *)destination, sizeof *destination);
}

static void read_inside(szfnat_nat *nat) {
    uint8_t *buffer = nat->world->received;
    for (int i = 0; i < 4096; i++) {
        struct sockaddr_in from;
        socklen_t length = sizeof from;
        ssize_t received = recvfrom(nat->inside_fd, buffer, SZFNAT_MAX_DATAGRAM, 0, (struct sockaddr *)&from, &length);
        if (received < 0) return;
        if (from.sin_family != AF_INET || ntohl(from.sin_addr.s_addr) != INADDR_LOOPBACK) continue;
        if ((size_t)received >= SZFNAT_CONTROL_LENGTH && memcmp(buffer, SZFNAT_CONTROL_MAGIC, 4) == 0) {
            szfnat_tcp_control(nat, buffer, (size_t)received, &from);
            continue;
        }
        if ((size_t)received < SZFNAT_HEADER_LENGTH || memcmp(buffer, SZFNAT_DATA_MAGIC, 4) != 0) continue;
        uint16_t inside_port = ntohs(from.sin_port);
        nat->world->udp_inside[inside_port] = (uint8_t)(nat->index + 1);
        struct sockaddr_in destination = {.sin_len = sizeof destination, .sin_family = AF_INET};
        memcpy(&destination.sin_addr.s_addr, buffer + 4, 4);
        memcpy(&destination.sin_port, buffer + 8, 2);
        udp_outbound(nat, inside_port, &destination, buffer + SZFNAT_HEADER_LENGTH,
                     (size_t)received - SZFNAT_HEADER_LENGTH);
    }
}

static void read_mapping(szfnat_nat *nat, szfnat_udp_map *map) {
    uint8_t *buffer = nat->world->received;
    for (int i = 0; i < 4096; i++) {
        struct sockaddr_in from;
        socklen_t length = sizeof from;
        ssize_t received = recvfrom(map->fd, buffer, SZFNAT_MAX_DATAGRAM, 0, (struct sockaddr *)&from, &length);
        if (received < 0) return;
        if (from.sin_family != AF_INET) continue;
        if (!admits(nat, map, szfnat_judge(nat->world, &from, 0))) {
            nat->stats.filtered++;
            continue;
        }
        nat->stats.udp_admitted++;
        deliver_inside(nat, map->inside_port, &from, buffer, (size_t)received);
    }
}

static void free_udp_map(szfnat_world *world, szfnat_udp_map *map) {
    close(map->fd);
    world->udp_public[map->public_port] = 0;
    free(map->permits);
    free(map);
}

static void expire(szfnat_nat *nat, double now) {
    for (szfnat_udp_map **link = &nat->udp; *link != NULL;) {
        szfnat_udp_map *map = *link;
        if (now - map->last_out > nat->config.mapping_timeout) {
            *link = map->next;
            free_udp_map(nat->world, map);
            nat->stats.expired++;
        } else link = &map->next;
    }
    szfnat_tcp_expire(nat, now);
}

#pragma mark - The world's thread

static void handle(szfnat_world *world, size_t i) {
    short revents = world->polls[i].revents;
    szfnat_poll_entry entry = world->entries[i];
    if (revents == 0) return;
    if (entry.kind == SZFNAT_POLL_WAKE) {
        char drain[64];
        while (read(world->wake[0], drain, sizeof drain) > 0) {
        }
    } else if (entry.kind == SZFNAT_POLL_INSIDE) {
        read_inside(entry.nat);
    } else if (entry.kind == SZFNAT_POLL_UDP) {
        read_mapping(entry.nat, entry.owner);
    } else if (entry.kind == SZFNAT_POLL_FLOW) {
        szfnat_tcp_event(entry.nat, entry.owner, world->polls[i].fd, revents);
    }
}

static void *run(void *argument) {
    szfnat_world *world = argument;
    pthread_mutex_lock(&world->lock);
    while (!world->stopping) {
        world->poll_count = 0;
        szfnat_poll_push(world, world->wake[0], POLLIN, SZFNAT_POLL_WAKE, NULL, NULL);
        for (int n = 0; n < SZFNAT_MAX_NATS; n++) {
            szfnat_nat *nat = world->nats[n];
            if (nat == NULL) continue;
            szfnat_poll_push(world, nat->inside_fd, POLLIN, SZFNAT_POLL_INSIDE, nat, NULL);
            for (szfnat_udp_map *map = nat->udp; map != NULL; map = map->next) {
                szfnat_poll_push(world, map->fd, POLLIN, SZFNAT_POLL_UDP, nat, map);
            }
            szfnat_tcp_poll_add(nat);
        }
        unsigned generation = world->generation;
        size_t count = world->poll_count;
        pthread_mutex_unlock(&world->lock);
        int ready = poll(world->polls, (nfds_t)count, 50);
        pthread_mutex_lock(&world->lock);
        if (world->stopping || generation != world->generation) continue;
        for (size_t i = 0; ready > 0 && i < count; i++) handle(world, i);
        double now = szfnat_now();
        for (int n = 0; n < SZFNAT_MAX_NATS; n++) {
            if (world->nats[n] != NULL) expire(world->nats[n], now);
        }
    }
    pthread_mutex_unlock(&world->lock);
    return NULL;
}

static void wake(szfnat_world *world) {
    world->generation++;
    write(world->wake[1], "w", 1);
}

szfnat_world *szfnat_world_create(void) {
    szfnat_world *world = calloc(1, sizeof *world);
    if (world == NULL) return NULL;
    pthread_mutex_init(&world->lock, NULL);
    if (pipe(world->wake) != 0) {
        free(world);
        return NULL;
    }
    szfnat_set_nonblocking(world->wake[0]);
    szfnat_set_nonblocking(world->wake[1]);
    if (pthread_create(&world->thread, NULL, run, world) != 0) {
        close(world->wake[0]);
        close(world->wake[1]);
        free(world);
        return NULL;
    }
    return world;
}

static void close_nat(szfnat_world *world, szfnat_nat *nat) {
    while (nat->udp != NULL) {
        szfnat_udp_map *map = nat->udp;
        nat->udp = map->next;
        free_udp_map(world, map);
    }
    szfnat_tcp_close_all(nat);
    close(nat->inside_fd);
    uint8_t owner = (uint8_t)(nat->index + 1);
    for (size_t port = 0; port < 65536; port++) {
        if (world->udp_inside[port] == owner) world->udp_inside[port] = 0;
        if (world->tcp_inside[port] == owner) world->tcp_inside[port] = 0;
    }
    world->nats[nat->index] = NULL;
    free(nat);
}

void szfnat_world_destroy(szfnat_world *world) {
    if (world == NULL) return;
    pthread_mutex_lock(&world->lock);
    world->stopping = 1;
    wake(world);
    pthread_mutex_unlock(&world->lock);
    pthread_join(world->thread, NULL);
    for (int n = 0; n < SZFNAT_MAX_NATS; n++) {
        if (world->nats[n] != NULL) close_nat(world, world->nats[n]);
    }
    close(world->wake[0]);
    close(world->wake[1]);
    free(world->polls);
    free(world->entries);
    pthread_mutex_destroy(&world->lock);
    free(world);
}

szfnat_nat *szfnat_add(szfnat_world *world, const szfnat_config *config) {
    pthread_mutex_lock(&world->lock);
    int index = -1;
    for (int n = 0; n < SZFNAT_MAX_NATS && index < 0; n++) {
        if (world->nats[n] == NULL) index = n;
    }
    int fd = index >= 0 ? socket(AF_INET, SOCK_DGRAM, 0) : -1;
    struct sockaddr_in address = szfnat_loopback(0);
    socklen_t length = sizeof address;
    if (fd < 0 || bind(fd, (struct sockaddr *)&address, sizeof address) != 0 ||
        getsockname(fd, (struct sockaddr *)&address, &length) != 0) {
        if (fd >= 0) close(fd);
        pthread_mutex_unlock(&world->lock);
        return NULL;
    }
    szfnat_set_nonblocking(fd);
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &kBufferBytes, sizeof kBufferBytes);
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &kBufferBytes, sizeof kBufferBytes);
    szfnat_nat *nat = calloc(1, sizeof *nat);
    nat->world = world;
    nat->index = index;
    nat->config = *config;
    nat->inside_fd = fd;
    nat->inside_port = ntohs(address.sin_port);
    nat->next_udp_port = nat->next_tcp_port = (uint16_t)(kSequentialLow + arc4random_uniform(kSequentialSpan));
    world->nats[index] = nat;
    wake(world);
    pthread_mutex_unlock(&world->lock);
    return nat;
}

uint16_t szfnat_inside_port(const szfnat_nat *nat) {
    return nat->inside_port;
}

void szfnat_remove(szfnat_world *world, szfnat_nat *nat) {
    pthread_mutex_lock(&world->lock);
    close_nat(world, nat);
    wake(world);
    pthread_mutex_unlock(&world->lock);
}

szfnat_stats szfnat_get_stats(szfnat_world *world, const szfnat_nat *nat) {
    pthread_mutex_lock(&world->lock);
    szfnat_stats stats = nat->stats;
    pthread_mutex_unlock(&world->lock);
    return stats;
}

// The NAT emulator's TCP side (szfnat.h). A host's connect() arrives as a control datagram; the NAT dials out from a
// public mapping chosen by its mapping rule and answers with a port where the host's own SYN is held (bound, never
// listening, so macOS drops that SYN and the host stays in SYN-SENT). When the outward dial completes, which between
// two NATs means their SYNs crossed, the NAT dials the host back from that port: the two SYNs cross again and the
// host's connect() completes exactly when the path end to end exists. Then the NAT splices the two legs.
//
// Inbound TCP is never accepted by a listener: each public port keeps an anchor socket bound and not listening, so a
// SYN nobody dialled toward is dropped silently, as most NATs drop unsolicited SYNs; only the crossing SYN of an
// outward dial gets through, unless either NAT is set to drop crossing SYNs as well (drops_tcp_crossing). TCP never
// hairpins here. A dial toward a private address elsewhere stays silent.

#include "szfnat_internal.h"

#include <arpa/inet.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

// How long a dial may take before the NAT forgets it; the host redials after 1 s of silence anyway.
static const double kFlowDeadline = 3;

static void kill_flow(szfnat_flow *flow) {
    if (flow->outside >= 0) close(flow->outside);
    if (flow->inside >= 0) close(flow->inside);
    flow->outside = flow->inside = -1;
    flow->dead = 1;
}

static szfnat_tcp_map *tcp_map_for(szfnat_nat *nat, uint16_t inside_port, szfnat_endpoint destination) {
    for (szfnat_tcp_map *map = nat->tcp; map != NULL; map = map->next) {
        if (map->inside_port == inside_port && szfnat_keys_match(nat->config.mapping, map->key, destination)) {
            return map;
        }
    }
    uint16_t port = 0;
    int anchor = szfnat_bind_public(nat, SOCK_STREAM, &port);
    if (anchor < 0) return NULL;
    szfnat_tcp_map *map = calloc(1, sizeof *map);
    map->anchor = anchor;
    map->public_port = port;
    map->inside_port = inside_port;
    map->key = destination;
    map->next = nat->tcp;
    nat->tcp = map;
    nat->stats.tcp_mappings++;
    return map;
}

// A socket bound to a fresh loopback port, never listening: the host's SYN to it waits there.
static int contact_socket(uint16_t *port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    struct sockaddr_in address = szfnat_loopback(0);
    socklen_t length = sizeof address;
    if (bind(fd, (struct sockaddr *)&address, sizeof address) != 0 ||
        getsockname(fd, (struct sockaddr *)&address, &length) != 0) {
        close(fd);
        return -1;
    }
    szfnat_set_nonblocking(fd);
    *port = ntohs(address.sin_port);
    return fd;
}

static int dial_from(uint16_t local_port, const struct sockaddr_in *destination, int reuse, int *fd_out) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    if (reuse) setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, sizeof on);
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    szfnat_set_nonblocking(fd);
    struct sockaddr_in local = szfnat_loopback(local_port);
    if (bind(fd, (struct sockaddr *)&local, sizeof local) != 0) {
        close(fd);
        return -1;
    }
    *fd_out = fd;
    if (connect(fd, (const struct sockaddr *)destination, sizeof *destination) == 0) return 1;
    return errno == EINPROGRESS ? 0 : -1;
}

static void answer(szfnat_nat *nat, const uint8_t *request, const struct sockaddr_in *from, uint16_t port) {
    uint8_t reply[SZFNAT_ANSWER_LENGTH];
    memcpy(reply, SZFNAT_CONTROL_MAGIC, 4);
    memcpy(reply + 4, request + 4, 4);
    uint16_t network = htons(port);
    memcpy(reply + 8, &network, 2);
    sendto(nat->inside_fd, reply, sizeof reply, 0, (const struct sockaddr *)from, sizeof *from);
}

static void cross_inside(szfnat_nat *nat, szfnat_flow *flow) {
    // The outward leg is up: cross the host's held SYN from the contact port.
    struct sockaddr_in host = szfnat_loopback(flow->inside_port);
    int contact = flow->inside;
    if (connect(contact, (struct sockaddr *)&host, sizeof host) == 0) {
        flow->state = SZFNAT_FLOW_SPLICED;
        nat->stats.tcp_spliced++;
    } else if (errno == EINPROGRESS) {
        flow->state = SZFNAT_FLOW_INSIDE;
    } else kill_flow(flow);
}

void szfnat_tcp_control(szfnat_nat *nat, const uint8_t *request, size_t length, const struct sockaddr_in *from) {
    if (length < SZFNAT_CONTROL_LENGTH) return;
    szfnat_world *world = nat->world;
    uint16_t inside_port;
    struct sockaddr_in destination = {.sin_len = sizeof destination, .sin_family = AF_INET};
    memcpy(&inside_port, request + 8, 2);
    inside_port = ntohs(inside_port);
    memcpy(&destination.sin_addr.s_addr, request + 10, 4);
    memcpy(&destination.sin_port, request + 14, 2);
    world->tcp_inside[inside_port] = (uint8_t)(nat->index + 1);
    // A redial replaces the host's earlier dial toward the same endpoint, which it has given up on.
    for (szfnat_flow *flow = nat->flows; flow != NULL; flow = flow->next) {
        if (!flow->dead && flow->state != SZFNAT_FLOW_SPLICED && flow->inside_port == inside_port &&
            flow->destination.sin_addr.s_addr == destination.sin_addr.s_addr &&
            flow->destination.sin_port == destination.sin_port) {
            kill_flow(flow);
        }
    }
    szfnat_endpoint judged = szfnat_judge(world, &destination, 1);
    szfnat_tcp_map *map = tcp_map_for(nat, inside_port, judged);
    uint16_t contact_port = 0;
    int contact = map ? contact_socket(&contact_port) : -1;
    if (contact < 0) {
        answer(nat, request, from, 0);
        return;
    }
    map->last_used = szfnat_now();
    szfnat_flow *flow = calloc(1, sizeof *flow);
    flow->outside = -1;
    flow->inside = contact;
    flow->inside_port = inside_port;
    flow->contact_port = contact_port;
    flow->destination = destination;
    flow->deadline = szfnat_now() + kFlowDeadline;
    flow->map = map;
    flow->next = nat->flows;
    nat->flows = flow;
    uint16_t port = ntohs(destination.sin_port);
    int loopback = ntohl(destination.sin_addr.s_addr) == INADDR_LOOPBACK;
    // A NAT that drops crossing SYNs, on either side, stops a simultaneous open between two NATs.
    uint8_t far = loopback ? world->tcp_public[port] : 0;
    int crossing = far != 0 && far != nat->index + 1;
    int dropped = crossing && (nat->config.drops_tcp_crossing ||
                               (world->nats[far - 1] != NULL && world->nats[far - 1]->config.drops_tcp_crossing));
    if (loopback && (world->tcp_inside[port] != 0 || far == nat->index + 1 || dropped)) {
        // A private address elsewhere, this NAT's own public address (no TCP hairpin), or a crossing one of the
        // NATs drops: nothing answers.
        if (world->tcp_inside[port] != 0) nat->stats.unreachable++;
        flow->state = SZFNAT_FLOW_SILENT;
        answer(nat, request, from, contact_port);
        return;
    }
    int dialled = dial_from(map->public_port, &destination, 1, &flow->outside);
    if (dialled < 0) {
        // Refused at once: the reset comes back through the NAT.
        kill_flow(flow);
        answer(nat, request, from, 0);
        return;
    }
    flow->state = SZFNAT_FLOW_DIALLING;
    answer(nat, request, from, contact_port);
    if (dialled == 1) cross_inside(nat, flow);
}

static int pipe_space(const szfnat_pipe *pipe) {
    return !pipe->eof && pipe->end < sizeof pipe->bytes;
}

void szfnat_tcp_poll_add(szfnat_nat *nat) {
    szfnat_world *world = nat->world;
    for (szfnat_flow *flow = nat->flows; flow != NULL; flow = flow->next) {
        if (flow->dead) continue;
        if (flow->state == SZFNAT_FLOW_DIALLING) {
            szfnat_poll_push(world, flow->outside, POLLOUT, SZFNAT_POLL_FLOW, nat, flow);
        } else if (flow->state == SZFNAT_FLOW_INSIDE) {
            szfnat_poll_push(world, flow->inside, POLLOUT, SZFNAT_POLL_FLOW, nat, flow);
        } else if (flow->state == SZFNAT_FLOW_SPLICED) {
            short outside = (short)((pipe_space(&flow->out_to_in) ? POLLIN : 0) |
                                    (flow->in_to_out.end > flow->in_to_out.start ? POLLOUT : 0));
            short inside = (short)((pipe_space(&flow->in_to_out) ? POLLIN : 0) |
                                   (flow->out_to_in.end > flow->out_to_in.start ? POLLOUT : 0));
            if (outside) szfnat_poll_push(world, flow->outside, outside, SZFNAT_POLL_FLOW, nat, flow);
            if (inside) szfnat_poll_push(world, flow->inside, inside, SZFNAT_POLL_FLOW, nat, flow);
        }
    }
}

// Moves what `from` has into `pipe`, and what `pipe` holds into `to`. NO on an error.
static int pump(int from, szfnat_pipe *pipe, int to, int *shut) {
    if (pipe_space(pipe)) {
        ssize_t got = read(from, pipe->bytes + pipe->end, sizeof pipe->bytes - pipe->end);
        if (got > 0) pipe->end += (size_t)got;
        else if (got == 0) pipe->eof = 1;
        else if (errno != EAGAIN && errno != EINTR) return 0;
    }
    if (pipe->end > pipe->start) {
        ssize_t put = send(to, pipe->bytes + pipe->start, pipe->end - pipe->start, 0);
        if (put > 0) pipe->start += (size_t)put;
        else if (put < 0 && errno != EAGAIN && errno != EINTR) return 0;
        if (pipe->start == pipe->end) pipe->start = pipe->end = 0;
    }
    if (pipe->eof && pipe->start == pipe->end && !*shut) {
        shutdown(to, SHUT_WR);
        *shut = 1;
    }
    return 1;
}

static int connect_error(int fd) {
    int error = 0;
    socklen_t length = sizeof error;
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) != 0) return errno;
    return error;
}

void szfnat_tcp_event(szfnat_nat *nat, szfnat_flow *flow, int fd, short revents) {
    if (flow->dead) return;
    if (flow->state == SZFNAT_FLOW_DIALLING && fd == flow->outside) {
        if ((revents & (POLLOUT | POLLERR | POLLHUP)) == 0) return;
        if (connect_error(flow->outside) != 0) kill_flow(flow);
        else cross_inside(nat, flow);
        return;
    }
    if (flow->state == SZFNAT_FLOW_INSIDE && fd == flow->inside) {
        if (connect_error(flow->inside) != 0) {
            kill_flow(flow);
            return;
        }
        flow->state = SZFNAT_FLOW_SPLICED;
        nat->stats.tcp_spliced++;
        return;
    }
    if (flow->state != SZFNAT_FLOW_SPLICED) return;
    int ok = pump(flow->outside, &flow->out_to_in, flow->inside, &flow->shut_inside) &&
             pump(flow->inside, &flow->in_to_out, flow->outside, &flow->shut_outside);
    flow->map->last_used = szfnat_now();
    if (!ok || (flow->shut_inside && flow->shut_outside)) kill_flow(flow);
}

void szfnat_tcp_expire(szfnat_nat *nat, double now) {
    for (szfnat_flow **link = &nat->flows; *link != NULL;) {
        szfnat_flow *flow = *link;
        if (!flow->dead && flow->state != SZFNAT_FLOW_SPLICED && now > flow->deadline) kill_flow(flow);
        if (flow->dead) {
            *link = flow->next;
            free(flow);
        } else link = &flow->next;
    }
    for (szfnat_tcp_map **link = &nat->tcp; *link != NULL;) {
        szfnat_tcp_map *map = *link;
        int busy = 0;
        for (szfnat_flow *flow = nat->flows; flow != NULL && !busy; flow = flow->next) busy = flow->map == map;
        if (!busy && now - map->last_used > nat->config.mapping_timeout) {
            *link = map->next;
            close(map->anchor);
            nat->world->tcp_public[map->public_port] = 0;
            free(map);
            nat->stats.expired++;
        } else link = &map->next;
    }
}

void szfnat_tcp_close_all(szfnat_nat *nat) {
    while (nat->flows != NULL) {
        szfnat_flow *flow = nat->flows;
        nat->flows = flow->next;
        kill_flow(flow);
        free(flow);
    }
    while (nat->tcp != NULL) {
        szfnat_tcp_map *map = nat->tcp;
        nat->tcp = map->next;
        close(map->anchor);
        nat->world->tcp_public[map->public_port] = 0;
        free(map);
    }
}

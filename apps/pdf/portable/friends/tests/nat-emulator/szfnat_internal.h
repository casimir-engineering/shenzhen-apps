// What szfnat.c (the world, UDP) and szfnat_tcp.c share. Not for the emulator's users: they include szfnat.h.

#ifndef SZFNAT_INTERNAL_H
#define SZFNAT_INTERNAL_H

#include "szfnat.h"

#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>

#define SZFNAT_MAX_NATS 64
#define SZFNAT_MAX_DATAGRAM 65535
#define SZFNAT_SPLICE_BUFFER 65536

// A remote endpoint as the NAT judges it: the virtual address (szfnat.h) and the port.
typedef struct {
    uint64_t address;
    uint16_t port;
} szfnat_endpoint;

typedef struct szfnat_udp_map {
    int fd;
    uint16_t public_port, inside_port;
    szfnat_endpoint key; // the destination it was made for (ADM: address only; EIM: unused)
    double last_out;
    szfnat_endpoint *permits; // every endpoint it has sent to, for the filter
    size_t permit_count, permit_capacity;
    struct szfnat_udp_map *next;
} szfnat_udp_map;

typedef struct szfnat_tcp_map {
    int anchor; // bound to the public port and never listening, so a SYN nobody dialled is dropped, not reset
    uint16_t public_port, inside_port;
    szfnat_endpoint key;
    double last_used;
    struct szfnat_tcp_map *next;
} szfnat_tcp_map;

typedef enum {
    SZFNAT_FLOW_DIALLING = 1, // outward connect() in progress from the public port
    SZFNAT_FLOW_INSIDE = 2,   // crossed outside; now crossing the host's own SYN on the inside
    SZFNAT_FLOW_SPLICED = 3,  // both legs up: bytes flow
    SZFNAT_FLOW_SILENT = 4,   // toward a private address: never answers, ends at its deadline
} szfnat_flow_state;

typedef struct {
    uint8_t bytes[SZFNAT_SPLICE_BUFFER];
    size_t start, end;
    int eof;
} szfnat_pipe;

typedef struct szfnat_flow {
    szfnat_flow_state state;
    int dead; // closed; freed by the next expiry pass, so no poll entry outlives it
    int outside, inside; // descriptors; -1 once closed
    uint16_t inside_port, contact_port; // the host's port, and the port its SYN is held at
    struct sockaddr_in destination;
    double deadline;
    szfnat_tcp_map *map;
    szfnat_pipe out_to_in, in_to_out;
    int shut_inside, shut_outside;
    struct szfnat_flow *next;
} szfnat_flow;

struct szfnat_nat {
    szfnat_world *world;
    int index;
    szfnat_config config;
    int inside_fd;
    uint16_t inside_port;
    uint16_t next_udp_port, next_tcp_port; // sequential allocation, one pool per protocol as in real NATs
    szfnat_udp_map *udp;
    szfnat_tcp_map *tcp;
    szfnat_flow *flows;
    szfnat_stats stats;
};

struct szfnat_world {
    pthread_t thread;
    pthread_mutex_t lock;
    int wake[2];
    int stopping;
    szfnat_nat *nats[SZFNAT_MAX_NATS];
    // Index + 1 of the NAT that owns each port: its public UDP and TCP mappings, and its hosts' inside ports.
    uint8_t udp_public[65536], tcp_public[65536], udp_inside[65536], tcp_inside[65536];
    unsigned generation; // bumped when a NAT comes or goes, so a poll round over stale entries is discarded
    struct pollfd *polls;
    struct szfnat_poll_entry *entries;
    size_t poll_count, poll_capacity;
    // The thread's buffers: one for what arrives, one for what it wraps for a host.
    uint8_t received[SZFNAT_MAX_DATAGRAM], wrapped[SZFNAT_HEADER_LENGTH + SZFNAT_MAX_DATAGRAM];
};

enum { SZFNAT_POLL_WAKE = 1, SZFNAT_POLL_INSIDE = 2, SZFNAT_POLL_UDP = 3, SZFNAT_POLL_FLOW = 4 };

typedef struct szfnat_poll_entry {
    int kind;
    szfnat_nat *nat;
    void *owner; // the UDP mapping or TCP flow
} szfnat_poll_entry;

double szfnat_now(void);
// How the NAT sees `address`: by the UDP or the TCP ownership tables (each protocol has its own ports).
szfnat_endpoint szfnat_judge(const szfnat_world *world, const struct sockaddr_in *address, int tcp);
int szfnat_keys_match(szfnat_mapping mapping, szfnat_endpoint a, szfnat_endpoint b);
// Binds a socket of `type` to 127.0.0.1 on a port the NAT's allocation picks; -1 when none is free.
int szfnat_bind_public(szfnat_nat *nat, int type, uint16_t *port);
void szfnat_set_nonblocking(int fd);
void szfnat_poll_push(szfnat_world *world, int fd, short events, int kind, szfnat_nat *nat, void *owner);
struct sockaddr_in szfnat_loopback(uint16_t port);

// TCP (szfnat_tcp.c): a control datagram from the shim, the flows' descriptors for poll, their events and deadlines.
void szfnat_tcp_control(szfnat_nat *nat, const uint8_t *request, size_t length, const struct sockaddr_in *from);
void szfnat_tcp_poll_add(szfnat_nat *nat);
void szfnat_tcp_event(szfnat_nat *nat, szfnat_flow *flow, int fd, short revents);
void szfnat_tcp_expire(szfnat_nat *nat, double now);
void szfnat_tcp_close_all(szfnat_nat *nat);

#endif

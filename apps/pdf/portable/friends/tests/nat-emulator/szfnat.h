// A userspace NAT emulator for Friends' hole-punching tests (lead decision 12; ADR 0011 § Verification): one NAT per
// simulated host, on loopback only, between that host's sockets and the "public" side where the local Node host's
// STUN, coturn and the other hosts' NATs live.
//
// How a host goes behind a NAT: its process links szfnat_shim.c, which interposes sendto, recvfrom, connect and
// getpeername while SZFNAT_INSIDE_PORT names its NAT's inside port. Every IPv4 UDP datagram the host sends travels to
// the NAT wrapped in a small header naming its destination; the NAT translates it to a public mapping (a UDP socket of
// its own on 127.0.0.1) and sends it on. Datagrams arriving at a mapping pass the NAT's filter and reach the host
// wrapped in a header naming their source, which the shim unwraps; anything reaching the host's own sockets directly
// is dropped. A TCP connect() asks the NAT over a control datagram, and the NAT dials out from a public mapping;
// crossing SYNs between two NATs' mappings complete in the kernel as the simultaneous open they are. IPv6 does not
// exist on this network: the shim refuses it, so global IPv6 never hides what the NATs do.
//
// Every address is 127.0.0.1, so "address" in the RFC 4787 sense is virtual: each NAT's public ports form one
// address, each NAT's inside hosts another, and everything else on loopback (STUN, TURN) a third. Address-dependent
// mapping and filtering compare those, so two STUN ports of one server look like one address, as on a real network.
//
// Threading: one thread per world runs every NAT; the functions below may be called from any thread.

#ifndef SZFNAT_H
#define SZFNAT_H

#include <stddef.h>
#include <stdint.h>

// The wire between the shim and a NAT's inside port (all integers in network order).
//   data:     "SZN1" | IPv4 address (4) | port (2) | payload   (to the NAT: destination; from it: source)
//   control:  "SZT1" | request id (4) | inside TCP port (2) | IPv4 address (4) | port (2)   (TCP connect request)
//   answer:   "SZT1" | request id (4) | port to connect to (2), 0 when the dial failed at once (a reset came back)
#define SZFNAT_DATA_MAGIC "SZN1"
#define SZFNAT_CONTROL_MAGIC "SZT1"
#define SZFNAT_HEADER_LENGTH 10
#define SZFNAT_CONTROL_LENGTH 16
#define SZFNAT_ANSWER_LENGTH 10
// The largest payload a host may send: macOS carries UDP datagrams of at most 9,216 bytes (net.inet.udp.maxdgram).
#define SZFNAT_MAX_PAYLOAD (9216 - SZFNAT_HEADER_LENGTH)
#define SZFNAT_ENV_INSIDE_PORT "SZFNAT_INSIDE_PORT"

typedef enum {
    SZFNAT_MAP_ENDPOINT_INDEPENDENT = 1, // one public port per inside port, whatever the destination
    SZFNAT_MAP_ADDRESS_DEPENDENT = 2,    // a public port per inside port and destination address
    SZFNAT_MAP_PORT_DEPENDENT = 3,       // a public port per inside port and destination address and port
} szfnat_mapping;

typedef enum {
    SZFNAT_FILTER_ENDPOINT_INDEPENDENT = 1, // a mapping admits anyone ("full cone")
    SZFNAT_FILTER_ADDRESS_DEPENDENT = 2,    // only addresses it has sent to
    SZFNAT_FILTER_PORT_DEPENDENT = 3,       // only address and port pairs it has sent to
} szfnat_filtering;

typedef enum {
    SZFNAT_PORTS_SEQUENTIAL = 1, // each new mapping takes the next free port after the last one
    SZFNAT_PORTS_RANDOM = 2,     // each new mapping takes a random free port from 1024 to 65535
} szfnat_allocation;

typedef struct {
    szfnat_mapping mapping;
    szfnat_filtering filtering;
    szfnat_allocation allocation;
    double mapping_timeout; // seconds without an outbound packet before a mapping ends (RFC 4787 REQ-6)
    int hairpinning;        // a host may reach another host of the same NAT through its public mapping
    int drops_tcp_crossing; // a SYN from another NAT crossing this one's own is dropped: no TCP simultaneous open
} szfnat_config;

typedef struct {
    size_t udp_sent;      // datagrams hosts sent out through a mapping
    size_t udp_admitted;  // datagrams arriving at a mapping that its filter let in
    size_t udp_mappings;  // UDP mappings made so far
    size_t tcp_mappings;  // TCP mappings made so far
    size_t filtered;      // inbound datagrams the filter dropped
    size_t hairpinned;    // datagrams turned back inside through a public mapping
    size_t hairpin_drops; // datagrams to the NAT's own public address while hairpinning is off
    size_t expired;       // mappings ended by their timeout
    size_t unreachable;   // datagrams or dials toward another NAT's inside host (a private address)
    size_t tcp_spliced;   // TCP connections that crossed and now carry bytes
} szfnat_stats;

typedef struct szfnat_world szfnat_world;
typedef struct szfnat_nat szfnat_nat;

// A world's thread starts at once. NULL when the thread or its wake-up pipe cannot be made.
szfnat_world *szfnat_world_create(void);
// Ends every NAT and the thread; closes every socket.
void szfnat_world_destroy(szfnat_world *world);

// A NAT whose inside port the shim reaches (SZFNAT_INSIDE_PORT). NULL when the inside socket cannot be bound or the
// world holds its maximum of NATs.
szfnat_nat *szfnat_add(szfnat_world *world, const szfnat_config *config);
uint16_t szfnat_inside_port(const szfnat_nat *nat);
// Ends the NAT: every mapping and connection closes.
void szfnat_remove(szfnat_world *world, szfnat_nat *nat);
szfnat_stats szfnat_get_stats(szfnat_world *world, const szfnat_nat *nat);

#endif

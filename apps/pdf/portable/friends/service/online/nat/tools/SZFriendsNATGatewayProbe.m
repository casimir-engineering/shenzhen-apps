// Read-only probe of what this LAN's gateway offers for port mapping, through the NAT area's own codecs: a NAT-PMP
// external address request (RFC 6886 opcode 0), a PCP ANNOUNCE (RFC 6887 opcode 0, lifetime 0) over IPv4 and, when
// given, over IPv6 to the router, and one unicast SSDP M-SEARCH for an IGD to the gateway's port 1900. None of them
// creates anything on the router: no MAP, no AddPortMapping. Never part of a suite; run by hand with
// `make -C portable friends-nat-gateway-probe GATEWAY=192.168.1.1 [GATEWAY6=fe80::1%en0]`.
//
// The multicast M-SEARCH production uses (SZFriendsNATUPnP.h) reaches every device on the LAN, so it is not sent
// here. Addresses in answers are reported by class only.

#import "service/online/nat/SZFriendsNATExchange.h"
#import "service/online/nat/SZFriendsNATPCP.h"
#import "service/online/nat/SZFriendsNATRoute.h"

#include <netinet/in.h>
#include <stdio.h>
#include <string.h>

static NSString *ScopeName(SZFriendsNATAddressScope scope) {
    switch (scope) {
    case SZFriendsNATAddressScopeGlobal: return @"public";
    case SZFriendsNATAddressScopeShared: return @"shared (carrier-grade NAT, 100.64/10)";
    case SZFriendsNATAddressScopePrivate: return @"private (another NAT above)";
    case SZFriendsNATAddressScopeUnspecified: return @"unspecified (no WAN address)";
    default: return @"other";
    }
}

// One exchange: 250, 500 and 1,000 ms retransmits within 2 s, as the client does. Prints and returns the answer.
static NSData *Ask(NSString *label, SZFriendsNATEndpoint *server, NSData *request, BOOL (^accept)(NSData *)) {
    dispatch_queue_t queue = dispatch_queue_create("szfriends.nat.probe", DISPATCH_QUEUE_SERIAL);
    SZFriendsNATExchange *exchange = [[SZFriendsNATExchange alloc] initWithServer:server bindAddress:nil queue:queue];
    if (exchange == nil) {
        printf("%-22s no socket toward the gateway\n", label.UTF8String);
        return nil;
    }
    __block NSData *result = nil;
    __block NSError *failure = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSDate *start = [NSDate date];
    dispatch_async(queue, ^{
        [exchange sendRequest:request
                  retransmits:@[ @0.25, @0.5, @1.0 ]
                       budget:2
                       accept:accept
                   completion:^(NSData *answer, NSError *error) {
                       result = answer;
                       failure = error;
                       dispatch_semaphore_signal(done);
                   }];
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    dispatch_sync(queue, ^{
        [exchange close];
    });
    if (result != nil) {
        printf("%-22s answered in %.0f ms (%lu bytes)\n", label.UTF8String, -start.timeIntervalSinceNow * 1000,
               (unsigned long)result.length);
    } else if (failure.code == SZFriendsNATErrorRefused) {
        printf("%-22s port closed (ICMP port unreachable)\n", label.UTF8String);
    } else {
        printf("%-22s silent for 2 s (filtered or dropped)\n", label.UTF8String);
    }
    return result;
}

static void ProbeNATPMP(SZFriendsNATEndpoint *gateway) {
    uint8_t request[SZFriendsNATPMPExternalRequestLength];
    SZFriendsNATPMPWriteExternalAddressRequest(request);
    __block SZFriendsNATPMPResponse response;
    NSData *answer = Ask(@"NAT-PMP (IPv4)", [gateway endpointWithPort:SZFriendsPCPPort],
                         [NSData dataWithBytes:request length:sizeof request], ^BOOL(NSData *a) {
                             return SZFriendsNATPMPParseExternalAddress(a.bytes, a.length, &response);
                         });
    if (answer == nil) return;
    if (response.result != 0) {
        printf("%-22s result %u (refused)\n", "", response.result);
        return;
    }
    NSData *address = [NSData dataWithBytes:response.externalAddress length:4];
    SZFriendsNATEndpoint *external = [SZFriendsNATEndpoint endpointWithAddress:address port:0];
    printf("%-22s external address: %s; epoch %u s\n", "", ScopeName(external.scope).UTF8String, response.epoch);
}

// PCP ANNOUNCE: a 24-byte header with opcode 0 and lifetime 0, which asks nothing of the server but to answer.
static void ProbePCP(NSString *label, SZFriendsNATEndpoint *gateway) {
    dispatch_queue_t queue = dispatch_queue_create("szfriends.nat.probe.addr", DISPATCH_QUEUE_SERIAL);
    SZFriendsNATEndpoint *server = [gateway endpointWithPort:SZFriendsPCPPort];
    SZFriendsNATExchange *source = [[SZFriendsNATExchange alloc] initWithServer:server bindAddress:nil queue:queue];
    if (source == nil) return;
    uint8_t announce[24] = {2, 0};
    SZFriendsNATEndpoint *client = source.localEndpoint;
    dispatch_sync(queue, ^{
        [source close];
    });
    if (client.family == AF_INET) {
        announce[18] = announce[19] = 0xff;
        memcpy(announce + 20, client.address.bytes, 4);
    } else {
        memcpy(announce + 8, client.address.bytes, 16);
    }
    NSData *answer = Ask(label, [gateway endpointWithPort:SZFriendsPCPPort], [NSData dataWithBytes:announce length:24],
                         ^BOOL(NSData *a) {
                             const uint8_t *b = a.bytes;
                             return a.length >= 4 && (b[1] & 0x80);
                         });
    if (answer == nil) return;
    const uint8_t *b = answer.bytes;
    if (b[0] == 0) {
        printf("%-22s version 0, result %u: NAT-PMP only\n", "", (unsigned)((b[2] << 8) | b[3]));
    } else {
        printf("%-22s version %u, result %u: PCP\n", "", b[0], answer.length >= 4 ? b[3] : 0);
    }
}

static void ProbeSSDP(SZFriendsNATEndpoint *gateway) {
    NSString *search = [NSString stringWithFormat:@"M-SEARCH * HTTP/1.1\r\nHOST: %@:1900\r\n"
                                                   "MAN: \"ssdp:discover\"\r\nMX: 1\r\n"
                                                   "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n",
                                                   gateway.host];
    NSData *answer = Ask(@"UPnP (unicast SSDP)", [gateway endpointWithPort:1900],
                         [search dataUsingEncoding:NSASCIIStringEncoding], ^BOOL(NSData *a) {
                             return a.length > 12 && memcmp(a.bytes, "HTTP/1.1 200", 12) == 0;
                         });
    if (answer == nil) {
        printf("%-22s (an IGD that listens only on the multicast group refuses unicast too: not conclusive)\n", "");
        return;
    }
    NSString *text = [[NSString alloc] initWithData:answer encoding:NSISOLatin1StringEncoding];
    for (NSString *line in [text componentsSeparatedByString:@"\r\n"]) {
        if ([line.lowercaseString hasPrefix:@"server:"] || [line.lowercaseString hasPrefix:@"st:"]) {
            printf("%-22s %s\n", "", line.UTF8String);
        }
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        SZFriendsNATEndpoint *gateway = argc > 1 ? [SZFriendsNATEndpoint endpointWithHost:@(argv[1]) port:0] : nil;
        SZFriendsNATEndpoint *gateway6 = argc > 2 && argv[2][0] ? [SZFriendsNATEndpoint endpointWithHost:@(argv[2])
                                                                                                    port:0]
                                                                : nil;
        BOOL lan = gateway.scope == SZFriendsNATAddressScopePrivate || gateway.scope == SZFriendsNATAddressScopeShared;
        if (gateway == nil || gateway.family != AF_INET || !lan ||
            (gateway6 != nil && gateway6.scope != SZFriendsNATAddressScopeLinkLocal)) {
            fprintf(stderr, "usage: SZFriendsNATGatewayProbe <private IPv4 gateway> [<link-local router>%%<if>]\n");
            return 2;
        }
        SZFriendsNATRoute *internet = [SZFriendsNATRoute defaultRouteForFamily:AF_INET];
        printf("%-22s %s (%s)\n", "route to the Internet", internet.interfaceName.UTF8String ?: "none",
               internet.physical ? "physical: port mapping would run" : "a tunnel: port mapping would be skipped");
        ProbeNATPMP(gateway);
        ProbePCP(@"PCP (IPv4)", gateway);
        if (gateway6 != nil) ProbePCP(@"PCP (IPv6)", gateway6);
        ProbeSSDP(gateway);
        printf("nothing was mapped: only read-only requests were sent\n");
    }
    return 0;
}

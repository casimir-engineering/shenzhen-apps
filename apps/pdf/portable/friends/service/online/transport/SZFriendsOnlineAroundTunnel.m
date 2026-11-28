// Which way a friend's direct connection takes under a VPN or TUN proxy, per network (ADR 0011 § VPN and tunnels):
// around it on the physical interface, or through it by the default route. A VPN that forbids going around
// (includeAllNetworks, a kill switch) drops every packet of a socket kept on the interface, so a connection kept there
// that never connects sends the next one on that network through the VPN's exit instead.

#import "service/online/transport/SZFriendsOnlineTransportInternal.h"

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>

// Networks remembered at most; the oldest goes first.
static const NSUInteger kNetworksMax = 32;

@interface SZFriendsOnlineTunnelChoice : NSObject
@property(nonatomic) BOOL around;    // the way the next connection takes
@property(nonatomic) BOOL confirmed; // a connection that way connected
@property(nonatomic) NSUInteger failures;
@end

@implementation SZFriendsOnlineTunnelChoice
@end

@implementation SZFriendsOnlineTunnelMemory {
    NSMutableDictionary<NSString *, SZFriendsOnlineTunnelChoice *> *_choices;
    NSMutableArray<NSString *> *_order; // oldest first
}

+ (instancetype)sharedMemory {
    static SZFriendsOnlineTunnelMemory *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _choices = [NSMutableDictionary dictionary];
        _order = [NSMutableArray array];
    }
    return self;
}

- (BOOL)goesAroundOnNetwork:(NSString *)network {
    @synchronized(self) {
        SZFriendsOnlineTunnelChoice *choice = _choices[network];
        return choice == nil || choice.around;
    }
}

- (void)network:(NSString *)network wentAround:(BOOL)around connected:(BOOL)connected {
    @synchronized(self) {
        SZFriendsOnlineTunnelChoice *choice = _choices[network];
        if (choice == nil) {
            choice = [SZFriendsOnlineTunnelChoice new];
            choice.around = around;
            _choices[network] = choice;
            [_order addObject:network];
            if (_order.count > kNetworksMax) {
                [_choices removeObjectForKey:_order.firstObject];
                [_order removeObjectAtIndex:0];
            }
        }
        if (choice.around != around) return; // started before the choice changed: the newer outcome decides
        if (connected) {
            choice.confirmed = YES;
            choice.failures = 0;
            return;
        }
        // A way that connected before is left only after failing twice in a row: a friend behind a hard NAT, or one
        // who went away, fails a direct connection either way.
        choice.failures++;
        if (choice.confirmed && choice.failures < 2) return;
        choice.around = !around;
        choice.confirmed = NO;
        choice.failures = 0;
    }
}

@end

NSString *SZFriendsOnlineTunnelNetwork(NSString *around, const char *tunnel) {
    struct ifaddrs *list = NULL;
    if (around == nil || getifaddrs(&list) != 0) return nil;
    NSString *subnet = nil;
    for (const struct ifaddrs *entry = list; entry != NULL && subnet == nil; entry = entry->ifa_next) {
        if (entry->ifa_addr == NULL || entry->ifa_netmask == NULL || entry->ifa_addr->sa_family != AF_INET ||
            entry->ifa_name == NULL || strcmp(entry->ifa_name, around.UTF8String) != 0) {
            continue;
        }
        struct in_addr address = ((const struct sockaddr_in *)(const void *)entry->ifa_addr)->sin_addr;
        struct in_addr mask = ((const struct sockaddr_in *)(const void *)entry->ifa_netmask)->sin_addr;
        struct in_addr network = {address.s_addr & mask.s_addr};
        char text[INET_ADDRSTRLEN];
        if (inet_ntop(AF_INET, &network, text, sizeof text) == NULL) continue;
        subnet = [NSString stringWithFormat:@"%s/%d", text, __builtin_popcount(ntohl(mask.s_addr))];
    }
    freeifaddrs(list);
    if (subnet == nil) return nil;
    return [NSString stringWithFormat:@"%@ %@ under %s", around, subnet, tunnel != NULL && tunnel[0] ? tunnel : "?"];
}

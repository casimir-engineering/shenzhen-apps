// Discovery internals shared by this directory's adapters and its tests. Not a public header: other areas use
// SZFriendsDiscovery.h and SZFriendsDiscoveryCoordinator.h only.

#import <Foundation/Foundation.h>

#include <sys/socket.h>

#import "service/discovery/SZFriendsDiscovery.h"
#import "service/session/SZFriendsSession.h"

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const SZFriendsDiscoveryErrorDomain;

typedef NS_ERROR_ENUM(SZFriendsDiscoveryErrorDomain, SZFriendsDiscoveryError) {
    SZFriendsDiscoveryErrorTimedOut = 1,      // the endpoint did not answer in time
    SZFriendsDiscoveryErrorUnknownEndpoint = 2, // never sighted, or lost since
    SZFriendsDiscoveryErrorNotRunning = 3,    // the adapter is stopped
    SZFriendsDiscoveryErrorCancelled = 4,     // stopped while connecting
    SZFriendsDiscoveryErrorDenied = 5,        // the system refused (Local Network or Bluetooth access)
    SZFriendsDiscoveryErrorNoChannel = 6,     // the device has not published an L2CAP channel for that entry
    SZFriendsDiscoveryErrorEvicted = 7,       // an incoming connection that had not authenticated made way for a
                                              // newer one, or sent no complete message 1 in time
};

NSError *SZFriendsDiscoveryMakeError(SZFriendsDiscoveryError code, NSString *detail);
NSString *SZFriendsHexFromData(NSData *data);
NSData *_Nullable SZFriendsDataFromHex(NSString *hex); // nil unless even-length lowercase or uppercase hex

#pragma mark - Network.framework adapter

@interface SZFriendsNetworkAdapterOptions : NSObject
@property(nonatomic, copy) NSString *serviceType;   // default SZFriendsBonjourServiceType
@property(nonatomic) BOOL loopbackOnly;             // lo0 only, no peer-to-peer: never reaches the network
@property(nonatomic) NSTimeInterval connectTimeout; // default 10 s
@property(nonatomic) NSTimeInterval retryDelay;     // after a browser or listener failure; default 5 s
// A hidden listener replaced at a new window keeps accepting this long, unadvertised, for connections already on
// their way to its port; default 30 s.
@property(nonatomic) NSTimeInterval listenerOverlap;
@property(nonatomic, copy) NSDate * (^clock)(void); // stamps sightings and names windows; default [NSDate date]
@end

id<SZFriendsDiscoveryAdapter> SZFriendsMakeNetworkAdapterWithOptions(dispatch_queue_t queue,
                                                                      SZFriendsNetworkAdapterOptions *options);
// Browsers, listeners and path monitors this process has created: the launch tests prove creating an adapter
// creates none.
NSUInteger SZFriendsNetworkObjectsCreated(void);
// Tests, on the adapter's queue: the hidden listeners' ports, the advertised one first, then any still in their
// overlap (0 for one not ready yet).
NSArray<NSNumber *> *SZFriendsNetworkAdapterHiddenPorts(id<SZFriendsDiscoveryAdapter> adapter);
// The Wi-Fi Direct boost (ADR 0019): a TCP stream to `host`:`port` on a joined link, with the adapter's parameters;
// nil when it does not connect (or `adapter` is not a network adapter). `done` runs once, on the adapter's queue.
void SZFriendsNetworkAdapterOpenStreamToHost(id<SZFriendsDiscoveryAdapter> adapter, NSString *host, uint16_t port,
                                             void (^done)(id<SZFriendsByteStream> _Nullable stream));

// TXT record of the hidden entry (v=1, t=<hex tag>, c=<hex tags concatenated>) or the public one (v=1, p=1, and
// nothing else: a public entry carries no tag). Hex because TXT values are shown verbatim by Bonjour tools and
// '=' or NUL bytes in a raw tag would confuse them.
NSDictionary<NSString *, NSData *> *SZFriendsNetworkTXTFields(NSData *_Nullable tag, NSArray<NSData *> *callbackTags,
                                                               BOOL publicEntry);
// NO for anything that is not a version 1 Friends entry. Malformed t or c values read as absent; at most
// SZFriendsCallbackTagsMax callback tags are kept.
BOOL SZFriendsNetworkParseTXT(NSDictionary<NSString *, NSData *> *fields, NSData *_Nullable *_Nonnull tag,
                              NSArray<NSData *> *_Nonnull *_Nonnull callbackTags, BOOL *isPublic);
// Random per presence window, never the Mac's name (ADR 0004).
NSString *SZFriendsRandomInstanceName(void);
// awdl* and llw* are the peer-to-peer Wi-Fi links; every other interface (Wi-Fi, Ethernet, loopback) is the LAN.
SZFriendsRouteMethod SZFriendsRouteForInterfaceName(NSString *interfaceName);
// What the per-address admission limit counts a connection from `address` under: an IPv4 address whole (also when it
// arrives IPv4-mapped on an IPv6 socket), an IPv6 address by its /64 (with the interface for a link-local one), nil
// for anything else (the listener's limit only). WHY /64: a host chooses any number of addresses inside its /64
// (privacy addresses, or simply made up), so counting whole IPv6 addresses never bounded one peer. Link-local
// addresses keep their interface because fe80::/64 is the same prefix on every link, so without it every neighbour
// on Wi-Fi, Ethernet and peer-to-peer Wi-Fi would share one count.
NSString *_Nullable SZFriendsAdmissionKeyForAddress(const struct sockaddr *_Nullable address);
SZFriendsAdapterState SZFriendsNetworkAdapterState(BOOL running, BOOL policyDenied, BOOL radioOff, BOOL failed,
                                                   BOOL browserReady, BOOL listenerReady);

#pragma mark - Admission (SZFriendsAdmission.m)

// Counts one adapter's incoming streams against its SZFriendsAdmissionLimits. Thread-safe: adapters admit on their
// queue, sessions report on theirs. Listener names are the adapter's own ("hidden", "public"); an address is the
// remote's admission key (SZFriendsAdmissionKeyForAddress on IP, the central's identifier on Bluetooth).
@interface SZFriendsAdmissionController : NSObject
// `clock` counts seconds for the per-minute rates (nil: CLOCK_MONOTONIC).
- (instancetype)initWithClock:(nullable NSTimeInterval (^)(void))clock NS_DESIGNATED_INITIALIZER;
@property(nonatomic, copy, null_resettable) SZFriendsAdmissionLimits *limits;
// The stream to hand to the delegate in place of `stream`: it answers the responder's admission questions and holds
// a place until the session authenticates or the stream closes. Always admitted: when the address or the listener
// already holds its maximum, the oldest connection holding a place there is closed to make room (its session sees
// the stream close with SZFriendsDiscoveryErrorEvicted), so nobody can lock friends out by keeping the places full.
// A connection with no complete message 1 within limits.firstMessageTimeout of this call is closed the same way. A nil
// `address` counts against the listener only.
- (id<SZFriendsByteStream>)admitStream:(id<SZFriendsByteStream>)stream
                              listener:(NSString *)listener
                               address:(nullable NSString *)address;
- (NSUInteger)pendingOnListener:(NSString *)listener;
- (NSUInteger)pendingFromAddress:(NSString *)address;
@end

#pragma mark - Streams

// A byte stream over NSInputStream/NSOutputStream, scheduled on one shared run loop thread because L2CAP streams
// are run-loop streams. `owner` is retained for the stream's life (a CBL2CAPChannel closes when released).
@interface SZFriendsRunLoopByteStream : NSObject <SZFriendsByteStream>
- (instancetype)initWithInputStream:(NSInputStream *)input
                       outputStream:(NSOutputStream *)output
                              owner:(nullable id)owner
                 preferredWriteSize:(NSUInteger)preferredWriteSize NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END

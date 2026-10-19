// UPnP IGD mapping through miniupnpc (SZFriendsNATUPnP.h).

#import "service/online/nat/SZFriendsNATUPnP.h"

#include <miniupnpc.h>
#include <miniwget_private.h>
#include <upnpcommands.h>
#include <upnperrors.h>
#include <stdatomic.h>
#include <string.h>

NSString *const SZFriendsNATUPnPDescription = @"Shenzhen Friends";

enum {
    kErrorConflict = 718,       // ConflictInMappingEntry
    kErrorPermanentOnly = 725,  // OnlyPermanentLeasesSupported
    kCleanupEntriesMax = 64,    // GetGenericPortMappingEntry calls spent on finding stale mappings
};

static NSString *const kLease = @"7200";

// Every miniupnpc call, for the whole helper, one at a time: they block on sockets with their own timeouts.
static dispatch_queue_t UPnPQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("szfriends.nat.upnp", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// Internal ports this helper maps now (on UPnPQueue only): what stale cleanup must leave alone.
static NSMutableSet<NSNumber *> *LivePorts(void) {
    static NSMutableSet<NSNumber *> *ports;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ports = [NSMutableSet set];
    });
    return ports;
}

// The numeric host of an http URL, or nil (no names: a description on a name could point anywhere).
static SZFriendsNATEndpoint *HostOfURL(const char *url) {
    if (url == NULL || strncmp(url, "http://", 7) != 0) return nil;
    char host[MAXHOSTNAMELEN + 1] = {0};
    unsigned short port = 0;
    char *path = NULL;
    unsigned int scope = 0;
    if (!parseURL(url, host, &port, &path, &scope)) return nil;
    return [SZFriendsNATEndpoint endpointWithHost:@(host) port:port];
}

// Who finished first, the work or the budget's timer.
@interface SZFriendsNATOnce : NSObject
- (BOOL)claim; // YES for the first caller only
@end

@implementation SZFriendsNATOnce {
    atomic_bool _claimed;
}
- (BOOL)claim {
    return !atomic_exchange(&_claimed, true);
}
@end

@implementation SZFriendsNATUPnP {
    NSString *_interfaceName;
    SZFriendsNATEndpoint *_deviceHost; // the gateway, or the test device's loopback address
    NSString *_rootURL;
    BOOL _loopbackOnly;
    atomic_bool _foundDevice;
    // UPnPQueue only:
    BOOL _haveDevice;
    struct UPNPUrls _urls;
    struct IGDdatas _data;
    NSString *_internalPort, *_externalPort, *_internalClient, *_lease;
    char _pinholeID[16];
    BOOL _havePinhole;
    SZFriendsNATEndpoint *_mappedIPv4, *_mappedIPv6;
}

+ (instancetype)discoveryOnInterface:(NSString *)interfaceName gateway:(SZFriendsNATEndpoint *)gateway {
    SZFriendsNATUPnP *upnp = [[self alloc] initPrivate];
    upnp->_interfaceName = [interfaceName copy];
    upnp->_deviceHost = [gateway endpointWithPort:0];
    return upnp;
}

+ (instancetype)deviceAtRootDescriptionURL:(NSString *)url {
    SZFriendsNATUPnP *upnp = [[self alloc] initPrivate];
    upnp->_rootURL = [url copy];
    upnp->_loopbackOnly = YES;
    upnp->_deviceHost = [HostOfURL(url.UTF8String) endpointWithPort:0];
    return upnp;
}

- (instancetype)initPrivate {
    if ((self = [super init])) {
        _budget = 3;
        _discoveryWait = 1;
    }
    return self;
}

- (void)dealloc {
    if (_haveDevice) FreeUPNPUrls(&_urls);
}

- (BOOL)foundDevice {
    return atomic_load(&_foundDevice);
}

- (BOOL)isOnDeviceHost:(const char *)url {
    SZFriendsNATEndpoint *host = HostOfURL(url);
    if (host == nil || _deviceHost == nil || ![host hasSameAddressAs:_deviceHost]) return NO;
    return !_loopbackOnly || SZFriendsNATLoopbackOnlyAllows(host);
}

// Fills _urls and _data from the one acceptable device. UPnPQueue.
- (BOOL)findDevice {
    if (_haveDevice) return YES;
    if (_deviceHost == nil) return NO;
    char lan[64] = {0};
    if (_rootURL != nil) {
        if (![self isOnDeviceHost:_rootURL.UTF8String]) return NO;
        if (!UPNP_GetIGDFromUrl(_rootURL.UTF8String, &_urls, &_data, lan, sizeof lan)) return NO;
    } else {
        static const char *const types[] = {"urn:schemas-upnp-org:device:InternetGatewayDevice:2",
                                            "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
                                            "urn:schemas-upnp-org:service:WANIPConnection:1",
                                            "urn:schemas-upnp-org:service:WANPPPConnection:1", NULL};
        int error = 0;
        // "" skips minissdpd's socket; searchalltypes sends every search first and waits once, not once per type.
        struct UPNPDev *devices = upnpDiscoverDevices(types, (int)(_discoveryWait * 1000), _interfaceName.UTF8String,
                                                      "", UPNP_LOCAL_PORT_ANY, 0, 2, &error, 1);
        BOOL found = NO;
        for (struct UPNPDev *device = devices; device != NULL && !found; device = device->pNext) {
            if (![self isOnDeviceHost:device->descURL]) continue;
            found = UPNP_GetIGDFromUrl(device->descURL, &_urls, &_data, lan, sizeof lan) == 1;
        }
        freeUPNPDevlist(devices);
        if (!found) return NO;
    }
    _haveDevice = YES;
    if (_data.first.servicetype[0] == '\0' || ![self isOnDeviceHost:_urls.controlURL]) return NO;
    atomic_store(&_foundDevice, YES);
    return YES;
}

// Deletes mappings a crashed run left: ours by description, for this LAN address, on a port this helper no longer
// maps. Deleting shifts later entries down, so the index advances only past entries that stay.
- (void)removeStaleMappingsBefore:(NSDate *)deadline {
    int index = 0;
    for (int calls = 0; calls < kCleanupEntriesMax && deadline.timeIntervalSinceNow > 0; calls++) {
        char indexText[8], extPort[6] = {0}, intClient[16] = {0}, intPort[6] = {0}, protocol[4] = {0};
        char desc[80] = {0}, enabled[4] = {0}, remote[64] = {0}, duration[16] = {0};
        snprintf(indexText, sizeof indexText, "%d", index);
        int result = UPNP_GetGenericPortMappingEntry(_urls.controlURL, _data.first.servicetype, indexText, extPort,
                                                     intClient, intPort, protocol, desc, enabled, remote, duration);
        if (result != UPNPCOMMAND_SUCCESS) return;
        BOOL ours = strcmp(desc, SZFriendsNATUPnPDescription.UTF8String) == 0 && strcmp(protocol, "UDP") == 0 &&
                    strcmp(intClient, _internalClient.UTF8String) == 0;
        if (ours && ![LivePorts() containsObject:@(atoi(intPort))] &&
            UPNP_DeletePortMapping(_urls.controlURL, _data.first.servicetype, extPort, "UDP", NULL) ==
                UPNPCOMMAND_SUCCESS) {
            continue;
        }
        index++;
    }
}

- (SZFriendsNATEndpoint *)externalEndpointForPort:(NSString *)port {
    char external[40] = {0};
    if (UPNP_GetExternalIPAddress(_urls.controlURL, _data.first.servicetype, external) != UPNPCOMMAND_SUCCESS) {
        return nil;
    }
    SZFriendsNATEndpoint *endpoint = [SZFriendsNATEndpoint endpointWithHost:@(external) port:(uint16_t)port.intValue];
    BOOL usable = endpoint.scope == SZFriendsNATAddressScopeGlobal ||
                  (_loopbackOnly && endpoint.scope == SZFriendsNATAddressScopeReserved);
    return usable && endpoint.family == AF_INET ? endpoint : nil;
}

- (int)addMappingWithLease:(NSString *)lease {
    const char *service = _data.first.servicetype;
    int result = UPNP_AddPortMapping(_urls.controlURL, service, _externalPort.UTF8String, _internalPort.UTF8String,
                                     _internalClient.UTF8String, SZFriendsNATUPnPDescription.UTF8String, "UDP", NULL,
                                     lease.UTF8String);
    size_t serviceLength = strlen(service);
    if (result == kErrorConflict && serviceLength > 2 && strcmp(service + serviceLength - 2, ":2") == 0) {
        char reserved[6] = {0};
        result = UPNP_AddAnyPortMapping(_urls.controlURL, service, _externalPort.UTF8String,
                                        _internalPort.UTF8String, _internalClient.UTF8String,
                                        SZFriendsNATUPnPDescription.UTF8String, "UDP", NULL, lease.UTF8String,
                                        reserved);
        if (result == UPNPCOMMAND_SUCCESS) _externalPort = @(reserved);
    }
    return result;
}

- (void)openPinholeFor:(SZFriendsNATEndpoint *)globalIPv6 lease:(NSString *)lease {
    BOOL global = globalIPv6 != nil && globalIPv6.scope == SZFriendsNATAddressScopeGlobal;
    if (!global || _data.IPv6FC.servicetype[0] == '\0' || ![self isOnDeviceHost:_urls.controlURL_6FC]) {
        return;
    }
    memset(_pinholeID, 0, sizeof _pinholeID);
    if (UPNP_AddPinhole(_urls.controlURL_6FC, _data.IPv6FC.servicetype, "", "0", globalIPv6.host.UTF8String,
                        _internalPort.UTF8String, "17", lease.UTF8String, _pinholeID) == UPNPCOMMAND_SUCCESS) {
        _havePinhole = YES;
        _mappedIPv6 = [globalIPv6 endpointWithPort:(uint16_t)_internalPort.intValue];
    }
}

- (NSArray<SZFriendsNATEndpoint *> *)mapped {
    NSMutableArray<SZFriendsNATEndpoint *> *mapped = [NSMutableArray array];
    if (_mappedIPv4 != nil) [mapped addObject:_mappedIPv4];
    if (_mappedIPv6 != nil) [mapped addObject:_mappedIPv6];
    return mapped;
}

// Runs `work` on UPnPQueue and calls `completion` on `queue` with its result or, at the budget, with a timeout.
// `late` runs on UPnPQueue when the work finished after the budget, to undo what it made.
- (void)runWork:(NSArray<SZFriendsNATEndpoint *> * (^)(void))work
           late:(dispatch_block_t)late
          queue:(dispatch_queue_t)queue
     completion:(SZFriendsNATUPnPCompletion)completion {
    SZFriendsNATOnce *once = [SZFriendsNATOnce new];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_budget * NSEC_PER_SEC)), queue, ^{
        if ([once claim]) {
            completion(@[], [NSError errorWithDomain:SZFriendsNATErrorDomain code:SZFriendsNATErrorTimedOut
                                            userInfo:nil]);
        }
    });
    dispatch_async(UPnPQueue(), ^{
        NSArray<SZFriendsNATEndpoint *> *mapped = work();
        if (![once claim]) {
            late();
            return;
        }
        dispatch_async(queue, ^{
            completion(mapped, mapped.count > 0 ? nil
                                                : [NSError errorWithDomain:SZFriendsNATErrorDomain
                                                                      code:SZFriendsNATErrorUnsupported
                                                                  userInfo:nil]);
        });
    });
}

- (void)mapUDPPort:(uint16_t)internalPort
      localAddress:(SZFriendsNATEndpoint *)localAddress
        globalIPv6:(SZFriendsNATEndpoint *)globalIPv6
             queue:(dispatch_queue_t)queue
        completion:(SZFriendsNATUPnPCompletion)completion {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:_budget];
    __weak SZFriendsNATUPnP *weakSelf = self;
    [self runWork:^NSArray<SZFriendsNATEndpoint *> * {
        SZFriendsNATUPnP *strongSelf = weakSelf;
        if (strongSelf == nil || localAddress.family != AF_INET || ![strongSelf findDevice]) return @[];
        strongSelf->_internalPort = [NSString stringWithFormat:@"%u", internalPort];
        strongSelf->_externalPort = strongSelf->_internalPort;
        strongSelf->_internalClient = localAddress.host;
        [strongSelf removeStaleMappingsBefore:deadline];
        NSString *lease = kLease;
        int result = [strongSelf addMappingWithLease:lease];
        if (result == kErrorPermanentOnly) {
            lease = @"0";
            result = [strongSelf addMappingWithLease:lease];
        }
        if (result == UPNPCOMMAND_SUCCESS) {
            strongSelf->_lease = lease;
            [LivePorts() addObject:@(internalPort)];
            strongSelf->_mappedIPv4 = [strongSelf externalEndpointForPort:strongSelf->_externalPort];
            if (strongSelf->_mappedIPv4 == nil) [strongSelf deleteOnQueue]; // no global address: no use to anyone
        }
        if (strongSelf->_lease != nil) [strongSelf openPinholeFor:globalIPv6 lease:lease];
        return [strongSelf mapped];
    }
        late:^{
            [weakSelf deleteOnQueue];
        }
        queue:queue
        completion:completion];
}

- (void)renewOnQueue:(dispatch_queue_t)queue completion:(SZFriendsNATUPnPCompletion)completion {
    __weak SZFriendsNATUPnP *weakSelf = self;
    [self runWork:^NSArray<SZFriendsNATEndpoint *> * {
        SZFriendsNATUPnP *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_lease == nil) return @[];
        if (strongSelf->_mappedIPv4 != nil && [strongSelf addMappingWithLease:strongSelf->_lease] != 0) {
            strongSelf->_mappedIPv4 = nil;
        }
        if (strongSelf->_havePinhole &&
            UPNP_UpdatePinhole(strongSelf->_urls.controlURL_6FC, strongSelf->_data.IPv6FC.servicetype,
                               strongSelf->_pinholeID, strongSelf->_lease.UTF8String) != UPNPCOMMAND_SUCCESS) {
            strongSelf->_havePinhole = NO;
            strongSelf->_mappedIPv6 = nil;
        }
        return [strongSelf mapped];
    }
        late:^{
        }
        queue:queue
        completion:completion];
}

// UPnPQueue.
- (void)deleteOnQueue {
    if (_lease == nil) return;
    if (_mappedIPv4 != nil || _externalPort != nil) {
        UPNP_DeletePortMapping(_urls.controlURL, _data.first.servicetype, _externalPort.UTF8String, "UDP", NULL);
    }
    if (_havePinhole) UPNP_DeletePinhole(_urls.controlURL_6FC, _data.IPv6FC.servicetype, _pinholeID);
    [LivePorts() removeObject:@(_internalPort.intValue)];
    _lease = nil;
    _havePinhole = NO;
    _mappedIPv4 = nil;
    _mappedIPv6 = nil;
}

- (void)removeMappings {
    // Strong on purpose: the delete must reach the router even when the mapping's owner is already gone.
    SZFriendsNATUPnP *strongSelf = self;
    dispatch_async(UPnPQueue(), ^{
        [strongSelf deleteOnQueue];
    });
}

@end

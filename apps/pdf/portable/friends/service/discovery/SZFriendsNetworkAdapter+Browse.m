// The Network.framework adapter's Bonjour browser and path monitor (SZFriendsNetworkAdapterInternal.h).

#import "service/discovery/SZFriendsNetworkAdapterInternal.h"

#include <ifaddrs.h>
#include <net/if.h>

// Peer-to-peer Wi-Fi needs the Wi-Fi radio but no network: an up awdl or llw interface means it can still work
// while no path is satisfied. The hardware matrix checks this reading with Wi-Fi off and on but unassociated.
static BOOL PeerToPeerInterfaceUp(void) {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return NO;
    BOOL up = NO;
    for (struct ifaddrs *entry = list; entry && !up; entry = entry->ifa_next) {
        NSString *name = @(entry->ifa_name);
        BOOL peerToPeer = SZFriendsRouteForInterfaceName(name) == SZFriendsRouteMethodPeerToPeerWiFi;
        up = peerToPeer && (entry->ifa_flags & IFF_UP) && (entry->ifa_flags & IFF_RUNNING);
    }
    freeifaddrs(list);
    return up;
}

static NSString *EndpointIDForName(NSString *name) {
    return [@"bonjour:" stringByAppendingString:name];
}

// Bonjour names and TXT keys are bytes from any device on the LAN. @(cString) returns nil for bytes that are not
// UTF-8, and a nil name or key then threw inside the browse handler and ended the helper. A Friends entry's name
// and keys are always ASCII, so anything else is not one of ours and is skipped.
NSString *SZFriendsStringFromLANBytes(const char *bytes) {
    return bytes ? [NSString stringWithUTF8String:bytes] : nil;
}

NSString *SZFriendsBonjourServiceName(nw_endpoint_t endpoint) {
    return SZFriendsStringFromLANBytes(endpoint ? nw_endpoint_get_bonjour_service_name(endpoint) : NULL);
}

NSDictionary<NSString *, NSData *> *SZFriendsNetworkTXTRecordFields(nw_txt_record_t txt) {
    NSMutableDictionary<NSString *, NSData *> *fields = [NSMutableDictionary dictionary];
    if (txt == nil) return fields;
    nw_txt_record_apply(txt, ^bool(const char *key, nw_txt_record_find_key_t found, const uint8_t *value,
                                   size_t length) {
        NSString *name = SZFriendsStringFromLANBytes(key);
        if (name != nil && found == nw_txt_record_find_key_non_empty_value) {
            fields[name] = [NSData dataWithBytes:value length:length];
        }
        return true;
    });
    return fields;
}

@implementation SZFriendsNetworkAdapter (Browse)

#pragma mark - Browsing

- (void)startBrowser {
    nw_browse_descriptor_t descriptor = nw_browse_descriptor_create_bonjour_service(_options.serviceType.UTF8String,
                                                                                    "local");
    nw_browse_descriptor_set_include_txt_record(descriptor, true);
    _browser = nw_browser_create(descriptor, [self parameters]);
    SZFriendsNoteNetworkObjectCreated();
    nw_browser_set_queue(_browser, _queue);
    NSUInteger run = _run;
    __weak SZFriendsNetworkAdapter *weakSelf = self;
    nw_browser_set_state_changed_handler(_browser, ^(nw_browser_state_t state, nw_error_t error) {
        SZFriendsNetworkAdapter *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_run != run) return;
        if (state == nw_browser_state_ready) {
            strongSelf->_browserReady = YES;
            strongSelf->_policyDenied = NO; // access granted since: the browser recovers by itself
            [strongSelf updateState];
        } else if (state == nw_browser_state_waiting || state == nw_browser_state_failed) {
            [strongSelf noteError:error failed:state == nw_browser_state_failed];
        }
    });
    nw_browser_browse_results_changed_handler_t changed = ^(nw_browse_result_t old, nw_browse_result_t new, bool done) {
        (void)done;
        SZFriendsNetworkAdapter *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_run != run) return;
        [strongSelf browseResultChangedFrom:old to:new];
    };
    nw_browser_set_browse_results_changed_handler(_browser, changed);
    nw_browser_start(_browser);
}

- (void)refreshDiscovery {
    if (!_running || !_browser) return;
    // Everything known is reported lost and immediately looked for again; the merger's removal grace absorbs
    // the gap, so nothing flips in Nearby for endpoints that are still there.
    for (NSString *endpointID in _endpoints.allKeys) [self.delegate adapter:self didLoseEndpoint:endpointID];
    [_endpoints removeAllObjects];
    nw_browser_cancel(_browser);
    _browser = nil;
    [self startBrowser];
}

- (void)browseResultChangedFrom:(nw_browse_result_t)old to:(nw_browse_result_t)new {
    nw_browse_result_change_t changes = nw_browse_result_get_changes(old, new);
    if (changes & nw_browse_result_change_result_removed) {
        NSString *removedName = SZFriendsBonjourServiceName(nw_browse_result_copy_endpoint(old));
        NSString *endpointID = removedName ? EndpointIDForName(removedName) : nil;
        if (endpointID && _endpoints[endpointID]) {
            [_endpoints removeObjectForKey:endpointID];
            [self.delegate adapter:self didLoseEndpoint:endpointID];
        }
        return;
    }
    if (!new || changes == nw_browse_result_change_identical) return;
    nw_endpoint_t endpoint = nw_browse_result_copy_endpoint(new);
    NSString *name = SZFriendsBonjourServiceName(endpoint);
    if (name == nil || [_ownNames containsObject:name]) return;
    NSString *endpointID = EndpointIDForName(name);

    NSDictionary<NSString *, NSData *> *fields =
        SZFriendsNetworkTXTRecordFields(nw_browse_result_copy_txt_record_object(new));
    NSData *tag = nil;
    NSArray<NSData *> *callbackTags = @[];
    BOOL isPublic = NO;
    if (!SZFriendsNetworkParseTXT(fields, &tag, &callbackTags, &isPublic)) {
        // Not (or no longer) a Friends v1 entry: forget it rather than dial something we cannot speak to.
        if (_endpoints[endpointID]) {
            [_endpoints removeObjectForKey:endpointID];
            [self.delegate adapter:self didLoseEndpoint:endpointID];
        }
        return;
    }
    // Seen on several interfaces (Wi-Fi and awdl): the LAN ranks first, and the racer dials by rank.
    __block SZFriendsRouteMethod route = SZFriendsRouteMethodNone;
    nw_browse_result_enumerate_interfaces(new, ^bool(nw_interface_t interface) {
        NSString *interfaceName = SZFriendsStringFromLANBytes(nw_interface_get_name(interface));
        SZFriendsRouteMethod method = SZFriendsRouteForInterfaceName(interfaceName ?: @"");
        if (route == SZFriendsRouteMethodNone || SZFriendsRouteIsBetter(method, route)) route = method;
        return true;
    });
    if (route == SZFriendsRouteMethodNone) route = SZFriendsRouteMethodLAN;
    _endpoints[endpointID] = endpoint;
    SZFriendsSighting *sighting = [[SZFriendsSighting alloc] initWithMethod:SZFriendsDiscoveryMethodNetwork
                                                                      route:route
                                                                 endpointID:endpointID
                                                                presenceTag:tag
                                                               callbackTags:callbackTags
                                                                   isPublic:isPublic
                                                                     seenAt:_options.clock()];
    [self.delegate adapter:self didSight:sighting];
}

#pragma mark - Path

- (void)startPathMonitor {
    _monitor = nw_path_monitor_create();
    SZFriendsNoteNetworkObjectCreated();
    nw_path_monitor_set_queue(_monitor, _queue);
    NSUInteger run = _run;
    __weak SZFriendsNetworkAdapter *weakSelf = self;
    nw_path_monitor_set_update_handler(_monitor, ^(nw_path_t path) {
        SZFriendsNetworkAdapter *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_run != run) return;
        BOOL usable = nw_path_get_status(path) == nw_path_status_satisfied;
        strongSelf->_radioOff = !usable && !PeerToPeerInterfaceUp();
        [strongSelf updateState];
    });
    nw_path_monitor_start(_monitor);
}

@end

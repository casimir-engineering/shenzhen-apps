// The Network.framework adapter's shared state. Split by concern so each file stays reviewable: the adapter file
// (lifecycle, advertising, listeners, accepted and outgoing connections) and +Browse (the Bonjour browser and the
// path monitor). Internal to this directory.

#import <Network/Network.h>

#import "service/discovery/SZFriendsDiscoveryInternal.h"
#import "service/discovery/SZFriendsNetworkStream.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsNetworkAdapter : NSObject <SZFriendsDiscoveryAdapter> {
  @package
    dispatch_queue_t _queue;
    SZFriendsNetworkAdapterOptions *_options;
    NSUInteger _run; // bumps on every start and stop, so callbacks from a previous run are ignored
    BOOL _running, _browserReady, _listenerReady, _policyDenied, _radioOff, _failed;
    nw_browser_t _Nullable _browser;
    nw_path_monitor_t _Nullable _monitor;
    NSMutableArray<NSString *> *_ownNames; // our recent instance names, so the browser never sights this Mac
    NSMutableDictionary<NSString *, nw_endpoint_t> *_endpoints;
    // Per endpoint, the peer-to-peer interface (awdl, llw) it was last seen on, and whether it was also seen on the
    // LAN: a lane on peer-to-peer Wi-Fi is pinned to that interface, a LAN dial never wakes it.
    NSMutableDictionary<NSString *, nw_interface_t> *_peerToPeerInterfaces;
    NSMutableSet<NSString *> *_seenOnLAN;
    // Peer-to-peer Wi-Fi (AWDL) in the browser and listeners: off unless the helper asks (ADR 0021). Never in
    // loopback mode.
    BOOL _peerToPeer;
    // The path monitor's last word: some interface other than awdl/llw (Wi-Fi joined, Ethernet) is usable.
    BOOL _hasNetwork;
    void (^_Nullable _onNetworkChange)(BOOL hasNetwork);
}
- (instancetype)initWithQueue:(dispatch_queue_t)queue options:(SZFriendsNetworkAdapterOptions *)options;
// The browser's and listeners' parameters: peer-to-peer Wi-Fi included only while _peerToPeer is on.
- (nw_parameters_t)parameters;
// An outgoing connection's: peer-to-peer Wi-Fi only on that route, pinned to `interface` when given.
- (nw_parameters_t)parametersForRoute:(SZFriendsRouteMethod)route interface:(nullable nw_interface_t)interface;
- (void)setPeerToPeer:(BOOL)peerToPeer;
- (void)updateState;
// Shared by the browser and both listeners: a refusal is Denied, any other failure retries the whole adapter.
- (void)noteError:(nullable nw_error_t)error failed:(BOOL)failed;
@end

@interface SZFriendsNetworkAdapter (Browse)
- (void)startBrowser;
- (void)startPathMonitor;
- (void)refreshDiscovery;
- (void)forgetEndpoint:(NSString *)endpointID;
@end

// What the browser reads from a result, safely (+Browse; pure, so tests build their own endpoints and records).
// A C string from the LAN as text: nil for NULL or for bytes that are not UTF-8, never an exception.
NSString *_Nullable SZFriendsStringFromLANBytes(const char *_Nullable bytes);
// The endpoint's Bonjour service name, or nil when it has none or its bytes are not UTF-8: such an entry is skipped.
NSString *_Nullable SZFriendsBonjourServiceName(nw_endpoint_t _Nullable endpoint);
// The record's keys with non-empty values. A key whose bytes are not UTF-8 is skipped; the other keys still count.
NSDictionary<NSString *, NSData *> *SZFriendsNetworkTXTRecordFields(nw_txt_record_t _Nullable txt);

// Counts a browser, listener or path monitor for SZFriendsNetworkObjectsCreated.
void SZFriendsNoteNetworkObjectCreated(void);

NS_ASSUME_NONNULL_END

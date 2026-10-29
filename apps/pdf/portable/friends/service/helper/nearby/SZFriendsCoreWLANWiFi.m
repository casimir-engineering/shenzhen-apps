// The Mac's Wi-Fi for the Wi-Fi Direct boost (ADR 0019), through CoreWLAN: join a friend's phone's link as an
// ordinary WPA2 network, and get back on the network the Mac was on. Built into the helper only; created only for a
// person's own home (never a test home, never a test binary), and it touches Wi-Fi only after the person said Go
// faster on this Mac, or at launch to come back from a link a crashed run left it on.
//
// Scanning for a network by name needs Location Services for the helper on macOS 14 and later (names come back empty
// otherwise), so the first join asks for it, after Go faster; joining itself shows no prompt. Coming back: leave the
// link, give macOS a few seconds to rejoin its preferred network by itself, then associate with the network written
// down (the system's saved password). Online: Network.framework's path monitor, no traffic of ours.

#import <CoreLocation/CoreLocation.h>
#import <CoreWLAN/CoreWLAN.h>
#import <Network/Network.h>

#import "service/helper/nearby/SZFriendsCoreWLANWiFi.h"

// How long the first join waits for the person to answer Location Services' prompt.
static const NSTimeInterval SZFriendsLocationWait = 60;
static NSString *const SZFriendsUnnamedNetwork = @"wifi";
// How long macOS gets to rejoin its own network after the Mac leaves a link, before it is asked to.
static const NSTimeInterval SZFriendsAutoJoinWait = 8;

@interface SZFriendsCoreWLANWiFi () <CLLocationManagerDelegate>
@end

@implementation SZFriendsCoreWLANWiFi {
    dispatch_queue_t _queue;
    nw_path_monitor_t _monitor, _wired;
    nw_path_status_t _status, _wiredStatus;
    CLLocationManager *_location;
    NSMutableArray<void (^)(void)> *_afterLocation;
    NSString *_joinedHere; // the link this run joined, on _queue
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.intuition.shenzhenfriends.wifi", DISPATCH_QUEUE_SERIAL);
        _status = nw_path_status_invalid;
        _wiredStatus = nw_path_status_invalid;
        _afterLocation = [NSMutableArray array];
        __weak SZFriendsCoreWLANWiFi *weakSelf = self;
        _monitor = nw_path_monitor_create();
        nw_path_monitor_set_queue(_monitor, _queue);
        nw_path_monitor_set_update_handler(_monitor, ^(nw_path_t path) {
            SZFriendsCoreWLANWiFi *strongSelf = weakSelf;
            if (strongSelf) strongSelf->_status = nw_path_get_status(path);
        });
        nw_path_monitor_start(_monitor);
        _wired = nw_path_monitor_create_with_type(nw_interface_type_wired);
        nw_path_monitor_set_queue(_wired, _queue);
        nw_path_monitor_set_update_handler(_wired, ^(nw_path_t path) {
            SZFriendsCoreWLANWiFi *strongSelf = weakSelf;
            if (strongSelf) strongSelf->_wiredStatus = nw_path_get_status(path);
        });
        nw_path_monitor_start(_wired);
    }
    return self;
}

- (void)dealloc {
    nw_path_monitor_cancel(_monitor);
    nw_path_monitor_cancel(_wired);
}

- (nullable CWInterface *)interface {
    return [CWWiFiClient sharedWiFiClient].interface;
}

- (SZFriendsBoostConnectivity *)connectivity {
    CWInterface *interface = self.interface;
    SZFriendsBoostConnectivity *now = [SZFriendsBoostConnectivity new];
    now.onWiFi = interface.powerOn && interface.serviceActive;
    now.wifiName = now.onWiFi ? interface.ssid : nil; // nil without Location Services: "your Wi-Fi"
    __block nw_path_status_t wired;
    dispatch_sync(_queue, ^{
        wired = self->_wiredStatus;
    });
    now.wired = wired == nw_path_status_satisfied;
    return now;
}

// Its name, or "wifi" when Location Services hides it: then only macOS's own auto-join brings the Mac back, and the
// online check still runs.
- (NSString *)currentNetwork {
    CWInterface *interface = self.interface;
    if (!interface.serviceActive) return nil;
    return interface.ssid ?: SZFriendsUnnamedNetwork;
}

#pragma mark - Location Services, for names

- (void)whenLocationAnswered:(void (^)(void))then {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_location == nil) {
            self->_location = [CLLocationManager new];
            self->_location.delegate = self;
        }
        if (self->_location.authorizationStatus != kCLAuthorizationStatusNotDetermined) return then();
        [self->_afterLocation addObject:[then copy]];
        if (self->_afterLocation.count == 1) {
            [self->_location requestWhenInUseAuthorization];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFriendsLocationWait * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               [self runAfterLocation];
                           });
        }
    });
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    if (manager.authorizationStatus != kCLAuthorizationStatusNotDetermined) [self runAfterLocation];
}

- (void)runAfterLocation {
    NSArray *waiting = [_afterLocation copy];
    [_afterLocation removeAllObjects];
    for (void (^then)(void) in waiting) then();
}

#pragma mark - Joining and coming back

// The network called `name` in a fresh scan, or nil.
- (nullable CWNetwork *)scanFor:(NSString *)name {
    NSError *error = nil;
    NSSet<CWNetwork *> *found = [self.interface scanForNetworksWithName:name includeHidden:NO error:&error];
    for (CWNetwork *network in found) {
        if ([network.ssid isEqualToString:name]) return network;
    }
    // Without Location Services the names come back empty: a scan filtered by name still finds only that network.
    return found.count == 1 ? found.anyObject : nil;
}

- (void)joinNetwork:(NSString *)network passphrase:(NSString *)passphrase completion:(void (^)(BOOL))completion {
    void (^done)(BOOL) = [completion copy];
    [self whenLocationAnswered:^{
        dispatch_async(self->_queue, ^{
            BOOL joined = NO;
            for (int attempt = 0; attempt < 3 && !joined; attempt++) {
                CWNetwork *found = [self scanFor:network];
                NSError *error = nil;
                joined = found != nil && [self.interface associateToNetwork:found password:passphrase error:&error];
                if (!joined) [NSThread sleepForTimeInterval:2];
            }
            if (joined) self->_joinedHere = [network copy];
            done(joined);
        });
    }];
}

- (void)rejoinNetwork:(NSString *)network leaving:(NSString *)joined completion:(void (^)(BOOL))completion {
    void (^done)(BOOL) = [completion copy];
    dispatch_async(_queue, ^{
        CWInterface *interface = self.interface;
        NSString *now = interface.ssid;
        // Only ever leave the link itself: a network the person chose meanwhile is theirs. Without its name (no Location
        // Services) the Mac leaves only a link this run joined; after a crash it then only asks to rejoin.
        BOOL onLink = now != nil ? [now isEqualToString:joined] : [self->_joinedHere isEqualToString:joined];
        if (onLink && interface.serviceActive) [interface disassociate];
        self->_joinedHere = nil;
        if (network == nil) return done(YES);
        [NSThread sleepForTimeInterval:1];
        for (NSTimeInterval waited = 1; waited < SZFriendsAutoJoinWait; waited += 0.5) {
            NSString *ssid = interface.ssid;
            if (interface.serviceActive && ![ssid isEqualToString:joined]) return done(YES);
            [NSThread sleepForTimeInterval:0.5];
        }
        if ([network isEqualToString:SZFriendsUnnamedNetwork]) return done(NO);
        CWNetwork *found = [self scanFor:network];
        NSError *error = nil;
        done(found != nil && [interface associateToNetwork:found password:nil error:&error]);
    });
}

- (void)checkOnline:(void (^)(BOOL))completion {
    void (^done)(BOOL) = [completion copy];
    dispatch_async(_queue, ^{
        done(self->_status == nw_path_status_satisfied);
    });
}

@end
